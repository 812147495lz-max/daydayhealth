import Foundation
import CryptoKit
import HealthKit

struct HealthMetricUpload: Codable {
  let external_id: String
  let kind: String
  let observed_at: Date
  let value: Double?
  let unit: String
}

struct HealthBatchRequest: Encodable {
  let batch_id: String
  let source: String
  let samples: [HealthMetricUpload]
  let deleted_ids: [String]
}

struct HealthBatchReceipt: Decodable {
  let inserted: Int
  let updated: Int
  let deleted: Int
  let received: Int?
}

struct HealthMetricChange: Codable {
  let sample: HealthMetricUpload?
  let deletedID: String?
}

/// Public quantity and category identifiers from the iOS SDK.
struct AdditionalHealthMetric {
  enum Mode: String { case total, average, event }

  let name: String
  let title: String
  let group: String
  let unit: String
  let mode: Mode
  let major: Int
  let minor: Int

  init(_ name: String, _ title: String, _ group: String, _ unit: String,
       _ mode: Mode, major: Int = 17, minor: Int = 0) {
    self.name = name
    self.title = title
    self.group = group
    self.unit = unit
    self.mode = mode
    self.major = major
    self.minor = minor
  }

  var kind: String { "hk_\(mode.rawValue)_\(name)" }
  var identifier: String {
    let prefix = mode == .event ? "HKCategoryTypeIdentifier" : "HKQuantityTypeIdentifier"
    return prefix + name
  }
  var sampleType: HKSampleType? {
    let version = OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)
    guard ProcessInfo.processInfo.isOperatingSystemAtLeast(version) else { return nil }
    if mode == .event {
      return HKObjectType.categoryType(forIdentifier: .init(rawValue: identifier))
    }
    return HKObjectType.quantityType(forIdentifier: .init(rawValue: identifier))
  }

  var quantityUnit: HKUnit {
    switch unit {
    case "count": return .count()
    case "%": return .percent()
    case "kcal/(kg*hr)":
      return HKUnit.kilocalorie().unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))
    case "ml/(kg*min)":
      return HKUnit.literUnit(with: .milli)
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
    default: return HKUnit(from: unit)
    }
  }

  static let all: [Self] = [
    .init("AppleSleepingWristTemperature", "Apple Sleeping Wrist Temperature", "身体测量", "degC",
          .average),
    .init("ElectrodermalActivity", "Electrodermal Activity", "身体测量", "S", .average),
    .init("Height", "身高", "身体测量", "m", .average),
    .init("WaistCircumference", "腰围", "身体测量", "m", .average),
    .init("AppleMoveTime", "Apple Move Time", "运动", "min", .total),
    .init("AppleStandTime", "Apple Stand Time", "运动", "min", .total),
    .init("CrossCountrySkiingSpeed", "Cross Country Skiing Speed", "运动", "m/s",
          .average, major: 18, minor: 0),
    .init("CyclingCadence", "Cycling Cadence", "运动", "count/min", .average),
    .init("CyclingFunctionalThresholdPower", "Cycling Functional Threshold Power", "运动", "W",
          .average),
    .init("CyclingPower", "Cycling Power", "运动", "W", .average),
    .init("CyclingSpeed", "骑行速度", "运动", "m/s", .average),
    .init("DistanceCrossCountrySkiing", "Distance Cross Country Skiing", "运动", "m",
          .total, major: 18, minor: 0),
    .init("DistanceCycling", "Distance Cycling", "运动", "m", .total),
    .init("DistanceDownhillSnowSports", "Distance Downhill Snow Sports", "运动", "m", .total),
    .init("DistancePaddleSports", "Distance Paddle Sports", "运动", "m", .total, major: 18, minor: 0),
    .init("DistanceRowing", "Distance Rowing", "运动", "m", .total, major: 18, minor: 0),
    .init("DistanceSkatingSports", "Distance Skating Sports", "运动", "m",
          .total, major: 18, minor: 0),
    .init("DistanceSwimming", "Distance Swimming", "运动", "m", .total),
    .init("DistanceWheelchair", "Distance Wheelchair", "运动", "m", .total),
    .init("EstimatedWorkoutEffortScore", "Estimated Workout Effort Score", "运动", "appleEffortScore",
          .average, major: 18, minor: 0),
    .init("NikeFuel", "Nike Fuel", "运动", "count", .total),
    .init("PaddleSportsSpeed", "Paddle Sports Speed", "运动", "m/s", .average, major: 18, minor: 0),
    .init("PhysicalEffort", "Physical Effort", "运动", "kcal/(kg*hr)", .average),
    .init("PushCount", "Push Count", "运动", "count", .total),
    .init("RowingSpeed", "Rowing Speed", "运动", "m/s", .average, major: 18, minor: 0),
    .init("RunningPower", "Running Power", "运动", "W", .average),
    .init("RunningSpeed", "跑步速度", "运动", "m/s", .average),
    .init("SwimmingStrokeCount", "Swimming Stroke Count", "运动", "count", .total),
    .init("UnderwaterDepth", "Underwater Depth", "运动", "m", .average),
    .init("WorkoutEffortScore", "Workout Effort Score", "运动", "appleEffortScore",
          .average, major: 18, minor: 0),
    .init("EnvironmentalAudioExposure", "Environmental Audio Exposure", "听力", "dBASPL", .average),
    .init("EnvironmentalSoundReduction", "Environmental Sound Reduction", "听力", "dBASPL", .average),
    .init("HeadphoneAudioExposure", "Headphone Audio Exposure", "听力", "dBASPL", .average),
    .init("AtrialFibrillationBurden", "Atrial Fibrillation Burden", "心脏", "%", .average),
    .init("HeartRateRecoveryOneMinute", "Heart Rate Recovery One Minute", "心脏", "count/min",
          .average),
    .init("HeartRateVariabilityRMSSD", "Heart Rate Variability RMSSD", "心脏", "ms",
          .average, major: 27, minor: 0),
    .init("PeripheralPerfusionIndex", "Peripheral Perfusion Index", "心脏", "%", .average),
    .init("VO2Max", "最大摄氧量", "心脏", "ml/(kg*min)", .average),
    .init("WalkingHeartRateAverage", "Walking Heart Rate Average", "心脏", "count/min", .average),
    .init("AppleWalkingSteadiness", "Apple Walking Steadiness", "行动能力", "%", .average),
    .init("RunningGroundContactTime", "Running Ground Contact Time", "行动能力", "ms", .average),
    .init("RunningStrideLength", "Running Stride Length", "行动能力", "m", .average),
    .init("RunningVerticalOscillation", "Running Vertical Oscillation", "行动能力", "cm", .average),
    .init("SixMinuteWalkTestDistance", "Six Minute Walk Test Distance", "行动能力", "m", .average),
    .init("StairAscentSpeed", "Stair Ascent Speed", "行动能力", "m/s", .average),
    .init("StairDescentSpeed", "Stair Descent Speed", "行动能力", "m/s", .average),
    .init("WalkingAsymmetryPercentage", "Walking Asymmetry Percentage", "行动能力", "%", .average),
    .init("WalkingDoubleSupportPercentage", "Walking Double Support Percentage", "行动能力", "%",
          .average),
    .init("WalkingSpeed", "步行速度", "行动能力", "m/s", .average),
    .init("WalkingStepLength", "Walking Step Length", "行动能力", "m", .average),
    .init("DietaryBiotin", "Dietary Biotin", "营养", "g", .total),
    .init("DietaryCaffeine", "Dietary Caffeine", "营养", "g", .total),
    .init("DietaryCalcium", "Dietary Calcium", "营养", "g", .total),
    .init("DietaryChloride", "Dietary Chloride", "营养", "g", .total),
    .init("DietaryCholesterol", "Dietary Cholesterol", "营养", "g", .total),
    .init("DietaryChromium", "Dietary Chromium", "营养", "g", .total),
    .init("DietaryCopper", "Dietary Copper", "营养", "g", .total),
    .init("DietaryFatMonounsaturated", "Dietary Fat Monounsaturated", "营养", "g", .total),
    .init("DietaryFatPolyunsaturated", "Dietary Fat Polyunsaturated", "营养", "g", .total),
    .init("DietaryFatSaturated", "Dietary Fat Saturated", "营养", "g", .total),
    .init("DietaryFiber", "Dietary Fiber", "营养", "g", .total),
    .init("DietaryFolate", "Dietary Folate", "营养", "g", .total),
    .init("DietaryIodine", "Dietary Iodine", "营养", "g", .total),
    .init("DietaryIron", "Dietary Iron", "营养", "g", .total),
    .init("DietaryMagnesium", "Dietary Magnesium", "营养", "g", .total),
    .init("DietaryManganese", "Dietary Manganese", "营养", "g", .total),
    .init("DietaryMolybdenum", "Dietary Molybdenum", "营养", "g", .total),
    .init("DietaryNiacin", "Dietary Niacin", "营养", "g", .total),
    .init("DietaryPantothenicAcid", "Dietary Pantothenic Acid", "营养", "g", .total),
    .init("DietaryPhosphorus", "Dietary Phosphorus", "营养", "g", .total),
    .init("DietaryPotassium", "Dietary Potassium", "营养", "g", .total),
    .init("DietaryRiboflavin", "Dietary Riboflavin", "营养", "g", .total),
    .init("DietarySelenium", "Dietary Selenium", "营养", "g", .total),
    .init("DietarySodium", "Dietary Sodium", "营养", "g", .total),
    .init("DietarySugar", "Dietary Sugar", "营养", "g", .total),
    .init("DietaryThiamin", "Dietary Thiamin", "营养", "g", .total),
    .init("DietaryVitaminA", "Dietary Vitamin A", "营养", "g", .total),
    .init("DietaryVitaminB12", "Dietary Vitamin B12", "营养", "g", .total),
    .init("DietaryVitaminB6", "Dietary Vitamin B6", "营养", "g", .total),
    .init("DietaryVitaminC", "Dietary Vitamin C", "营养", "g", .total),
    .init("DietaryVitaminD", "Dietary Vitamin D", "营养", "g", .total),
    .init("DietaryVitaminE", "Dietary Vitamin E", "营养", "g", .total),
    .init("DietaryVitaminK", "Dietary Vitamin K", "营养", "g", .total),
    .init("DietaryWater", "饮水", "营养", "mL", .total),
    .init("DietaryZinc", "Dietary Zinc", "营养", "g", .total),
    .init("BloodAlcoholContent", "Blood Alcohol Content", "其他健康记录", "%", .average),
    .init("BloodPressureDiastolic", "舒张压", "其他健康记录", "mmHg", .average),
    .init("BloodPressureSystolic", "收缩压", "其他健康记录", "mmHg", .average),
    .init("InsulinDelivery", "Insulin Delivery", "其他健康记录", "IU", .total),
    .init("NumberOfAlcoholicBeverages", "Number Of Alcoholic Beverages", "其他健康记录", "count", .total),
    .init("NumberOfTimesFallen", "Number Of Times Fallen", "其他健康记录", "count", .total),
    .init("TimeInDaylight", "Time In Daylight", "其他健康记录", "min", .total),
    .init("UVExposure", "UVExposure", "其他健康记录", "count", .average),
    .init("WaterTemperature", "Water Temperature", "其他健康记录", "degC", .average),
    .init("BasalBodyTemperature", "Basal Body Temperature", "生殖健康", "degC", .average),
    .init("AppleSleepingBreathingDisturbances", "Apple Sleeping Breathing Disturbances", "呼吸", "count",
          .average, major: 18, minor: 0),
    .init("ForcedExpiratoryVolume1", "Forced Expiratory Volume1", "呼吸", "L", .average),
    .init("ForcedVitalCapacity", "Forced Vital Capacity", "呼吸", "L", .average),
    .init("InhalerUsage", "Inhaler Usage", "呼吸", "count", .total),
    .init("PeakExpiratoryFlowRate", "Peak Expiratory Flow Rate", "呼吸", "L/min", .average),
    .init("BloodGlucose", "血糖", "生命体征", "mg/dL", .average),
    .init("BodyTemperature", "体温", "生命体征", "degC", .average),
    .init("AppleStandHour", "Apple Stand Hour", "运动", "category", .event),
    .init("EnvironmentalAudioExposureEvent", "Environmental Audio Exposure Event", "听力", "category",
          .event),
    .init("HeadphoneAudioExposureEvent", "Headphone Audio Exposure Event", "听力", "category",
          .event),
    .init("HighHeartRateEvent", "High Heart Rate Event", "心脏", "category", .event),
    .init("HypertensionEvent", "Hypertension Event", "心脏", "category", .event, major: 26, minor: 2),
    .init("IrregularHeartRhythmEvent", "Irregular Heart Rhythm Event", "心脏", "category", .event),
    .init("LowCardioFitnessEvent", "Low Cardio Fitness Event", "心脏", "category", .event),
    .init("LowHeartRateEvent", "Low Heart Rate Event", "心脏", "category", .event),
    .init("MindfulSession", "正念训练", "心理健康", "category", .event),
    .init("AppleWalkingSteadinessEvent", "Apple Walking Steadiness Event", "行动能力", "category",
          .event),
    .init("HandwashingEvent", "Handwashing Event", "其他健康记录", "category", .event),
    .init("ToothbrushingEvent", "Toothbrushing Event", "其他健康记录", "category", .event),
    .init("BleedingAfterMenopause", "Bleeding After Menopause", "生殖健康", "category",
          .event, major: 27, minor: 0),
    .init("BleedingAfterPregnancy", "Bleeding After Pregnancy", "生殖健康", "category",
          .event, major: 18, minor: 0),
    .init("BleedingDuringPregnancy", "Bleeding During Pregnancy", "生殖健康", "category",
          .event, major: 18, minor: 0),
    .init("CervicalMucusQuality", "Cervical Mucus Quality", "生殖健康", "category", .event),
    .init("Contraceptive", "Contraceptive", "生殖健康", "category", .event),
    .init("InfrequentMenstrualCycles", "Infrequent Menstrual Cycles", "生殖健康", "category", .event),
    .init("IntermenstrualBleeding", "Intermenstrual Bleeding", "生殖健康", "category", .event),
    .init("IrregularMenstrualCycles", "Irregular Menstrual Cycles", "生殖健康", "category", .event),
    .init("Lactation", "Lactation", "生殖健康", "category", .event),
    .init("MenopausalState", "Menopausal State", "生殖健康", "category", .event, major: 27, minor: 0),
    .init("MenstrualFlow", "Menstrual Flow", "生殖健康", "category", .event),
    .init("OvulationTestResult", "Ovulation Test Result", "生殖健康", "category", .event),
    .init("PersistentIntermenstrualBleeding", "Persistent Intermenstrual Bleeding", "生殖健康", "category",
          .event),
    .init("Pregnancy", "Pregnancy", "生殖健康", "category", .event),
    .init("PregnancyTestResult", "Pregnancy Test Result", "生殖健康", "category", .event),
    .init("ProgesteroneTestResult", "Progesterone Test Result", "生殖健康", "category", .event),
    .init("ProlongedMenstrualPeriods", "Prolonged Menstrual Periods", "生殖健康", "category", .event),
    .init("SexualActivity", "Sexual Activity", "生殖健康", "category", .event),
    .init("SleepApneaEvent", "Sleep Apnea Event", "呼吸", "category", .event, major: 18, minor: 0),
    .init("AbdominalCramps", "Abdominal Cramps", "症状", "category", .event),
    .init("Acne", "Acne", "症状", "category", .event),
    .init("AppetiteChanges", "Appetite Changes", "症状", "category", .event),
    .init("BladderIncontinence", "Bladder Incontinence", "症状", "category", .event),
    .init("Bloating", "Bloating", "症状", "category", .event),
    .init("BreastPain", "Breast Pain", "症状", "category", .event),
    .init("ChestTightnessOrPain", "Chest Tightness Or Pain", "症状", "category", .event),
    .init("Chills", "Chills", "症状", "category", .event),
    .init("Constipation", "Constipation", "症状", "category", .event),
    .init("Coughing", "Coughing", "症状", "category", .event),
    .init("Diarrhea", "Diarrhea", "症状", "category", .event),
    .init("Dizziness", "Dizziness", "症状", "category", .event),
    .init("DrySkin", "Dry Skin", "症状", "category", .event),
    .init("Fainting", "Fainting", "症状", "category", .event),
    .init("Fatigue", "Fatigue", "症状", "category", .event),
    .init("Fever", "Fever", "症状", "category", .event),
    .init("GeneralizedBodyAche", "Generalized Body Ache", "症状", "category", .event),
    .init("HairLoss", "Hair Loss", "症状", "category", .event),
    .init("Headache", "Headache", "症状", "category", .event),
    .init("Heartburn", "Heartburn", "症状", "category", .event),
    .init("HotFlashes", "Hot Flashes", "症状", "category", .event),
    .init("LossOfSmell", "Loss Of Smell", "症状", "category", .event),
    .init("LossOfTaste", "Loss Of Taste", "症状", "category", .event),
    .init("LowerBackPain", "Lower Back Pain", "症状", "category", .event),
    .init("MemoryLapse", "Memory Lapse", "症状", "category", .event),
    .init("MoodChanges", "Mood Changes", "症状", "category", .event),
    .init("Nausea", "Nausea", "症状", "category", .event),
    .init("NightSweats", "Night Sweats", "症状", "category", .event),
    .init("PelvicPain", "Pelvic Pain", "症状", "category", .event),
    .init("RapidPoundingOrFlutteringHeartbeat", "Rapid Pounding Or Fluttering Heartbeat", "症状", "category",
          .event),
    .init("RunnyNose", "Runny Nose", "症状", "category", .event),
    .init("ShortnessOfBreath", "Shortness Of Breath", "症状", "category", .event),
    .init("SinusCongestion", "Sinus Congestion", "症状", "category", .event),
    .init("SkippedHeartbeat", "Skipped Heartbeat", "症状", "category", .event),
    .init("SleepChanges", "Sleep Changes", "症状", "category", .event),
    .init("SoreThroat", "Sore Throat", "症状", "category", .event),
    .init("VaginalDryness", "Vaginal Dryness", "症状", "category", .event),
    .init("Vomiting", "Vomiting", "症状", "category", .event),
    .init("Wheezing", "Wheezing", "症状", "category", .event),
  ]
  static let byIdentifier = Dictionary(uniqueKeysWithValues: all.map { ($0.identifier, $0) })
}

/// Incrementally store HealthKit measurements with offline retry and tombstones.
actor HealthMetricsSync {
  static let shared = HealthMetricsSync()
  static let fixtureMetadataKey = "com.daydayhealth.debug.health.original-id"
  private let store = HKHealthStore()
  private let maxPageSize = 200
  #if DEBUG && targetEnvironment(simulator)
  private var debugImportRunning = false
  #endif

  private var sampleTypes: [HKSampleType] {
    let quantities: [HKQuantityTypeIdentifier] = [
      .heartRate, .restingHeartRate, .heartRateVariabilitySDNN,
      .stepCount, .bodyMass, .bodyFatPercentage,
      .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
      .leanBodyMass, .bodyMassIndex, .appleExerciseTime, .flightsClimbed,
      .respiratoryRate, .oxygenSaturation,
      .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates
    ]
    let quantityTypes: [HKSampleType] = quantities.compactMap {
      HKObjectType.quantityType(forIdentifier: $0)
    }
    let categories: [HKSampleType] = [
      HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    ].compactMap { $0 }
    return quantityTypes + categories + AdditionalHealthMetric.all.compactMap(\.sampleType)
  }

  func authorize() async throws {
    guard HKHealthStore.isHealthDataAvailable() else {
      throw NSError(domain: "HealthKit", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "此设备不支持 Apple 健康"])
    }
    // Correlation queries rely on authorization for their component samples.
    // HealthKit rejects correlation containers in the authorization request.
    var readTypes = Set<HKObjectType>(sampleTypes)
    readTypes.insert(HKObjectType.workoutType())
    try await store.requestAuthorization(toShare: [], read: readTypes)
    UserDefaults.standard.set(true, forKey: "wbHealthEnabled")
  }

  func synchronize(client: APIClient) async throws -> Int {
    let instanceID = try await LegacyServerIdentity.shared.instanceID(client: client)
    let namespace = LocalCache.namespace(client.server + instanceID)
    try await HealthOutboxDB.shared.migrateLegacy(HealthMetricChange.self,
      directory: "DayDayHealthMetricOutbox", namespace: namespace, kind: "metrics")
    var count = 0
    var unreadable: [String] = []
    // Important data first. Rotate the remaining catalog across normal refresh cycles
    // instead of blocking every foreground sync on ~190 HealthKit queries.
    let prioritized = Set([
      HKQuantityTypeIdentifier.heartRate.rawValue,
      HKQuantityTypeIdentifier.restingHeartRate.rawValue,
      HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
      HKQuantityTypeIdentifier.stepCount.rawValue,
      HKQuantityTypeIdentifier.bodyMass.rawValue,
      HKQuantityTypeIdentifier.bodyFatPercentage.rawValue,
      HKQuantityTypeIdentifier.activeEnergyBurned.rawValue,
      HKQuantityTypeIdentifier.basalEnergyBurned.rawValue,
      HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue,
      HKQuantityTypeIdentifier.appleExerciseTime.rawValue,
      HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue,
      HKQuantityTypeIdentifier.dietaryProtein.rawValue,
      HKQuantityTypeIdentifier.dietaryFatTotal.rawValue,
      HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue,
      HKCategoryTypeIdentifier.sleepAnalysis.rawValue
    ])
    let all = sampleTypes
    let common = all.filter { prioritized.contains($0.identifier) }
    let secondary = all.filter { !prioritized.contains($0.identifier) }
    let rotationKey = "wbHealthExtrasRotation-\(namespace)"
    let offset = min(max(0, UserDefaults.standard.integer(forKey: rotationKey)), max(0, secondary.count - 1))
    let batchSize = min(36, secondary.count)
    let rotation = (0..<batchSize).map { secondary[(offset + $0) % secondary.count] }
    let selected = common + rotation
    for type in selected {
      let revision = type.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue ? "-v2" : ""
      let key = "wbMetricAnchor-\(namespace)-\(type.identifier)\(revision)"
      var anchor = try await readAnchor(key: key)
      while true {
        try Task.checkCancellation()
        let page: Page
        do {
          page = try await fetch(type: type, anchor: anchor)
        } catch {
          unreadable.append(AdditionalHealthMetric.byIdentifier[type.identifier]?.title
                            ?? type.identifier)
          break
        }
        guard let nextAnchor = page.anchor else { break }
        let additions = page.samples.compactMap { sample -> HealthMetricUpload? in
          #if targetEnvironment(simulator)
          if sample.metadata?[Self.fixtureMetadataKey] != nil { return nil }
          #endif
          // Meals recorded in this app have their own background upload queue.
          if let syncID = sample.metadata?[HKMetadataKeySyncIdentifier] as? String,
             syncID.hasPrefix(Self.mealSyncIDPrefix),
             sample.sourceRevision.source.bundleIdentifier == Bundle.main.bundleIdentifier {
            return nil
          }
          return metric(from: sample)
        }.map {
          HealthMetricChange(sample: $0, deletedID: nil)
        }
        let removals = page.deleted.map {
          HealthMetricChange(sample: nil, deletedID: $0.uuid.uuidString)
        }
        let anchorData = try NSKeyedArchiver.archivedData(
          withRootObject: nextAnchor, requiringSecureCoding: true)
        // Atomic write: enqueue events AND advance HealthKit anchor in the same SQLite transaction.
        try await HealthOutboxDB.shared.enqueue(additions + removals,
          namespace: namespace, kind: "metrics", anchorKey: key, anchorData: anchorData)
        if !additions.isEmpty || !removals.isEmpty {
          await HealthTrendRepository.shared.invalidate(identifier: type.identifier)
        }
        anchor = nextAnchor
        count += additions.count + removals.count
        if page.samples.count + page.deleted.count < maxPageSize { break }
      }
    }
    // Upload once after collection, not after each HealthKit page. A failed upload
    // retains the existing durable JSON queue and its committed anchors.
    try await flush(client: client, namespace: namespace)
    if !secondary.isEmpty {
      UserDefaults.standard.set((offset + batchSize) % secondary.count, forKey: rotationKey)
    }
    if !unreadable.isEmpty {
      let examples = unreadable.prefix(3).joined(separator: "、")
      throw NSError(domain: "HealthKit", code: 5, userInfo: [
        NSLocalizedDescriptionKey: "已同步 \(count) 条变更，\(unreadable.count) 类暂无法读取（\(examples)）。"
      ])
    }
    return count
  }

  /// Compatibility for callers still using the older bucket-based API. Read only the
  /// default highlighted metrics and their requested window; never scan all types.
  func localTrends(bucket: String, calendar: Calendar, refresh: Bool = false) async throws
    -> [String: [TrendPoint]] {
    let span: TimeInterval
    let aggregation: HealthBucket
    switch bucket {
    case "hour": span = 3 * 86400; aggregation = .hour
    case "month": span = 2 * 365 * 86400; aggregation = .month
    default: span = 45 * 86400; aggregation = .day
    }
    let end = Date()
    let range = end.addingTimeInterval(-span)...end
    var result: [String: [TrendPoint]] = [:]
    for definition in HealthMetricCatalog.all where
      HealthMetricCatalog.mainIdentifiers.contains(definition.identifier) {
      guard let kind = Self.quantitySpec(definition.identifier)?.kind ??
          (definition.identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue
            ? "sleep_minutes" : nil) else { continue }
      // Failures of one HealthKit type must not invalidate all locally available charts.
      if let points = try? await HealthTrendRepository.shared.series(for: definition,
        range: range, bucket: aggregation, calendar: calendar, refresh: refresh) {
        result[kind] = points
      }
    }
    return result
  }

  static func quantitySpec(_ identifier: String) -> (kind: String, unit: HKUnit, symbol: String)? {
    switch identifier {
    case HKQuantityTypeIdentifier.heartRate.rawValue:
      return ("heart_rate", HKUnit.count().unitDivided(by: .minute()), "bpm")
    case HKQuantityTypeIdentifier.restingHeartRate.rawValue:
      return ("resting_heart_rate", HKUnit.count().unitDivided(by: .minute()), "bpm")
    case HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue:
      return ("hrv", HKUnit.secondUnit(with: .milli), "ms")
    case HKQuantityTypeIdentifier.stepCount.rawValue:
      return ("step_count", .count(), "count")
    case HKQuantityTypeIdentifier.bodyMass.rawValue:
      return ("body_mass", HKUnit.gramUnit(with: .kilo), "kg")
    case HKQuantityTypeIdentifier.bodyFatPercentage.rawValue:
      return ("body_fat_percentage", .percent(), "%")
    case HKQuantityTypeIdentifier.activeEnergyBurned.rawValue:
      return ("active_energy", .kilocalorie(), "kcal")
    case HKQuantityTypeIdentifier.basalEnergyBurned.rawValue:
      return ("resting_energy", .kilocalorie(), "kcal")
    case HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue:
      return ("walking_running_distance", .meterUnit(with: .kilo), "km")
    case HKQuantityTypeIdentifier.leanBodyMass.rawValue:
      return ("lean_body_mass", .gramUnit(with: .kilo), "kg")
    case HKQuantityTypeIdentifier.bodyMassIndex.rawValue:
      return ("body_mass_index", .count(), "kg/m²")
    case HKQuantityTypeIdentifier.appleExerciseTime.rawValue:
      return ("exercise_time", .minute(), "min")
    case HKQuantityTypeIdentifier.flightsClimbed.rawValue:
      return ("flights_climbed", .count(), "count")
    case HKQuantityTypeIdentifier.respiratoryRate.rawValue:
      return ("respiratory_rate", .count().unitDivided(by: .minute()), "bpm")
    case HKQuantityTypeIdentifier.oxygenSaturation.rawValue:
      return ("oxygen_saturation", .percent(), "%")
    case HKQuantityTypeIdentifier.dietaryEnergyConsumed.rawValue:
      return ("dietary_energy", .kilocalorie(), "kcal")
    case HKQuantityTypeIdentifier.dietaryProtein.rawValue:
      return ("dietary_protein", .gram(), "g")
    case HKQuantityTypeIdentifier.dietaryFatTotal.rawValue:
      return ("dietary_fat", .gram(), "g")
    case HKQuantityTypeIdentifier.dietaryCarbohydrates.rawValue:
      return ("dietary_carbohydrates", .gram(), "g")
    default:
      guard let extra = AdditionalHealthMetric.byIdentifier[identifier], extra.mode != .event
      else { return nil }
      return (extra.kind, extra.quantityUnit, extra.unit)
    }
  }

  private func metric(from sample: HKSample) -> HealthMetricUpload? {
    let identifier = sample.sampleType.identifier
    let kind: String
    let value: Double
    let unit: String
    if let quantity = sample as? HKQuantitySample {
      guard let spec = Self.quantitySpec(identifier),
        quantity.quantity.is(compatibleWith: spec.unit) else { return nil }
      kind = spec.kind
      unit = spec.symbol
      value = quantity.quantity.doubleValue(for: spec.unit) * (unit == "%" ? 100 : 1)
    } else if let category = sample as? HKCategorySample {
      if identifier == HKCategoryTypeIdentifier.sleepAnalysis.rawValue {
        guard [1, 3, 4, 5].contains(category.value) else { return nil }
        kind = "sleep_minutes"
        value = category.endDate.timeIntervalSince(category.startDate) / 60
        unit = "min"
      } else {
        guard let spec = AdditionalHealthMetric.byIdentifier[identifier] else { return nil }
        kind = spec.kind
        value = Double(category.value)
        unit = "category"
      }
    } else { return nil }
    return HealthMetricUpload(external_id: sample.uuid.uuidString,
      kind: kind, observed_at: sample.startDate, value: value, unit: unit)
  }

  static let mealSyncIDPrefix = "daydayhealth-meal-"

  func saveMeal(_ meal: MealEntry, requestPermission: Bool) async throws -> [HealthMetricUpload] {
    guard HKHealthStore.isHealthDataAvailable(), let items = meal.items,
      !items.isEmpty, items.allSatisfy(\.isValid),
      let foodType = HKObjectType.correlationType(forIdentifier: .food) else {
      throw APIClient.APIError.message("此设备无法写入这笔饮食记录。")
    }
    let values: [(HKQuantityTypeIdentifier, Double)] = [
      (.dietaryEnergyConsumed, items.reduce(0) { $0 + $1.kcal }),
      (.dietaryProtein, items.reduce(0) { $0 + $1.protein }),
      (.dietaryFatTotal, items.reduce(0) { $0 + $1.fat }),
      (.dietaryCarbohydrates, items.reduce(0) { $0 + $1.carbs })
    ]
    let quantities: [(HKQuantityType, HKUnit, Double)] = values.compactMap { identifier, value in
      guard let type = HKObjectType.quantityType(forIdentifier: identifier),
        let spec = Self.quantitySpec(type.identifier) else { return nil }
      return (type, spec.unit, value)
    }
    guard quantities.count == values.count else {
      throw APIClient.APIError.message("此设备缺少所需的 Apple 健康营养类型。")
    }
    let types = Set(quantities.map { $0.0 as HKSampleType })
    if requestPermission {
      try await store.requestAuthorization(toShare: types, read: Set(types.map { $0 as HKObjectType }))
    }
    guard types.allSatisfy({ store.authorizationStatus(for: $0) == .sharingAuthorized }) else {
      throw APIClient.APIError.message("请在 Apple 健康中允许写入热量、蛋白质、脂肪和碳水。")
    }

    let syncID = Self.mealSyncIDPrefix + meal.currentHealthRecordID.uuidString
    let samples: [HKQuantitySample]
    if let previous = try await findMeal(syncID, type: foodType) {
      samples = previous.objects.compactMap { $0 as? HKQuantitySample }
    } else {
      samples = quantities.map { type, unit, value in
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
          start: meal.date, end: meal.date, metadata: [
            HKMetadataKeyWasUserEntered: true,
            HKMetadataKeySyncIdentifier: syncID + "-" + type.identifier,
            HKMetadataKeySyncVersion: 1
          ])
      }
      let food = HKCorrelation(type: foodType, start: meal.date, end: meal.date, objects: Set(samples), metadata: [
        HKMetadataKeyFoodType: meal.food,
        HKMetadataKeyWasUserEntered: true,
        HKMetadataKeySyncIdentifier: syncID,
        HKMetadataKeySyncVersion: 1
      ])
      try await store.save(food)
    }
    let receipt = samples.compactMap { metric(from: $0) }
    guard receipt.count == values.count else {
      throw APIClient.APIError.message("无法读取完整的 Apple 健康保存结果。")
    }
    for (type, _, _) in quantities {
      await HealthTrendRepository.shared.invalidate(identifier: type.identifier)
    }
    return receipt
  }

  private func findMeal(_ syncID: String, type: HKCorrelationType) async throws -> HKCorrelation? {
    let predicate = mealPredicate(syncID)
    return try await withCheckedThrowingContinuation { continuation in
      let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: 1, sortDescriptors: nil) {
        _, samples, error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume(returning: samples?.first as? HKCorrelation) }
      }
      store.execute(query)
    }
  }

  private func mealPredicate(_ syncID: String) -> NSPredicate {
    NSCompoundPredicate(andPredicateWithSubpredicates: [
      HKQuery.predicateForObjects(from: HKSource.default()),
      HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
        allowedValues: [syncID])
    ])
  }

  func mealExternalIDs(_ id: UUID) async throws -> [String] {
    guard let type = HKObjectType.correlationType(forIdentifier: .food) else { return [] }
    let meal = try await findMeal(Self.mealSyncIDPrefix + id.uuidString, type: type)
    return meal?.objects.map { $0.uuid.uuidString } ?? []
  }

  func removeMeal(_ id: UUID) async throws {
    guard HKHealthStore.isHealthDataAvailable(),
          let foodType = HKObjectType.correlationType(forIdentifier: .food) else {
      throw APIClient.APIError.message("此设备无法更新 Apple 健康饮食记录。")
    }
    let syncID = Self.mealSyncIDPrefix + id.uuidString
    if let food = try await findMeal(syncID, type: foodType) {
      try await store.delete(food)
    }

    // Check the component samples too, so retry also works if only part was removed.
    let identifiers: [HKQuantityTypeIdentifier] = [
      .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates
    ]
    for identifier in identifiers {
      guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { continue }
      let predicate = mealPredicate(syncID + "-" + type.identifier)
      let page = try await fetch(type: type, anchor: nil, predicate: predicate)
      if !page.samples.isEmpty { try await store.delete(page.samples) }
      await HealthTrendRepository.shared.invalidate(identifier: type.identifier)
    }
  }

  static func remoteMealIDs(_ id: UUID) -> [String] {
    MealTrendData.nutritionIDs.map { mealSyncIDPrefix + id.uuidString + "-" + $0 }
  }

  static func remoteMealSamples(_ meal: MealEntry) -> [HealthMetricUpload] {
    guard meal.isDeleted != true else { return [] }
    let ids = remoteMealIDs(meal.currentHealthRecordID)
    return MealTrendData.nutritionIDs.enumerated().compactMap { index, identifier in
      guard let spec = quantitySpec(identifier),
        let value = MealTrendData.value(for: meal, identifier: identifier), value.isFinite, value >= 0 else {
        return nil
      }
      return HealthMetricUpload(external_id: ids[index], kind: spec.kind, observed_at: meal.date,
        value: value, unit: spec.symbol)
    }
  }

  func uploadMeal(_ samples: [HealthMetricUpload], deleting ids: [String],
                  client: APIClient) async throws {
    // Keep replacement and the final group of removals in a single server transaction.
    let limit = 500
    var remaining = ids[...]
    while remaining.count > limit {
      let changes = remaining.prefix(limit).map { HealthMetricChange(sample: nil, deletedID: $0) }
      _ = try await upload(changes, client: client, redirectDelegate: RejectHTTPRedirects(),
        stableBatchID: true)
      remaining = remaining.dropFirst(limit)
    }
    let changes = samples.map { HealthMetricChange(sample: $0, deletedID: nil) }
      + remaining.map { HealthMetricChange(sample: nil, deletedID: $0) }
    if !changes.isEmpty {
      _ = try await upload(changes, client: client, redirectDelegate: RejectHTTPRedirects(),
        stableBatchID: true)
    }
  }

  private struct Page {
    let samples: [HKSample]
    let deleted: [HKDeletedObject]
    let anchor: HKQueryAnchor?
  }

  private func fetch(type: HKSampleType, anchor: HKQueryAnchor?,
                     predicate: NSPredicate? = nil, limit: Int? = nil) async throws -> Page {
    try await withCheckedThrowingContinuation { continuation in
      let query = HKAnchoredObjectQuery(type: type, predicate: predicate,
        anchor: anchor, limit: limit ?? maxPageSize) { _, samples, deleted, nextAnchor, error in
          if let error { continuation.resume(throwing: error) }
          else { continuation.resume(returning: Page(
            samples: samples ?? [], deleted: deleted ?? [], anchor: nextAnchor
          )) }
        }
      store.execute(query)
    }
  }

  private func readAnchor(key: String) async throws -> HKQueryAnchor? {
    if let data = try await HealthOutboxDB.shared.anchorData(for: key) {
      return try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    // Old anchor is used only before this metric's first SQLite commit.
    guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
    return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
  }

  private func upload(_ batch: [HealthMetricChange], client: APIClient,
                      source: String = "apple_health",
                      redirectDelegate: URLSessionTaskDelegate? = nil,
                      stableBatchID: Bool = false) async throws -> HealthBatchReceipt {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let deleted = batch.compactMap(\.deletedID)
    let deletedIDs = Set(deleted)
    let samples = batch.compactMap(\.sample).filter { !deletedIDs.contains($0.external_id) }
    let content: Data
    if source == "apple_health" && !stableBatchID {
      content = try encoder.encode(batch)
    } else {
      encoder.outputFormatting = .sortedKeys
      content = try encoder.encode(HealthBatchRequest(
        batch_id: "", source: source, samples: samples, deleted_ids: deleted
      ))
    }
    let batchID = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
    let request = HealthBatchRequest(
      batch_id: batchID, source: source, samples: samples, deleted_ids: deleted
    )
    return try await client.send(
      "/v1/health/sync/batch", method: "POST", body: encoder.encode(request),
      redirectDelegate: redirectDelegate
    )
  }

  private func flush(client: APIClient, namespace: String) async throws {
    while true {
      let pending = try await HealthOutboxDB.shared.peek(HealthMetricChange.self,
        namespace: namespace, kind: "metrics", limit: 100)
      guard !pending.isEmpty else { return }
      _ = try await upload(pending.map(\.value), client: client)
      try await HealthOutboxDB.shared.acknowledge(pending.map(\.id))
    }
  }

}

#if DEBUG && targetEnvironment(simulator)
extension HealthMetricsSync {
  func importDebugFixture(_ data: Data, client: APIClient?) async throws -> String {
    guard !debugImportRunning else {
      throw APIClient.APIError.message("已有导入正在进行。")
    }
    debugImportRunning = true
    defer { debugImportRunning = false }
    guard HKHealthStore.isHealthDataAvailable() else {
      throw APIClient.APIError.message("此模拟器不支持 HealthKit。")
    }

    let nutrition: [HKQuantityTypeIdentifier] = [
      .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates
    ]
    let types = sampleTypes + nutrition.compactMap { HKObjectType.quantityType(forIdentifier: $0) }
    let parsed = try DebugHealthFixture.parse(data, types: types)
    let groups = Dictionary(grouping: parsed.rows, by: { $0.sample.sampleType })
    let ledgerKey = "wbDebugHealthImportedIDs-v1"
    var ledger = Set(UserDefaults.standard.stringArray(forKey: ledgerKey) ?? [])
    var written = 0, skipped = 0, failed = 0, read = 0, uploaded = 0
    var issues: [String] = []
    var changes: [HealthMetricChange] = []

    if !groups.isEmpty {
      try await store.requestAuthorization(toShare: Set(groups.keys),
        read: Set(groups.keys.map { $0 as HKObjectType }))
    }

    for (type, rows) in groups.sorted(by: { $0.key.identifier < $1.key.identifier }) {
      for offset in stride(from: 0, to: rows.count, by: 100) {
        let chunk = rows[offset..<min(offset + 100, rows.count)]
        let idPredicate = HKQuery.predicateForObjects(
          withMetadataKey: Self.fixtureMetadataKey, allowedValues: chunk.map(\.id))
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
          idPredicate, HKQuery.predicateForObjects(from: .default())
        ])
        do {
          // Recover saves that completed before the local ledger was persisted.
          let existing = try await fetch(type: type, anchor: nil, predicate: predicate)
          let recovered = Set(existing.samples.compactMap {
            $0.metadata?[Self.fixtureMetadataKey] as? String
          }).subtracting(ledger)
          if !recovered.isEmpty {
            ledger.formUnion(recovered)
            UserDefaults.standard.set(Array(ledger), forKey: ledgerKey)
          }
        } catch {
          issues.append("检查已有样本失败：\(error.localizedDescription)")
        }
        for row in chunk {
          if ledger.contains(row.id) {
            skipped += 1
            continue
          }
          guard store.authorizationStatus(for: type) == .sharingAuthorized else {
            failed += 1
            let issue = "未获写入权限：\(type.identifier)"
            if !issues.contains(issue) { issues.append(issue) }
            continue
          }
          do {
            try await store.save(row.sample)
            written += 1
            ledger.insert(row.id)
            UserDefaults.standard.set(Array(ledger), forKey: ledgerKey)
          } catch {
            failed += 1
            let issue = "写入失败（\(type.identifier)）：\(error.localizedDescription)"
            if !issues.contains(issue) { issues.append(issue) }
          }
        }
        do {
          var anchor: HKQueryAnchor?
          repeat {
            let page = try await fetch(type: type, anchor: anchor, predicate: predicate)
            read += page.samples.count
            changes += page.samples.compactMap { metric(from: $0) }.map {
              HealthMetricChange(sample: $0, deletedID: nil)
            }
            anchor = page.samples.count + page.deleted.count >= maxPageSize ? page.anchor : nil
          } while anchor != nil
        } catch {
          issues.append("读取失败（\(type.identifier)）：\(error.localizedDescription)")
        }
      }
    }

    if !changes.isEmpty {
      if let client, let url = URL(string: client.server), url.scheme == "http",
         url.host == "127.0.0.1" {
        changes.sort { ($0.sample?.external_id ?? "") < ($1.sample?.external_id ?? "") }
        do {
          for offset in stride(from: 0, to: changes.count, by: 100) {
            let receipt = try await upload(
              Array(changes[offset..<min(offset + 100, changes.count)]), client: client,
              source: "apple_health_debug_fixture", redirectDelegate: DebugHealthNoRedirects())
            uploaded += receipt.received ?? (receipt.inserted + receipt.updated)
          }
        } catch {
          issues.append("上传失败：\(error.localizedDescription)。可重新选择同一文件重试。")
        }
      } else {
        issues.append("未上传：请连接 127.0.0.1 的本机测试后台，再选择同一文件。")
      }
    }
    if read < written + skipped {
      issues.append("部分已导入样本未读到；请检查读取权限及样本是否仍在健康 App 中。")
    }
    return ([
      "写入 \(written) 条 · 读取 \(read) 条 · 后台确认收到 \(uploaded) 条",
      "已导入 \(skipped) 条 · 文件内重复 \(parsed.repeated) 条 · 不支持 \(parsed.unsupported) 条 · 格式无效 \(parsed.invalid) 条 · 写入失败 \(failed) 条"
    ] + issues).joined(separator: "\n")
  }
}
#endif
