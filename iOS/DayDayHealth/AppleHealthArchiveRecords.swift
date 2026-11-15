import CoreLocation
import HealthKit
import CryptoKit

struct AppleHealthArchiveRecord: Codable {
  let id: UUID
  let type: String
  var deleted = false
  var revision: Double? = nil
  var fields: [String: Data]? = nil

  static func snapshot(_ type: String, identity: String, fields: [String: Data], now: Date) -> Self {
    let bytes = Array(SHA256.hash(data: Data((type + "\n" + identity).utf8)).prefix(16))
    let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    return Self(id: id, type: type, revision: now.timeIntervalSince1970, fields: fields)
  }
}

actor AppleHealthArchiveReader {
  static let shared = AppleHealthArchiveReader()
  static let queueKind = "healthkit-archive"
  private let store = HKHealthStore()
  private let queue = HealthOutboxDB.archive
  private var collecting = false
  private var nextType = 0
  private var collectionAccount: String?
  private var finished = Set<String>()

  private static let specialTypes: [HKSampleType] = {
    var types: [HKSampleType] = [
      .workoutType(), HKSeriesType.workoutRoute(), HKSeriesType.heartbeat(),
      .electrocardiogramType(), .audiogramSampleType(), .visionPrescriptionType(),
      HKCorrelationType(.bloodPressure), HKCorrelationType(.food)
    ]
    if #available(iOS 18.0, *) {
      types += [.stateOfMindType(), HKScoredAssessmentType(.init(rawValue: "HKScoredAssessmentTypeIdentifierGAD7")),
                HKScoredAssessmentType(.init(rawValue: "HKScoredAssessmentTypeIdentifierPHQ9"))]
    }
    if #available(iOS 26.0, *) { types.append(.medicationDoseEventType()) }
    return types + clinicalTypes
  }()

  static var sampleTypes: [HKSampleType] { AppleHealthArchiveTypeCatalog.samples + specialTypes }
  static let clinicalTypes: [HKSampleType] = AppleHealthArchiveTypeCatalog.clinical
  static var generalReadTypes: Set<HKObjectType> {
    var result = Set<HKObjectType>(sampleTypes.filter {
      !($0 is HKClinicalType) && !($0 is HKCorrelationType) && !$0.requiresPerObjectAuthorization()
    })
    if #available(iOS 26.0, *) { result.remove(HKObjectType.medicationDoseEventType()) }
    result.formUnion(AppleHealthArchiveTypeCatalog.characteristics)
    result.insert(HKObjectType.activitySummaryType())
    return result
  }

  func authorize() async throws {
    try await store.requestAuthorization(toShare: [], read: Self.generalReadTypes)
  }

  func authorizeClinicalRecords() async throws {
    try await store.requestAuthorization(toShare: [], read: Set(Self.clinicalTypes))
  }

  @available(iOS 26.0, *)
  func authorizeMedications() async throws {
    try await store.requestPerObjectReadAuthorization(for: .userAnnotatedMedicationType(), predicate: nil)
  }

  func collectPrescriptions(namespace: String) async throws {
    let type = HKObjectType.visionPrescriptionType()
    try await store.requestPerObjectReadAuthorization(for: type, predicate: nil)
    let query = HKSampleQueryDescriptor(predicates: [.visionPrescription()], sortDescriptors: [])
    let samples = try await query.result(for: store)
    try await queue.prepareArchive()
    for sample in samples {
      let record = try await encode(sample)
      try await queue.enqueue([record], namespace: namespace, kind: Self.queueKind)
    }
  }

  func collectClinicalDocuments(namespace: String) async throws {
    let cdaType = HKDocumentType(.CDA)
    try await store.requestAuthorization(toShare: [], read: [cdaType])
    let documents: [HKDocumentSample] = try await withCheckedThrowingContinuation { continuation in
      let query = HKDocumentQuery(documentType: cdaType, predicate: nil, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: nil, includeDocumentData: false) {
        _, results, _, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: results ?? []) }
      }
      store.execute(query)
    }
    try await queue.prepareArchive()
    for document in documents {
      let data: Data? = try await withCheckedThrowingContinuation { continuation in
        let query = HKDocumentQuery(documentType: cdaType, predicate: HKQuery.predicateForObject(with: document.uuid),
                                    limit: 1, sortDescriptors: nil, includeDocumentData: true) {
          _, results, _, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: (results?.first as? HKCDADocumentSample)?.document?.documentData) }
        }
        store.execute(query)
      }
      if let data {
        var record = try await encode(document)
        record.fields?["cda_xml"] = data
        try await queue.enqueue([record], namespace: namespace, kind: Self.queueKind)
      }
    }
    let verifiable = HKVerifiableClinicalRecordQueryDescriptor(
      recordTypes: [.covid19, .immunization, .laboratory, .recovery],
      sourceTypes: [.smartHealthCard, .euDigitalCOVIDCertificate])
    for record in try await verifiable.result(for: store) {
      try await queue.enqueue([try await encode(record)], namespace: namespace, kind: Self.queueKind)
    }
  }

  struct Collection {
    var more = false
    var failures = 0
  }

  /// Run a bounded sweep. A rotating cursor prevents a large or failing type from
  /// starving the rest. Every successful page has its own durable checkpoint.
  func collect(namespace: String, generation: String, dirty: Set<String>,
               timeLimit: TimeInterval, includeClinical: Bool) async throws -> Collection {
    guard !collecting else { return Collection(more: true) }
    collecting = true
    defer { collecting = false }
    let key = namespace + "/" + generation
    if key != collectionAccount {
      collectionAccount = key
      nextType = 0
      finished.removeAll()
    }
    if dirty.isEmpty { finished.removeAll() } else { finished.subtract(dirty) }
    try await queue.prepareArchive()
    let types = Self.sampleTypes.filter {
      !$0.requiresPerObjectAuthorization() && (includeClinical || !($0 is HKClinicalType))
    }
    nextType %= types.count
    let deadline = Date().addingTimeInterval(timeLimit)
    var result = Collection()
    for _ in types.indices {
      try Task.checkCancellation()
      guard Date() < deadline else { result.more = true; break }
      let type = types[nextType]
      nextType = (nextType + 1) % types.count
      guard !finished.contains(type.identifier) else { continue }
      do {
        let more = try await collectPage(type: type, namespace: namespace, key: key)
        if more { result.more = true } else { finished.insert(type.identifier) }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        result.failures += 1
      }
    }
    if Date() < deadline && dirty.isEmpty {
      do { try await collectSnapshots(namespace: namespace, key: key) }
      catch is CancellationError { throw CancellationError() }
      catch { result.failures += 1 }
    }
    return result
  }

  private func collectPage(type: HKSampleType, namespace: String, key: String) async throws -> Bool {
    let anchorKey = key + "/" + type.identifier
    let anchor = try await queue.anchorData(for: anchorKey).flatMap {
      try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
    }
    let limit = type is HKSeriesType || type is HKElectrocardiogramType || type is HKClinicalType ? 1 : 100
    let page: ([HKSample], [HKDeletedObject], HKQueryAnchor) = try await withCheckedThrowingContinuation { c in
      let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: limit) {
        _, samples, deleted, next, error in
        if let error { c.resume(throwing: error) }
        else if let next { c.resume(returning: (samples ?? [], deleted ?? [], next)) }
        else { c.resume(throwing: CocoaError(.fileReadUnknown)) }
      }
      store.execute(query)
    }
    var records: [AppleHealthArchiveRecord] = []
    for sample in page.0 {
      try Task.checkCancellation()
      records.append(try await encode(sample))
    }
    records += page.1.map { .init(id: $0.uuid, type: type.identifier, deleted: true) }
    let next = try NSKeyedArchiver.archivedData(withRootObject: page.2, requiringSecureCoding: true)
    try Task.checkCancellation()
    try await queue.enqueue(records, namespace: namespace, kind: Self.queueKind,
                            anchorKey: anchorKey, anchorData: next)
    return page.0.count + page.1.count >= limit
  }

  private func encode(_ sample: HKSample) async throws -> AppleHealthArchiveRecord {
    var fields = ["sample": try NSKeyedArchiver.archivedData(withRootObject: sample, requiringSecureCoding: true)]
    if let clinical = sample as? HKClinicalRecord, let fhir = clinical.fhirResource {
      fields["fhir"] = fhir.data
    } else if let credential = sample as? HKVerifiableClinicalRecord {
      fields["credential"] = credential.dataRepresentation
    } else if let workout = sample as? HKWorkout {
      let routeQuery = HKSampleQueryDescriptor(
        predicates: [.workoutRoute(HKQuery.predicateForObjects(from: workout))], sortDescriptors: [])
      if let routes = try? await routeQuery.result(for: store), !routes.isEmpty {
        fields["route_ids"] = try JSONEncoder().encode(routes.map(\.uuid))
      }
    } else if let route = sample as? HKWorkoutRoute {
      var locations: [CLLocation] = []
      for try await location in HKWorkoutRouteQueryDescriptor(route).results(for: store) {
        try Task.checkCancellation()
        locations.append(location)
      }
      fields["locations"] = try NSKeyedArchiver.archivedData(withRootObject: locations, requiringSecureCoding: true)
    } else if let ecg = sample as? HKElectrocardiogram {
      var voltage: [[Double]] = []
      for try await measurement in HKElectrocardiogramQueryDescriptor(ecg).results(for: store) {
        try Task.checkCancellation()
        if let value = measurement.quantity(for: .appleWatchSimilarToLeadI) {
          voltage.append([measurement.timeSinceSampleStart, value.doubleValue(for: .volt())])
        }
      }
      fields["leadI_volts"] = try JSONEncoder().encode(voltage)
    } else if let heartbeat = sample as? HKHeartbeatSeriesSample {
      var beats: [[Double]] = []
      for try await beat in HKHeartbeatSeriesQueryDescriptor(heartbeat).results(for: store) {
        try Task.checkCancellation()
        beats.append([beat.timeIntervalSinceStart, beat.precededByGap ? 1 : 0])
      }
      fields["heartbeat_seconds_and_gap"] = try JSONEncoder().encode(beats)
    } else if let quantity = sample as? HKQuantitySample, quantity.count > 1 {
      let predicate = HKQuery.predicateForObject(with: sample.uuid)
      let query = HKQuantitySeriesSampleQueryDescriptor(predicate: .quantitySample(type: quantity.quantityType,
                                                                                  predicate: predicate))
      var quantities: [[String: Any]] = []
      for try await item in query.results(for: store) {
        try Task.checkCancellation()
        quantities.append(["quantity": item.quantity, "start": item.dateInterval.start, "end": item.dateInterval.end])
      }
      fields["quantity_series"] = try NSKeyedArchiver.archivedData(withRootObject: quantities, requiringSecureCoding: true)
    }
    if sample is HKVisionPrescription ||
        sample.sampleType.identifier == HKClinicalTypeIdentifier.clinicalNoteRecord.rawValue {
      let attachments = HKAttachmentStore(healthStore: store)
      for attachment in try await attachments.attachments(for: sample) {
        try Task.checkCancellation()
        let id = attachment.identifier.uuidString
        fields["attachment_info_" + id] = try NSKeyedArchiver.archivedData(withRootObject: attachment,
                                                                           requiringSecureCoding: true)
        fields["attachment_" + id] = try await withCheckedThrowingContinuation { continuation in
          _ = attachments.getData(for: attachment) { data, error in
            if let data { continuation.resume(returning: data) }
            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
          }
        }
      }
    }
    fields["start"] = try JSONEncoder().encode(sample.startDate.timeIntervalSince1970)
    fields["end"] = try JSONEncoder().encode(sample.endDate.timeIntervalSince1970)
    return .init(id: sample.uuid, type: sample.sampleType.identifier, fields: fields)
  }

  private func collectSnapshots(namespace: String, key: String) async throws {
    let today = Date()
    let cacheKey = key + "/snapshots"
    let lastRun = try await queue.anchorData(for: cacheKey).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    if lastRun.map({ today.timeIntervalSince($0) >= 3600 }) ?? true {
      try await collectProfile(namespace: namespace, key: cacheKey, now: today)
    }
    let calendar = Calendar.current
    let ringsKey = key + "/activitySummary"
    let lastRings = try await queue.anchorData(for: ringsKey).flatMap { try? JSONDecoder().decode(Date.self, from: $0) }
    let start = lastRings.flatMap { calendar.date(byAdding: .day, value: -30, to: $0) }
    let predicate = start.map {
      let parts: Set<Calendar.Component> = [.year, .month, .day, .era, .calendar]
      return HKQuery.predicate(forActivitySummariesBetweenStart: calendar.dateComponents(parts, from: $0),
                               end: calendar.dateComponents(parts, from: today))
    }
    if lastRings.map({ today.timeIntervalSince($0) >= 3600 }) ?? true {
      let rings = try await HKActivitySummaryQueryDescriptor(predicate: predicate).result(for: store)
      var summaries: [AppleHealthArchiveRecord] = []
      for ring in rings {
        let day = ring.dateComponents(for: calendar)
        let identity = "\(day.era ?? 0)/\(day.year ?? 0)/\(day.month ?? 0)/\(day.day ?? 0)"
        summaries.append(.snapshot("activitySummary", identity: identity,
                                 fields: ["summary": try NSKeyedArchiver.archivedData(withRootObject: ring, requiringSecureCoding: true)],
                                 now: today))
      }
      try Task.checkCancellation()
      try await queue.enqueue(summaries, namespace: namespace, kind: Self.queueKind,
                              anchorKey: ringsKey, anchorData: try JSONEncoder().encode(today))
    }
  }

  private func collectProfile(namespace: String, key: String, now today: Date) async throws {
    var records: [AppleHealthArchiveRecord] = []
    let characteristics: [(String, Int?)] = [
      ("biologicalSex", (try? store.biologicalSex().biologicalSex).flatMap { $0 == .notSet ? nil : $0.rawValue }),
      ("bloodType", (try? store.bloodType().bloodType).flatMap { $0 == .notSet ? nil : $0.rawValue }),
      ("skinType", (try? store.fitzpatrickSkinType().skinType).flatMap { $0 == .notSet ? nil : $0.rawValue }),
      ("wheelchairUse", (try? store.wheelchairUse().wheelchairUse).flatMap { $0 == .notSet ? nil : $0.rawValue }),
      ("activityMoveMode", (try? store.activityMoveMode().activityMoveMode).map { $0.rawValue })
    ]
    for (type, value) in characteristics {
      guard let value else { continue }
      records.append(.snapshot("characteristic." + type, identity: "profile",
                               fields: ["value": try JSONEncoder().encode(value)], now: today))
    }
    if let birthday = try? store.dateOfBirthComponents() {
      records.append(.snapshot("characteristic.dateOfBirth", identity: "profile",
                               fields: ["value": try JSONEncoder().encode(birthday)], now: today))
    }
    if #available(iOS 26.0, *),
       let medications = try? await HKUserAnnotatedMedicationQueryDescriptor().result(for: store),
       !medications.isEmpty {
      records.append(.snapshot("userAnnotatedMedications", identity: "medications",
                               fields: ["medications": try NSKeyedArchiver.archivedData(withRootObject: medications, requiringSecureCoding: true)],
                               now: today))
    }
    try Task.checkCancellation()
    try await queue.enqueue(records, namespace: namespace, kind: Self.queueKind,
                            anchorKey: key, anchorData: try JSONEncoder().encode(today))
  }
}
