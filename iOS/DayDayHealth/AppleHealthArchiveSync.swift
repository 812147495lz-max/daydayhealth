import CryptoKit
import HealthKit
import OSLog
import SwiftUI
import UIKit

enum AppleHealthArchiveFiles {
  static func directory() throws -> URL {
    var directory = URL.applicationSupportDirectory.appending(path: "AppleHealthArchive", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var attributes = URLResourceValues()
    attributes.isExcludedFromBackup = true
    try directory.setResourceValues(attributes)
    return directory
  }
}

final class AppleHealthArchiveAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions options:
                   [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    AppleHealthArchiveSync.shared.connectionChanged()
    return true
  }

  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                   completionHandler: @escaping () -> Void) {
    let sync = AppleHealthArchiveSync.shared
    guard identifier == sync.sessionID else { completionHandler(); return }
    sync.backgroundCompletion = completionHandler
    sync.connectionChanged()
    sync.connectSession()
  }
}

@MainActor
final class AppleHealthArchiveSync: NSObject, ObservableObject, URLSessionDataDelegate {
  static let shared = AppleHealthArchiveSync()
  static let path = "/api/v1/healthkit-archive"

  @Published private(set) var enabled = false
  @Published private(set) var authorizing = false
  @Published private(set) var authorizationMessage: String?

  static let setupHealthKey = "wbHealthArchive.firstSetupHealth"
  private var attemptedInitialAuthorization = false
  private let log = Logger(subsystem: "DayDayHealth", category: "HealthArchive")

  let sessionID = (Bundle.main.bundleIdentifier ?? "DayDayHealth") + ".healthkit-archive"
  var backgroundCompletion: (() -> Void)?
  private let store = HKHealthStore()
  private let reader = AppleHealthArchiveReader.shared
  private let queue = HealthOutboxDB.archive
  private let defaults = UserDefaults.standard
  private var observers: [HKObserverQuery] = []
  private var account: String?
  private var collection: Task<Void, Never>?
  private var pendingTypes = Set<String>()
  private var uploadPreparation: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?
  private var finishing = 0
  private var foreground = false
  private var cleanupComplete = false
  private var changedCredentials: String?
  private var bodies: [Int: Data] = [:]

  private struct Identity: Decodable { let instance_id: UUID }
  private struct BatchReceipt: Decodable { let received: Int; let sha256: String }
  private struct ChunkReceipt: Decodable { let offset: Int; let complete: Bool }
  private struct Upload: Codable {
    let account: String
    let generation: String
    let ids: [Int64]
    let filename: String
    let digest: String
    var total: Int? = nil
    var offset: Int? = nil
  }

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.background(withIdentifier: sessionID)
    config.sessionSendsLaunchEvents = true
    config.timeoutIntervalForResource = 24 * 3600
    config.timeoutIntervalForRequest = 60
    config.httpCookieStorage = nil
    let delegateQueue = OperationQueue.main
    return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
  }()

  func connectSession() { _ = session }

  private var credentials: FNOSWorkoutCredentials? {
    guard let value = KeychainStore.loadFNOS(), value.mustChangePassword != true,
          value.userID != nil, URL(string: value.server)?.scheme == "https" else { return nil }
    return value
  }

  private func key(_ name: String, _ account: String) -> String { "wbHealthArchive." + name + "." + account }
  private var generation: String? { account.flatMap { defaults.string(forKey: key("remote", $0)) } }

  func connectionChanged() {
    let credentials = credentials
    let current = credentials?.client.cacheAccount
    let token = credentials?.token
    if account == current {
      if changedCredentials != token, let current {
        changedCredentials = token
        clearRetry(current)
        retryTask?.cancel()
        retryTask = nil
        upload()
      }
      return
    }
    changedCredentials = token
    let previous = account
    account = current
    enabled = current != nil && HKHealthStore.isHealthDataAvailable()
    if let previous { cancel(account: previous) }
    if let current { clearRetry(current) }
    if enabled {
      startObservers()
      collect()
      upload()
    } else {
      connectSession()
    }
  }

  func requestInitialAuthorization() async {
    guard !attemptedInitialAuthorization, !defaults.bool(forKey: Self.setupHealthKey) else { return }
    attemptedInitialAuthorization = true
    await refreshAuthorization()
  }

  func runBackgroundRefresh() async {
    refresh()
    await withTaskCancellationHandler {
      await collection?.value
      await uploadPreparation?.value
    } onCancel: {
      Task { @MainActor in
        self.collection?.cancel()
        self.uploadPreparation?.cancel()
      }
    }
  }

  func refreshAuthorization() async {
    guard HKHealthStore.isHealthDataAvailable(), !authorizing else { return }
    authorizing = true
    authorizationMessage = nil
    defer { authorizing = false }
    do {
      try await reader.authorize()
      defaults.set(true, forKey: Self.setupHealthKey)
      if let account { restartHistory(account) }
    } catch {
      authorizationMessage = "无法请求 Apple 健康权限，请检查 App 签名和系统设置。"
    }
  }

  private func restartHistory(_ account: String) {
    defaults.set(UUID().uuidString, forKey: key("cursorEpoch", account))
    if let collection {
      collection.cancel()
      Task {
        await collection.value
        guard enabled, self.account == account else { return }
        refresh(force: true)
      }
    } else {
      refresh(force: true)
    }
  }

  func authorizeClinical() async {
    guard enabled, let account, !authorizing else { return }
    authorizing = true
    authorizationMessage = nil
    defer { authorizing = false }
    do {
      try await reader.authorizeClinicalRecords()
      guard self.account == account, enabled else { return }
      defaults.set(true, forKey: key("clinical", account))
      startObservers()
      restartHistory(account)
    } catch { authorizationMessage = "无法请求临床健康记录权限，请检查设备和 App 签名。" }
  }

  func authorizePrescriptions() async {
    guard enabled, let account, !authorizing else { return }
    authorizing = true
    authorizationMessage = nil
    defer { authorizing = false }
    do {
      try await reader.collectPrescriptions(namespace: account)
      upload()
    } catch { authorizationMessage = "暂时无法访问眼镜处方，请稍后重试。" }
  }

  @available(iOS 26.0, *)
  func authorizeMedications() async {
    guard enabled, let account, !authorizing else { return }
    authorizing = true
    authorizationMessage = nil
    defer { authorizing = false }
    do {
      try await reader.authorizeMedications()
      guard self.account == account, enabled else { return }
      restartHistory(account)
    } catch { authorizationMessage = "暂时无法访问用药记录，请稍后重试。" }
  }

  func authorizeClinicalDocuments() async {
    guard enabled, let account, !authorizing else { return }
    authorizing = true
    authorizationMessage = nil
    defer { authorizing = false }
    do {
      try await reader.collectClinicalDocuments(namespace: account)
      upload()
    } catch { authorizationMessage = "暂时无法访问医疗文件，请稍后重试。" }
  }

  func setForeground(_ active: Bool) {
    foreground = active
    if active { refresh() }
  }

  func refresh(force: Bool = false) {
    connectionChanged()
    guard enabled, let account else { return }
    if force {
      clearRetry(account)
      retryTask?.cancel()
      retryTask = nil
    }
    collect()
    upload()
  }

  private func startObservers() {
    guard let account, HKHealthStore.isHealthDataAvailable() else { return }
    let registered = Set(observers.compactMap { $0.objectType?.identifier })
    let clinical = defaults.bool(forKey: key("clinical", account))
    for type in AppleHealthArchiveReader.sampleTypes where
      !registered.contains(type.identifier) && !type.requiresPerObjectAuthorization()
      && !(type is HKCorrelationType) && (clinical || !(type is HKClinicalType)) {
      let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, error in
        Task { @MainActor in
          defer { completion() }
          guard let self, self.enabled, error == nil else { return }
          self.pendingTypes.insert(type.identifier)
          if let collection = self.collection { await collection.value }
          self.collect()
          await self.collection?.value
          self.upload()
        }
      }
      observers.append(query)
      store.execute(query)
      store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
    }
  }

  private func cancel(account: String) {
    collection?.cancel()
    uploadPreparation?.cancel()
    retryTask?.cancel()
    retryTask = nil
    for observer in observers { store.stop(observer) }
    observers.removeAll()
    pendingTypes.removeAll()
    Task {
      for task in await session.allTasks where descriptor(task)?.account == account {
        task.cancel()
      }
    }
  }

  private func collect() {
    guard collection == nil, enabled, let namespace = account else { return }
    let dirty = pendingTypes
    pendingTypes.removeAll()
    collection = Task {
      defer {
        collection = nil
        if enabled && (self.account != namespace || !pendingTypes.isEmpty) { collect() }
      }
      do {
        let cursorEpoch = defaults.string(forKey: key("cursorEpoch", namespace)) ?? "initial"
        let result = try await reader.collect(namespace: namespace, generation: cursorEpoch,
          dirty: dirty, timeLimit: foreground ? 20 : 8,
          includeClinical: defaults.bool(forKey: key("clinical", namespace)))
        guard !Task.isCancelled, enabled, self.account == namespace else { return }
        if result.failures > 0 {
          log.warning("Some HealthKit queries failed and will be retried")
        }
        upload()
      } catch is CancellationError {
      } catch {
        log.error("Unable to collect HealthKit records")
      }
    }
  }

  private func request(_ suffix: String, method: String, credentials: FNOSWorkoutCredentials) throws -> URLRequest {
    var request = try credentials.client.makeRequest(Self.path + suffix, method: method)
    credentials.authorize(&request)
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }

  private func resolveGeneration(_ account: String) async throws -> String {
    if let generation { return generation }
    guard let credentials, credentials.client.cacheAccount == account else { throw CancellationError() }
    let (data, response) = try await URLSession.shared.data(
      for: request("/identity", method: "GET", credentials: credentials), delegate: RejectHTTPRedirects())
    guard self.account == account, enabled else { throw CancellationError() }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      throw APIClient.APIError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
    let identity = try JSONDecoder().decode(Identity.self, from: data).instance_id.uuidString.lowercased()
    defaults.set(identity, forKey: key("remote", account))
    return identity
  }

  private func upload() {
    guard enabled, uploadPreparation == nil, finishing == 0, let account,
          let credentials else { return }
    if let date = defaults.object(forKey: key("retryAt", account)) as? Date, date > .now {
      scheduleRetry(date)
      return
    }
    uploadPreparation = Task {
      defer {
        uploadPreparation = nil
        if enabled, self.account != account { upload() }
      }
      do {
        let active = await session.allTasks
        if !cleanupComplete, finishing == 0 {
          try cleanupUploadFiles(keeping: Set(active.compactMap { descriptor($0)?.filename }))
          cleanupComplete = true
        }
        guard !active.contains(where: { descriptor($0)?.account == account }), finishing == 0 else { return }
        let rows = try await queue.peekArchive(AppleHealthArchiveRecord.self, namespace: account,
                                              kind: AppleHealthArchiveReader.queueKind)
        guard !rows.isEmpty, enabled, self.account == account else { return }
        let generation = try await resolveGeneration(account)
        guard enabled, self.account == account else { return }
        try Task.checkCancellation()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(rows[0].value)
        let filename = UUID().uuidString + ".upload"
        let prefix = "/" + generation
        let payload: Data
        let upload: Upload
        var request: URLRequest
        if first.count > 1024 * 1024 - 2 {
          let digest = Self.hash(first)
          let offset = defaults.integer(forKey: key("offset." + digest, account + "/" + generation))
          guard first.count <= 512 * 1024 * 1024, offset >= 0, offset < first.count else {
            throw APIClient.APIError.httpStatus(413)
          }
          payload = first.subdata(in: offset..<min(first.count, offset + 512 * 1024))
          upload = Upload(account: account, generation: generation, ids: [rows[0].id],
                          filename: filename, digest: digest, total: first.count, offset: offset)
          request = try self.request(prefix + "/records/" + digest + "/chunks/\(offset)?total=\(first.count)",
                                     method: "PUT", credentials: credentials)
          request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        } else {
          var batch = Data("[".utf8)
          var ids: [Int64] = []
          for row in rows {
            let encoded = ids.isEmpty ? first : try encoder.encode(row.value)
            guard batch.count + encoded.count + 2 <= 1024 * 1024 else { break }
            if !ids.isEmpty { batch.append(44) }
            batch.append(encoded)
            ids.append(row.id)
          }
          batch.append(93)
          payload = batch
          upload = Upload(account: account, generation: generation, ids: ids, filename: filename, digest: Self.hash(batch))
          request = try self.request(prefix + "/batches", method: "POST", credentials: credentials)
          request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let file = try AppleHealthArchiveFiles.directory().appending(path: filename)
        let description = try JSONEncoder().encode(upload).base64EncodedString()
        try payload.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = description
        task.resume()
      } catch is CancellationError {
      } catch APIClient.APIError.httpStatus(let status) {
        failed(status, account: account)
      } catch {
        failed(0, account: account)
      }
    }
  }

  private func cleanupUploadFiles(keeping names: Set<String>) throws {
    let directory = try AppleHealthArchiveFiles.directory()
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      where file.pathExtension == "upload" && !names.contains(file.lastPathComponent) {
      try FileManager.default.removeItem(at: file)
    }
  }

  private static func hash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func descriptor(_ task: URLSessionTask) -> Upload? {
    task.taskDescription.flatMap { Data(base64Encoded: $0) }.flatMap { try? JSONDecoder().decode(Upload.self, from: $0) }
  }

  nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    MainActor.assumeIsolated {
      let id = dataTask.taskIdentifier
      if (bodies[id]?.count ?? 0) + data.count <= 4096 { bodies[id, default: Data()].append(data) }
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    MainActor.assumeIsolated {
      let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
      guard let upload = descriptor(task) else { return }
      finishing += 1
      Task {
        await complete(upload, task: task, body: body, error: error)
        finishing -= 1
        self.upload()
        await uploadPreparation?.value
        finishBackgroundEvents()
      }
    }
  }

  private var backgroundEventsFinished = false

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    MainActor.assumeIsolated {
      backgroundEventsFinished = true
      finishBackgroundEvents()
    }
  }

  private func finishBackgroundEvents() {
    guard backgroundEventsFinished, finishing == 0, let completion = backgroundCompletion else { return }
    backgroundEventsFinished = false
    backgroundCompletion = nil
    completion()
  }

  private func complete(_ upload: Upload, task: URLSessionTask, body: Data, error: Error?) async {
    if let directory = try? AppleHealthArchiveFiles.directory() {
      try? FileManager.default.removeItem(at: directory.appending(path: upload.filename))
    }
    guard account == upload.account, enabled else { return }
    let response = task.response as? HTTPURLResponse
    let status = response?.statusCode ?? 0
    if (error as? URLError)?.code == .cancelled { return }
    if status == 401 || status == 403,
       let token = credentials?.token,
       task.originalRequest?.value(forHTTPHeaderField: "Authorization") != "Bearer " + token { return }
    if status == 409, upload.offset != nil {
      defaults.removeObject(forKey: key("offset." + upload.digest, upload.account + "/" + upload.generation))
    }
    guard error == nil, status == 200, response?.url == task.originalRequest?.url else {
      failed(status, account: upload.account, retryAfter: response?.value(forHTTPHeaderField: "Retry-After"))
      return
    }
    do {
      if let total = upload.total, let offset = upload.offset {
        let receipt = try JSONDecoder().decode(ChunkReceipt.self, from: body)
        guard receipt.offset != offset, receipt.offset >= 0, receipt.offset <= total, receipt.complete == (receipt.offset == total),
              receipt.complete || receipt.offset % (512 * 1024) == 0 else { throw CocoaError(.fileReadCorruptFile) }
        let key = key("offset." + upload.digest, upload.account + "/" + upload.generation)
        if !receipt.complete {
          defaults.set(receipt.offset, forKey: key)
          clearRetry(upload.account)
          return
        }
        defaults.removeObject(forKey: key)
      } else {
        let receipt = try JSONDecoder().decode(BatchReceipt.self, from: body)
        guard receipt.received == upload.ids.count, receipt.sha256 == upload.digest else {
          throw CocoaError(.fileReadCorruptFile)
        }
      }
      try await queue.acknowledge(upload.ids)
      guard account == upload.account, enabled else { return }
      clearRetry(upload.account)
    } catch {
      failed(0, account: upload.account)
    }
  }

  private func clearRetry(_ account: String) {
    defaults.removeObject(forKey: key("retryAt", account))
    defaults.removeObject(forKey: key("attempts", account))
  }

  private func failed(_ status: Int, account: String, retryAfter: String? = nil) {
    guard self.account == account, enabled else { return }
    if status == 412 {
      defaults.removeObject(forKey: key("remote", account))
      defaults.set(UUID().uuidString, forKey: key("cursorEpoch", account))
      collect()
    }
    log.warning("Health archive request failed (status \(status, privacy: .public))")
    let attempts = key("attempts", account)
    let count = min(defaults.integer(forKey: attempts), 3)
    let delays: [TimeInterval] = [30, 120, 600, 1800]
    var delay = delays[count] * Double.random(in: 1...1.2)
    if let retryAfter {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      if let seconds = TimeInterval(retryAfter), seconds.isFinite { delay = max(delay, seconds) }
      else if let date = formatter.date(from: retryAfter) { delay = max(delay, date.timeIntervalSinceNow) }
    }
    if [401, 403, 404, 413, 422].contains(status) { delay = max(1800, delay) }
    let next = Date.now.addingTimeInterval(min(24 * 3600, delay))
    defaults.set(count + 1, forKey: attempts)
    defaults.set(next, forKey: key("retryAt", account))
    scheduleRetry(next)
  }

  private func scheduleRetry(_ date: Date) {
    guard retryTask == nil else { return }
    retryTask = Task {
      do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) }
      catch { return }
      retryTask = nil
      refresh()
    }
  }
}
