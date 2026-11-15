import Foundation
import OSLog

struct APIClient {
  let server: String
  let apiKey: String
  var workoutCredentials: FNOSWorkoutCredentials? = nil

  static func validServer(_ value: String) -> Bool {
    guard let url = URL(string: value), let host = url.host, !host.isEmpty,
      url.user == nil, url.password == nil else { return false }
    if url.scheme == "https" { return true }
    #if (targetEnvironment(macCatalyst) || targetEnvironment(simulator)) && DEBUG
    return url.scheme == "http" && host == "127.0.0.1"
    #else
    return false
    #endif
  }

  enum APIError: LocalizedError {
    case invalidServer
    case httpStatus(Int)
    case passwordChangeRequired
    case message(String)
    var errorDescription: String? {
      switch self {
      case .invalidServer:
        return "请输入 HTTPS 服务地址"
      case .httpStatus(let code):
        switch code {
        case 401: return "连接密码不正确，请重新填写。"
        case 403: return "需要后台管理密码，请在高级选项中填写后重试。"
        case 404: return "后台地址不正确，或后台版本过旧，请更新后台。"
        case 503: return "后台还没配置好，请检查后台的连接密码和 AI 模型设置。"
        default: return "后台暂时无法处理请求（\(code)），请稍后重试。"
        }
      case .passwordChangeRequired:
        return "请先修改后端账号密码。"
      case .message(let text):
        return text
      }
    }
  }

  func makeRequest(
    _ path: String, method: String, body: Data? = nil
  ) throws -> URLRequest {
    guard Self.validServer(server), let base = URL(string: server),
      let host = base.host, !host.isEmpty,
      let url = URL(string: path, relativeTo: base)?.absoluteURL,
      url.host == host else { throw APIError.invalidServer }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 90
    request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  func send<T: Decodable>(
    _ path: String,
    method: String = "GET",
    body: Data? = nil,
    redirectDelegate: URLSessionTaskDelegate? = nil
  ) async throws -> T {
    let request = try makeRequest(path, method: method, body: body)
    let (data, response) = try await URLSession.shared.data(for: request, delegate: redirectDelegate)
    guard let http = response as? HTTPURLResponse,
       (200..<300).contains(http.statusCode) else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      if code == 400 || code == 502,
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let detail = object["detail"] as? String,
        detail.range(of: "[\\p{Han}]", options: .regularExpression) != nil {
        throw APIError.message(detail)
      }
      if code == 422 { throw APIError.message("填写的内容格式不正确，请检查接口地址和模型名称。") }
      throw APIError.httpStatus(code)
    }
    return try JSONDecoder().decode(T.self, from: data)
  }
}

struct APIEmptyResult: Decodable {
  let id: Int?
}
struct NotificationChanges: Decodable {
  struct Command: Decodable {
    let id: Int
    let task_id: Int?
    let command: String
    let title: String
    let fire_epoch: Int
    let notification_key: String
  }
  let cursor: Int
  let commands: [Command]
}
struct NotificationReceiptResult: Decodable {
  let saved: Bool
}
struct WorkoutUploadResult: Decodable {
  let id: Int
  let created: Bool
}
struct SupervisorSummary: Codable {
  let recorded_sessions: Int
  let completion_certainty: String
  let goals: [GoalSummary]
}
struct GoalSummary: Codable {
  let title: String
  let target: Int
  let observed: Int?
}


struct ServerInstance: Decodable {
  let instance_id: String
}

struct NotificationState: Decodable {
  let instance_id: String
  let commands: [NotificationChanges.Command]
}

struct DeviceEnrollment: Decodable {
  let device_id: String
  let token: String
}

private func fnosErrorCode(in data: Data, is code: String) -> Bool {
  guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  else { return false }
  let error = body["error"] as? [String: Any]
  let detail = body["detail"] as? [String: Any]
  return [error?["code"], body["code"], body["detail"], detail?["code"]]
    .contains { ($0 as? String) == code }
}

struct FNOSWorkoutCredentials: Codable {
  let server: String
  let token: String
  let clientID: String?
  let clientSecret: String?
  var userID: String? = nil
  var username: String? = nil
  var lastLoginAt: String? = nil
  var anomaly: Bool? = nil
  var mustChangePassword: Bool? = nil

  func authorize(_ request: inout URLRequest) {
    request.setValue(nil, forHTTPHeaderField: "X-API-Key")
    request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    request.setValue(clientID, forHTTPHeaderField: "CF-Access-Client-Id")
    request.setValue(clientSecret, forHTTPHeaderField: "CF-Access-Client-Secret")
  }

  enum PasswordError: Error {
    case currentPassword
    case invalidResponse
  }

  func changePassword(
    current: String, new: String, session: URLSession = .shared
  ) async throws {
    var request = try client.makeRequest("/api/v1/auth/change-password", method: "POST",
      body: JSONEncoder().encode(["current_password": current, "new_password": new]))
    guard request.url?.scheme == "https" else { throw APIClient.APIError.invalidServer }
    authorize(&request)
    let (data, response) = try await session.data(
      for: request, delegate: RejectHTTPRedirects()
    )
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    if status == 401 {
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let error = body?["error"] as? [String: Any]
      if error?["code"] as? String != "unauthorized" { throw PasswordError.currentPassword }
    }
    if status == 403, fnosErrorCode(in: data, is: "password_change_required") {
      throw APIClient.APIError.passwordChangeRequired
    }
    guard status == 200 else { throw APIClient.APIError.httpStatus(status) }
    struct Receipt: Decodable { let changed: Bool }
    guard try JSONDecoder().decode(Receipt.self, from: data).changed else {
      throw PasswordError.invalidResponse
    }
  }

  var client: APIClient {
    APIClient(server: server, apiKey: "", workoutCredentials: self)
  }
}

extension APIClient {
  var cacheAccount: String {
    if let credentials = workoutCredentials {
      let identity = credentials.userID.map { "user:" + $0 } ?? credentials.token
      return LocalCache.namespace("fnos\n" + server + "\n" + identity)
    }
    #if targetEnvironment(simulator) && DEBUG
    if workoutMockJSON != nil { return LocalCache.namespace("mock\n" + server + "\n" + apiKey) }
    #endif
    return LocalCache.namespace(server + "\n" + apiKey)
  }

  #if targetEnvironment(simulator) && DEBUG
  private var workoutMockJSON: String? {
    guard server == LocalTestConfiguration.address else { return nil }
    return ProcessInfo.processInfo.environment["WB_WORKOUT_SYNC_MOCK_JSON"]
  }
  #endif

  func workoutSyncPage(
    cursor: String?, session: URLSession = .shared
  ) async throws -> WorkoutSyncPage {
    #if targetEnvironment(simulator) && DEBUG
    if let fixture = workoutMockJSON {
      return try WorkoutSyncPage.decode(Data(fixture.utf8))
    }
    #endif
    var query = URLComponents()
    query.path = "/api/v1/workouts/sync"
    query.queryItems = [URLQueryItem(name: "limit", value: "100")]
    if let cursor { query.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
    // A literal plus must survive form-style decoding on the server.
    let path = query.string?.replacingOccurrences(of: "+", with: "%2B") ?? query.path
    var request = try makeRequest(path, method: "GET")
    if let credentials = workoutCredentials {
      guard request.url?.scheme == "https" else { throw APIError.invalidServer }
      credentials.authorize(&request)
    }
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let (data, response) = try await session.data(
      for: request, delegate: RejectHTTPRedirects()
    )
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      if status == 400, fnosErrorCode(in: data, is: "cursor_invalid") {
        throw WorkoutSyncError.invalidCursor
      }
      if status == 403, fnosErrorCode(in: data, is: "password_change_required") {
        throw APIError.passwordChangeRequired
      }
      throw APIError.httpStatus(status)
    }
    return try WorkoutSyncPage.decode(data)
  }
}

struct BackendConnection: Codable, Equatable {
  let loginServer: String
  let dataServer: String
  let requiresCloudflareAccess: Bool

  static func origin(address: String, port: String) throws -> String {
    let address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = address.contains("://") ? address : "https://" + address
    guard var parts = URLComponents(string: url),
          parts.scheme?.lowercased() == "https",
          let host = parts.host, !host.isEmpty,
          host.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
          parts.user == nil, parts.password == nil,
          parts.path.isEmpty || parts.path == "/",
          parts.query == nil, parts.fragment == nil,
          parts.rangeOfPort == nil || parts.port != nil else {
      throw APIClient.APIError.message("请输入 HTTPS 后端地址，可带端口。")
    }
    if !port.isEmpty {
      guard port.utf8.allSatisfy({ (48...57).contains($0) }),
            let value = Int(port), (1...65535).contains(value) else {
        throw APIClient.APIError.message("端口必须是 1 至 65535。")
      }
      guard parts.port == nil || parts.port == value else {
        throw APIClient.APIError.message("地址中的端口与端口栏不一致。")
      }
      parts.port = value
    }
    if let value = parts.port, !(1...65535).contains(value) {
      throw APIClient.APIError.message("端口必须是 1 至 65535。")
    }
    if parts.port == 443 { parts.port = nil }
    parts.scheme = "https"
    parts.host = host.lowercased()
    parts.path = ""
    guard let result = parts.url?.absoluteString else { throw APIClient.APIError.invalidServer }
    return result
  }

  static func fields(for origin: String) -> (address: String, port: String) {
    guard var parts = URLComponents(string: origin) else { return (origin, "") }
    let port = parts.port.map(String.init) ?? ""
    parts.port = nil
    return (parts.string ?? origin, port)
  }

  var loginClient: FNOSLoginClient {
    FNOSLoginClient(loginServer: loginServer, dataServer: dataServer,
                    requiresCloudflareAccess: requiresCloudflareAccess)
  }
}

struct FNOSLoginClient {
  let loginServer: String
  let dataServer: String
  var requiresCloudflareAccess = true

  static let diagnostics = Logger(subsystem: "DayDayHealth", category: "FNOSLogin")

  enum LoginError: Error {
    case invalidResponse
    case accessNotConfigured
    case missingToken
    case setupRequired
    case alreadySet
    case whitelistUnavailable
  }

  private struct CredentialsRequest: Encodable {
    let username: String
    let password: String
    let device_name = "iphone"
  }

  private struct CredentialsResponse: Decodable {
    let token: String?
    let user_id: String?
    let username: String?
    let cf_access_client_id: String?
    let cf_access_client_secret: String?
    let last_login_at: String?
    let anomaly: Bool?
    let must_change_password: Bool?

    private enum CodingKeys: String, CodingKey {
      case token, user_id, username, cf_access_client_id, cf_access_client_secret
      case last_login_at, anomaly, must_change_password
    }

    init(from decoder: Decoder) throws {
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      token = try fields.decodeIfPresent(String.self, forKey: .token)
      cf_access_client_id = try fields.decodeIfPresent(String.self, forKey: .cf_access_client_id)
      cf_access_client_secret = try fields.decodeIfPresent(
        String.self, forKey: .cf_access_client_secret
      )
      user_id = try? fields.decode(String.self, forKey: .user_id)
      username = try? fields.decode(String.self, forKey: .username)
      last_login_at = try? fields.decode(String.self, forKey: .last_login_at)
      anomaly = try? fields.decode(Bool.self, forKey: .anomaly)
      must_change_password = try fields.decodeIfPresent(Bool.self, forKey: .must_change_password)
    }
  }

  private static func describeResponse(_ data: Data) -> String {
    guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
      return "not a JSON object"
    }
    let keys = ["token", "cf_access_client_id", "cf_access_client_secret", "user_id",
                "schema_version", "token_type", "anomaly", "must_change_password"]
    return keys.map { key in
      let shape: String
      switch body[key] {
      case nil: shape = "missing"
      case is NSNull: shape = "null"
      case let value as String: shape = value.isEmpty ? "empty string" : "string"
      case is NSNumber: shape = "number or boolean"
      default: shape = "other"
      }
      return key + "=" + shape
    }.joined(separator: ", ")
  }

  static func decodingPath(_ error: DecodingError) -> String {
    let path: [any CodingKey]
    switch error {
    case let .keyNotFound(key, context): path = context.codingPath + [key]
    case let .typeMismatch(_, context), let .valueNotFound(_, context),
         let .dataCorrupted(context): path = context.codingPath
    @unknown default: path = []
    }
    return path.isEmpty ? "<root>" : path.map(\.stringValue).joined(separator: ".")
  }

  func login(
    username: String, password: String, session: URLSession = .shared
  ) async throws -> FNOSWorkoutCredentials {
    try await authenticate(
      path: "/api/v1/auth/login", username: username,
      body: JSONEncoder().encode(CredentialsRequest(username: username, password: password)),
      session: session
    )
  }

  func setupPassword(
    username: String, password: String, session: URLSession = .shared
  ) async throws -> FNOSWorkoutCredentials {
    try await authenticate(
      path: "/api/v1/auth/setup-password", username: username,
      body: JSONEncoder().encode([
        "username": username, "new_password": password, "device_name": "iphone"
      ]),
      session: session
    )
  }

  private func authenticate(
    path: String, username: String, body: Data, session: URLSession
  ) async throws -> FNOSWorkoutCredentials {
    guard APIClient.validServer(loginServer), APIClient.validServer(dataServer),
      let base = URL(string: loginServer), base.scheme == "https",
      URL(string: dataServer)?.scheme == "https",
      let url = URL(string: path, relativeTo: base)?.absoluteURL else {
      throw APIClient.APIError.invalidServer
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = body

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(
        for: request, delegate: RejectHTTPRedirects()
      )
    } catch let error as URLError {
      Self.diagnostics.error("Login transport failed: URLError \(error.code.rawValue)")
      throw error
    }
    guard let http = response as? HTTPURLResponse else { throw LoginError.invalidResponse }
    Self.diagnostics.info("Login HTTP \(http.statusCode), body bytes \(data.count)")
    if http.statusCode == 200 {
      Self.diagnostics.info("Redacted body shape: \(Self.describeResponse(data), privacy: .public)")
    }
    if http.statusCode == 409 || http.statusCode == 503 {
      let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let error = body?["error"] as? [String: Any]
      switch (http.statusCode, error?["code"] as? String) {
      case (409, "password_setup_required"): throw LoginError.setupRequired
      case (409, "password_already_set"): throw LoginError.alreadySet
      case (503, "whitelist_unavailable"): throw LoginError.whitelistUnavailable
      default: break
      }
    }
    guard http.statusCode == 200 else { throw APIClient.APIError.httpStatus(http.statusCode) }
    let result: CredentialsResponse
    do {
      result = try JSONDecoder().decode(CredentialsResponse.self, from: data)
    } catch let error as DecodingError {
      let path = Self.decodingPath(error)
      Self.diagnostics.error("Login decoding failed at \(path, privacy: .public)")
      throw error
    }
    guard let token = result.token, !token.isEmpty else { throw LoginError.missingToken }
    let id = requiresCloudflareAccess ? result.cf_access_client_id : nil
    let secret = requiresCloudflareAccess ? result.cf_access_client_secret : nil
    if requiresCloudflareAccess, id?.isEmpty != false || secret?.isEmpty != false {
      throw LoginError.accessNotConfigured
    }
    guard ([token] + [id, secret].compactMap { $0 }).allSatisfy({
      $0.utf8.allSatisfy { (33...126).contains($0) }
    }) else { throw LoginError.invalidResponse }
    return FNOSWorkoutCredentials(
      server: dataServer, token: token, clientID: id, clientSecret: secret,
      userID: result.user_id, username: result.username ?? username,
      lastLoginAt: result.last_login_at, anomaly: result.anomaly,
      mustChangePassword: result.must_change_password
    )
  }
}

final class RejectHTTPRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// Credentials for an OpenAI-compatible service, stored only in the device keychain.
enum MealModelError: LocalizedError {
  case timedOut
  case photoRejected(Int)

  var errorDescription: String? {
    switch self {
    case .timedOut: return "模型服务响应超时，请稍后重试。"
    case .photoRejected(let status):
      return "模型未接受照片（HTTP \(status)）。请确认模型支持图片。"
    }
  }
}

struct DirectModelConfiguration: Codable {
  let baseURL: String
  let model: String
  let key: String

  static func normalize(_ address: String) -> String {
    let base = address.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let suffix = "/chat/completions"
    return base.hasSuffix(suffix) ? String(base.dropLast(suffix.count)) : base
  }

  static func endpoint(_ baseURL: String) -> URL? {
    guard let parts = URLComponents(string: baseURL), parts.scheme == "https",
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil else { return nil }
    return parts.url?.appendingPathComponent("chat").appendingPathComponent("completions")
  }

  struct Message: Encodable {
    let role: String
    let content: String
    var photos: [Data] = []

    enum CodingKeys: String, CodingKey { case role, content }

    func encode(to encoder: Encoder) throws {
      struct Part: Encodable {
        let type: String
        var text: String? = nil
        var image_url: [String: String]? = nil
      }
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encode(role, forKey: .role)
      if photos.isEmpty {
        try values.encode(content, forKey: .content)
      } else {
        let parts = [Part(type: "text", text: content)] + photos.map {
          Part(type: "image_url", image_url: ["url": "data:image/jpeg;base64," + $0.base64EncodedString()])
        }
        try values.encode(parts, forKey: .content)
      }
    }
  }

  struct ToolCall: Decodable {
    let name: String
    let arguments: String
  }

  struct Completion {
    let text: String
    let reasoning: String?
  }

  struct ToolDecision {
    let completion: Completion
    let calls: [ToolCall]
  }

  private struct CompletionResponse: Decodable {
    struct Choice: Decodable {
      struct MessageBody: Decodable {
        let content: String?
        let reasoning_content: String?
        let tool_calls: [Call]?

        var completion: Completion {
          let reasoning = reasoning_content?.trimmingCharacters(in: .whitespacesAndNewlines)
          return Completion(text: content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                            reasoning: reasoning?.isEmpty == false ? reasoning : nil)
        }
      }

      struct Call: Decodable {
        let function: ToolCall
      }

      let message: MessageBody
    }

    let choices: [Choice]
  }

  func completeWithHealthTools(_ messages: [Message], maxTokens: Int? = nil,
                               session: URLSession = .shared) async throws -> ToolDecision {
    guard let url = Self.endpoint(baseURL) else { throw APIClient.APIError.invalidServer }
    let encoded = try JSONEncoder().encode(messages)
    guard let messageArray = try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]]
    else { throw APIClient.APIError.invalidServer }
    let argumentsSchema: [String: Any] = [
      "type": "object",
      "properties": [
        "records": ["type": "array", "items": ["type": "string",
          "enum": ["health", "workouts", "meals"]]],
        "start": ["type": "string", "description": "YYYY-MM-DD or all"],
        "end": ["type": "string", "description": "YYYY-MM-DD"],
        "metrics": ["type": "array", "items": ["type": "string"]]
      ],
      "required": ["records"],
      "additionalProperties": false
    ]
    func tool(_ name: String, _ description: String, _ parameters: [String: Any]) -> [String: Any] {
      ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]]
    }
    let tools = [
      tool("get_private_records", "读取已授权的个人健康、训练或饮食记录", argumentsSchema),
      tool("lookup_food_nutrition", "查找食物、菜品或指定包装食品每100克的营养参考值", [
        "type": "object",
        "properties": ["food": ["type": "string"], "english": ["type": "string"]],
        "required": ["food"], "additionalProperties": false
      ]),
      tool("calculate_bmi", "根据明确提供的公斤和厘米计算成人 BMI；不作诊断", [
        "type": "object",
        "properties": ["weight_kg": ["type": "number"], "height_cm": ["type": "number"]],
        "required": ["weight_kg", "height_cm"], "additionalProperties": false
      ])
    ]
    var body: [String: Any] = [
      "model": model, "stream": false, "messages": messageArray,
      "tool_choice": "auto", "tools": tools
    ]
    if let maxTokens { body["max_tokens"] = maxTokens }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    let includesImage = messages.contains { !$0.photos.isEmpty }
    request.timeoutInterval = includesImage ? 90 : 45
    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await session.data(
      for: request, delegate: RejectHTTPRedirects())
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
      // Some providers support images but don't support tool calling.
      if [400, 404, 415, 422, 501].contains(status) {
        let completion = try await completeReply(messages, maxTokens: maxTokens, session: session)
        return ToolDecision(completion: completion, calls: [])
      }
      try Self.validateCompletionStatus(status, includesImage: includesImage)
      throw APIClient.APIError.httpStatus(status)
    }
    guard let choice = (try? JSONDecoder().decode(CompletionResponse.self, from: data))?.choices.first else {
      throw APIClient.APIError.message("模型响应无法解析，请确认接口兼容 Chat Completions。")
    }
    let calls = choice.message.tool_calls?.prefix(4).map(\.function) ?? []
    let completion = choice.message.completion
    guard !completion.text.isEmpty || !calls.isEmpty else {
      throw APIClient.APIError.message("模型没有返回回答。")
    }
    return ToolDecision(completion: completion, calls: calls)
  }

  func complete(_ messages: [Message], maxTokens: Int? = nil,
                timeout: TimeInterval? = nil,
                session: URLSession = .shared) async throws -> String {
    let reply = try await completeReply(messages, maxTokens: maxTokens, timeout: timeout, session: session)
    return reply.text
  }

  func completeReply(_ messages: [Message], maxTokens: Int? = nil,
                     timeout: TimeInterval? = nil,
                     session: URLSession = .shared) async throws -> Completion {
    struct Payload: Encodable {
      let model: String
      let messages: [Message]
      let max_tokens: Int?
      let stream = false
    }
    let payload = try JSONEncoder().encode(
      Payload(model: model, messages: messages, max_tokens: maxTokens))
    let includesImage = messages.contains { !$0.photos.isEmpty }
    return try await complete(payload: payload, includesImage: includesImage,
                              timeout: timeout ?? (includesImage ? 90 : 45), session: session)
  }

  func completeMeal(prompt: String, photos: [Data], timeout: TimeInterval? = nil,
                    session: URLSession = .shared) async throws -> String {
    do {
      return try await complete([Message(role: "user", content: prompt, photos: photos)],
                                timeout: timeout, session: session)
    } catch let error as URLError where error.code == .timedOut {
      throw MealModelError.timedOut
    } catch APIClient.APIError.httpStatus(let status) where status == 408 || status == 504 {
      throw MealModelError.timedOut
    }
  }

  private func complete(payload: Data, includesImage: Bool = false,
                        timeout: TimeInterval, session: URLSession) async throws -> Completion {
    guard let url = Self.endpoint(baseURL) else { throw APIClient.APIError.invalidServer }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = payload
    let (data, response) = try await session.data(
      for: request, delegate: RejectHTTPRedirects()
    )
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    try Self.validateCompletionStatus(status, includesImage: includesImage)
    guard let reply = (try? JSONDecoder().decode(CompletionResponse.self, from: data))?
      .choices.first?.message.completion, !reply.text.isEmpty else {
      throw APIClient.APIError.message("模型没有返回文本，请确认接口兼容 Chat Completions。")
    }
    return reply
  }

  private static func validateCompletionStatus(_ status: Int, includesImage: Bool) throws {
    guard (200..<300).contains(status) else {
      if status == 408 || status == 504 { throw APIClient.APIError.httpStatus(status) }
      if includesImage, [400, 413, 415, 422].contains(status) {
        throw MealModelError.photoRejected(status)
      }
      let message: String
      switch status {
      case 401: message = "服务商拒绝了 API 密钥，请检查密钥。"
      case 402, 429: message = "服务商账户余额不足或调用受限，请查看账户。"
      case 403: message = "这个 API 密钥没有使用该模型的权限。"
      case 400, 404, 415, 422:
        message = includesImage
          ? "模型未接受照片（HTTP \(status)）。请确认模型支持图片。"
          : "服务商拒绝了请求，请检查接口地址和模型 ID（HTTP \(status)）。"
      default: message = "模型服务返回 HTTP \(status)，请稍后重试。"
      }
      throw APIClient.APIError.message(message)
    }
  }
}
