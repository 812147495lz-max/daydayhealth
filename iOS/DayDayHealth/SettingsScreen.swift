import SwiftUI
import UserNotifications
import UIKit

struct SettingsScreen: View {
  @ObservedObject var store: HealthStore
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.openURL) private var openURL
  @EnvironmentObject private var digest: DailyDigest
  @EnvironmentObject private var healthArchive: AppleHealthArchiveSync
  @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

  var body: some View {
    Form {
      Section("服务器") {
        NavigationLink {
          FNOSWorkoutSettings(store: store)
        } label: {
          Label(store.backendConnection != nil ? "后端已保存" : "配置后端",
                systemImage: "figure.strengthtraining.traditional")
        }
        if store.workoutAuthRequired {
          Text("登录已失效，请重新登录。").foregroundStyle(.secondary)
        }
      }

      Section {
        NavigationLink {
          ModelSettingsScreen(store: store)
        } label: {
          Label("AI 模型", systemImage: "sparkles")
        }
      }

      Section {
        Toggle("每日通知", isOn: Binding(
          get: { digest.enabled },
          set: { enabled in
            Task {
              await digest.setEnabled(enabled, store: store)
              if digest.enabled { await digest.refresh(store: store) }
              await loadNotificationStatus()
            }
          }
        ))
        if digest.enabled {
          DatePicker("通知时间", selection: Binding(get: { digest.notificationTime }, set: { time in
            digest.setTime(time)
            Task { await digest.refresh(store: store) }
          }), displayedComponents: .hourAndMinute)
        }
        if let message = digest.notificationMessage {
          Text(message).font(.footnote).foregroundStyle(.secondary)
        }
      } header: {
        Text("AI 健康日报通知")
      } footer: {
        Text("提前 30 分钟准备，完成后按时通知。系统后台唤醒延迟时，日报完成后补发。")
      }

      Section("AI 数据共享") {
        NavigationLink {
          RemoteAIDataConsentScreen()
        } label: {
          Label("允许云端 AI 使用哪些记录", systemImage: "hand.raised")
        }
      }

      Section {
        NavigationLink {
          MealGoalSettings()
        } label: {
          Label("体重与热量目标", systemImage: "target")
        }
      }

      Section {
        NavigationLink {
          AppBackupScreen()
        } label: {
          Label("备份与恢复", systemImage: "externaldrive")
        }
      }

      #if !targetEnvironment(macCatalyst)
      Section("Apple 健康权限") {
        Button("管理 Apple 健康读取权限") { Task { await healthArchive.refreshAuthorization() } }
        if healthArchive.enabled {
          Button("授权临床健康记录") { Task { await healthArchive.authorizeClinical() } }
          Button("授权医疗文件") { Task { await healthArchive.authorizeClinicalDocuments() } }
          Button("授权眼镜处方") { Task { await healthArchive.authorizePrescriptions() } }
          if #available(iOS 26.0, *) {
            Button("授权用药记录") { Task { await healthArchive.authorizeMedications() } }
          }
        }
        if let message = healthArchive.authorizationMessage { Text(message).font(.footnote) }
      }
      .disabled(healthArchive.authorizing)
      #endif

      #if DEBUG && targetEnvironment(simulator)
      Section("Debug") {
        NavigationLink("HealthKit 测试数据") {
          DebugHealthImportScreen(store: store)
        }
      }
      #endif

      Section("通知") {
        LabeledContent("系统通知", value: notificationLabel)
        if notificationStatus == .notDetermined {
          Button("开启通知") {
            Task {
              _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
              await loadNotificationStatus()
              if store.configured { await store.syncNotifications() }
            }
          }
        } else {
          Button("打开系统通知设置") {
            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
              openURL(url)
            }
          }
        }

      }

    }
    .scrollContentBackground(.hidden)
    .background(HealthTheme.background)
    .navigationTitle("设置")
    .task(id: scenePhase) {
      if scenePhase == .active { await loadNotificationStatus() }
    }
  }

  private var notificationsAllowed: Bool {
    [.authorized, .provisional, .ephemeral].contains(notificationStatus)
  }

  private var notificationLabel: String {
    if notificationsAllowed { return "已允许" }
    return notificationStatus == .denied ? "已关闭" : "未设置"
  }

  private func loadNotificationStatus() async {
    notificationStatus = await UNUserNotificationCenter.current()
      .notificationSettings().authorizationStatus
  }
}

struct FNOSWorkoutSettings: View {
  @ObservedObject var store: HealthStore
  @State private var backendAddress = ""
  @State private var backendPort = ""
  @State private var separateLogin = false
  @State private var loginAddress = ""
  @State private var loginPort = ""
  @State private var requiresCloudflareAccess = false
  @State private var username = ""
  @State private var password = ""
  @State private var connecting = false
  @State private var setup = false
  @State private var confirmation = ""
  @State private var message: String?

  var body: some View {
    Form {
      if !setup {
        Section("后端配置") {
          addressFields("后端地址", address: $backendAddress, port: $backendPort)
          Toggle("使用独立登录地址", isOn: $separateLogin)
          if separateLogin {
            addressFields("登录地址", address: $loginAddress, port: $loginPort)
          }
          Toggle("使用 Cloudflare Access", isOn: $requiresCloudflareAccess)
          Button("保存后端") { saveBackend() }
            .disabled(backendAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || ((try? enteredBackend()).map { $0 == store.backendConnection } ?? false))
        }
        .disabled(connecting)
      }
      if let credentials = KeychainStore.loadFNOS(), !store.workoutAuthRequired {
        Section {
          LabeledContent("账号", value: credentials.username ?? "已登录")
          NavigationLink("修改密码") {
            FNOSPasswordSettings(store: store, credentials: credentials)
          }
          Button("退出登录", role: .destructive) {
            do {
              try store.signOutTraining()
              message = nil
            } catch {
              message = "无法退出登录，请重试。"
            }
          }
          if let message { Text(message).font(.footnote) }
        }
      } else {
        Section {
          if setup {
            LabeledContent("账号", value: username)
            SecureField("新密码（至少 8 位）", text: $password).textContentType(.newPassword)
            SecureField("确认新密码", text: $confirmation).textContentType(.newPassword)
            if !confirmation.isEmpty && password != confirmation {
              Text("两次输入的新密码不一致。").foregroundStyle(.secondary)
            }
          } else {
            TextField("账号", text: $username)
              .keyboardType(.default).textInputAutocapitalization(.never)
              .autocorrectionDisabled()
            SecureField("密码", text: $password).textContentType(.password)
          }
        }
        Section {
          Button(connecting ? "正在验证…" : setup ? "保存密码" : "登录") {
            Task { await connect() }
          }
          .disabled(connecting
            || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (!setup && backendAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            || (setup && (password.count < 8 || password != confirmation)))
          if let message { Text(message).font(.footnote) }
        }
      }
    }
    .navigationTitle(setup ? "首次设置密码" : "后端设置")
    .onAppear(perform: loadBackendFields)
    .toolbar {
      if setup {
        Button("返回登录") {
          setup = false
          password = ""
          confirmation = ""
          message = nil
        }
        .disabled(connecting)
      }
    }
  }

  @ViewBuilder
  private func addressFields(_ label: String, address: Binding<String>, port: Binding<String>) -> some View {
    TextField(label, text: address)
      .keyboardType(.URL)
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    LabeledContent(label == "登录地址" ? "登录端口" : "端口") {
      TextField("443", text: port)
        .keyboardType(.numberPad)
        .multilineTextAlignment(.trailing)
    }
  }

  private func loadBackendFields() {
    guard let saved = store.backendConnection else { return }
    (backendAddress, backendPort) = BackendConnection.fields(for: saved.dataServer)
    (loginAddress, loginPort) = BackendConnection.fields(for: saved.loginServer)
    separateLogin = saved.loginServer != saved.dataServer
    requiresCloudflareAccess = saved.requiresCloudflareAccess
  }

  private func enteredBackend() throws -> BackendConnection {
    let data = try BackendConnection.origin(address: backendAddress, port: backendPort)
    let login = separateLogin
      ? try BackendConnection.origin(address: loginAddress, port: loginPort)
      : data
    return BackendConnection(loginServer: login, dataServer: data,
                             requiresCloudflareAccess: requiresCloudflareAccess)
  }

  private func saveBackend() {
    do {
      try store.saveTrainingBackend(enteredBackend())
      password = ""
      confirmation = ""
      loadBackendFields()
      message = "后端已保存"
    } catch { message = error.localizedDescription }
  }

  private func connect() async {
    guard !connecting else { return }
    connecting = true
    message = nil
    defer { connecting = false }
    do {
      let account = username.trimmingCharacters(in: .whitespacesAndNewlines)
      let settings: BackendConnection
      if setup, let saved = store.backendConnection {
        settings = saved
      } else {
        settings = try enteredBackend()
        try store.saveTrainingBackend(settings)
      }
      let client = settings.loginClient
      let credentials = try await (setup
        ? client.setupPassword(username: account, password: password)
        : client.login(username: account, password: password))
      password = ""
      confirmation = ""
      setup = false
      do {
        try KeychainStore.saveFNOS(credentials)
      } catch {
        let status = (error as NSError).code
        FNOSLoginClient.diagnostics.error("Login Keychain save failed: status \(status)")
        message = "登录已成功，但无法保存凭证（钥匙串错误 \(status)）。"
        return
      }
      store.restoreTrainingConnection(reauthenticated: true)
      if credentials.mustChangePassword == true { return }
      message = "登录成功。"
      FNOSLoginClient.diagnostics.info("Login credentials saved; starting workout sync")
      Task { await store.synchronizeTraining() }
    } catch FNOSLoginClient.LoginError.setupRequired {
      username = username.trimmingCharacters(in: .whitespacesAndNewlines)
      setup = true
      password = ""
      confirmation = ""
    } catch FNOSLoginClient.LoginError.alreadySet {
      setup = false
      password = ""
      confirmation = ""
      message = "该账号已设置密码，请登录。"
    } catch FNOSLoginClient.LoginError.whitelistUnavailable {
      message = "服务端白名单暂不可用，请联系管理员。"
    } catch APIClient.APIError.httpStatus(401) {
      message = "账号或密码不正确。"
    } catch APIClient.APIError.httpStatus(423) {
      message = "账号已锁定，请联系管理员解锁。解锁后可立即重试。"
    } catch APIClient.APIError.httpStatus(429) {
      message = "尝试次数过多，请联系管理员解锁。解锁后可立即重试。"
    } catch let error as URLError
      where error.code == .cannotFindHost || error.code == .dnsLookupFailed {
      message = "登录域名暂不可用，请联系后台管理员。"
    } catch APIClient.APIError.httpStatus(403) {
      message = "登录入口访问被拒绝，请联系管理员检查 Access 配置。"
    } catch APIClient.APIError.httpStatus(422) {
      message = "请检查账号和密码格式。"
    } catch FNOSLoginClient.LoginError.accessNotConfigured {
      if setup {
        setup = false
        password = ""
        confirmation = ""
      }
      message = "服务端 Access 配置未完成，请联系管理员。"
    } catch FNOSLoginClient.LoginError.missingToken {
      message = "登录接口返回成功，但响应缺少 Token，请联系管理员。"
    } catch FNOSLoginClient.LoginError.invalidResponse {
      message = "登录响应中的凭证格式不正确，请联系管理员。"
    } catch APIClient.APIError.message(let text) {
      message = text
    } catch let error as DecodingError {
      message = "无法解析登录响应（" + FNOSLoginClient.decodingPath(error) + "）。"
    } catch let error as URLError {
      message = "登录网络请求失败（\(error.code.rawValue)），请检查网络后重试。"
    } catch APIClient.APIError.httpStatus(let status) {
      message = "登录服务返回 HTTP \(status)，请稍后重试。"
    } catch {
      message = "处理登录结果失败，请稍后重试。"
    }
  }
}

struct FNOSPasswordSettings: View {
  @ObservedObject var store: HealthStore
  let credentials: FNOSWorkoutCredentials
  var required = false
  @Environment(\.dismiss) private var dismiss
  @State private var current = ""
  @State private var new = ""
  @State private var confirmation = ""
  @State private var saving = false
  @State private var message: String?

  var body: some View {
    Form {
      if required {
        Text("此账号需要修改密码，完成后才能进入主界面。")
      }
      SecureField("当前密码", text: $current).textContentType(.password)
      SecureField("新密码（至少 8 位）", text: $new).textContentType(.newPassword)
      SecureField("确认新密码", text: $confirmation).textContentType(.newPassword)
      if !confirmation.isEmpty && confirmation != new {
        Text("两次输入的新密码不一致。").foregroundStyle(.secondary)
      }
      Button(saving ? "正在保存…" : "保存") {
        Task { await save() }
      }
      .disabled(saving || current.isEmpty || new.count < 8 || new != confirmation)
      if let message { Text(message).font(.footnote) }
    }
    .navigationTitle("修改密码")
    .toolbar {
      Button(required ? "退出登录" : "取消") {
        if required {
          do { try store.signOutTraining() }
          catch { message = "无法退出登录，请重试。" }
        } else { dismiss() }
      }
      .disabled(saving)
    }
  }

  private func save() async {
    guard !saving, !current.isEmpty, new.count >= 8, new == confirmation,
      KeychainStore.loadFNOS()?.token == credentials.token else { return }
    saving = true
    defer { saving = false }
    do {
      try await credentials.changePassword(current: current, new: new)
      current = ""
      new = ""
      confirmation = ""
      if required {
        try store.completeRequiredPasswordChange(credentials)
        await store.synchronizeTraining()
      } else {
        message = "密码已修改。"
      }
    } catch APIClient.APIError.passwordChangeRequired {
      if required {
        message = "服务端仍要求修改密码，请稍后重试或联系管理员。"
      } else {
        store.requireTrainingPasswordChange(credentials)
      }
    } catch FNOSWorkoutCredentials.PasswordError.currentPassword {
      message = "当前密码不正确。"
    } catch APIClient.APIError.httpStatus(401) {
      store.expireTraining(credentials)
      dismiss()
    } catch APIClient.APIError.httpStatus(409) {
      message = "账号尚未设置密码，请联系管理员。"
    } catch APIClient.APIError.httpStatus(403) {
      message = "访问被拒绝，请联系管理员检查 Access 配置。"
    } catch APIClient.APIError.httpStatus(422) {
      message = "请检查新密码的长度和格式。"
    } catch {
      message = "暂时无法修改密码，请稍后重试。"
    }
  }
}

private enum ModelProvider: String, CaseIterable, Identifiable {
  case deepSeek = "DeepSeek"
  case openRouter = "OpenRouter"
  case custom = "自定义"

  var id: Self { self }

  var baseURL: String {
    switch self {
    case .deepSeek: "https://api.deepseek.com"
    case .openRouter: "https://openrouter.ai/api/v1"
    case .custom: ""
    }
  }

  var modelHint: String {
    switch self {
    case .deepSeek: "例如 deepseek-flash"
    case .openRouter: "服务商 / 模型 ID"
    case .custom: "填写服务商提供的模型 ID"
    }
  }

  static func detect(_ baseURL: String) -> Self {
    if ["https://api.deepseek.com", "https://api.deepseek.com/v1"].contains(baseURL) {
      return .deepSeek
    }
    return baseURL == openRouter.baseURL ? .openRouter : .custom
  }
}

struct ModelSettingsScreen: View {
  @ObservedObject var store: HealthStore
  @State private var provider: ModelProvider = .deepSeek
  @State private var address = ModelProvider.deepSeek.baseURL
  @State private var model = "deepseek-flash"
  @State private var key = ""
  @State private var busy = false
  @State private var message: String?

  private var baseURL: String { DirectModelConfiguration.normalize(address) }
  private var savedKey: String? {
    guard let saved = store.directModel, saved.baseURL == baseURL else { return nil }
    return saved.key
  }

  var body: some View {
    Form {
      Section("模型连接") {
        Picker("服务商", selection: Binding(get: { provider }, set: { select($0) })) {
          ForEach(ModelProvider.allCases) { item in Text(item.rawValue).tag(item) }
        }
        if provider == .custom {
          TextField("接口基础地址（HTTPS）", text: $address)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        } else {
          LabeledContent("接口地址", value: address)
        }
        LabeledContent("模型 ID") {
          TextField(provider.modelHint, text: $model)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
        }
        SecureField(savedKey != nil ? "API 密钥已保存，可留空" : "API 密钥", text: $key)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      }
      Section {
        Button("测试连接") { Task { await perform(test: true) } }
        Button("保存并使用") { Task { await perform(test: false) } }
        if busy { ProgressView("正在处理…") }
        if let message { Text(message) }
      }
    }
    .navigationTitle("AI 模型")
    .disabled(busy)
    .onAppear {
      if let saved = store.directModel {
        address = saved.baseURL
        model = saved.model
        provider = ModelProvider.detect(address)
      }
    }
  }

  private func select(_ item: ModelProvider) {
    guard provider != item else { return }
    provider = item
    address = item.baseURL
    model = item == .deepSeek ? "deepseek-flash" : ""
    key = ""
    message = nil
  }

  private func perform(test: Bool) async {
    guard !busy else { return }
    guard DirectModelConfiguration.endpoint(baseURL) != nil else {
      message = "请填写有效的 HTTPS 接口地址，地址中不要带账号、密码或参数。"
      return
    }
    let modelID = model.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !modelID.isEmpty else {
      message = "请填写模型 ID。"
      return
    }
    let enteredKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let secret = enteredKey.isEmpty ? (savedKey ?? "") : enteredKey
    guard !secret.isEmpty else {
      message = "请填写 API 密钥。"
      return
    }
    let configuration = DirectModelConfiguration(baseURL: baseURL, model: modelID, key: secret)
    message = nil
    busy = true
    defer { busy = false }
    do {
      if test {
        _ = try await configuration.complete([.init(role: "user", content: "请简短回复：你好")])
        message = "测试通过"
      } else {
        try store.saveDirectModel(configuration)
        address = configuration.baseURL
        key = ""
        message = "已保存"
      }
    } catch {
      message = error.localizedDescription
    }
  }
}


private struct RemoteAIDataConsentScreen: View {
  @State private var identity = ChatTopicStore.deviceIdentity
  @State private var permitted: Set<AIDataAuthorization.Source> = []
  @State private var sharesChatCity = false
  @State private var sharesChatEnvironment = false

  var body: some View {
    Form {
      Section {
        Text("开启后，相关记录会按需发送给你配置的 AI 服务商。关闭授权无法撤回已发送的数据。")
        ForEach(AIDataAuthorization.Source.allCases) { source in
          Toggle(source.title, isOn: Binding(
            get: { permitted.contains(source) },
            set: { enabled in
              if enabled { permitted.insert(source) } else { permitted.remove(source) }
              AIDataAuthorization.set(enabled, for: source, identity: identity)
            }))
        }
      }
      Section {
        Toggle("聊天中共享所在城市", isOn: Binding(
          get: { sharesChatCity },
          set: { enabled in
            sharesChatCity = enabled
            AIDataAuthorization.setChatCitySharing(enabled, identity: identity)
            if enabled { ChatCityLocation.shared.requestPermission() }
          }))
      } footer: {
        Text("开启后，聊天时会尝试获取近似位置，并向你配置的 AI 服务商提供城市及所在地区。可在 iOS 设置中管理定位权限。")
      }
      Section {
        Toggle("聊天与日报使用天气和空气质量", isOn: Binding(
          get: { sharesChatEnvironment },
          set: { enabled in
            sharesChatEnvironment = enabled
            AIDataAuthorization.setChatEnvironmentSharing(enabled, identity: identity)
            if enabled { ChatCityLocation.shared.requestPermission() }
            else { ChatEnvironment.shared.clear() }
          }))
      } footer: {
        Text("聊天按时段查询，日报生成时查询昨天的情况。Open-Meteo 接收近似坐标，查询结果提供给你配置的 AI 服务商。")
      }
    }
    .navigationTitle("AI 数据授权")
    .onAppear {
      identity = ChatTopicStore.identity()
      sharesChatCity = AIDataAuthorization.sharesChatCity(identity: identity)
      sharesChatEnvironment = AIDataAuthorization.sharesChatEnvironment(identity: identity)
      permitted = Set(AIDataAuthorization.Source.allCases.filter {
        AIDataAuthorization.allowed($0, identity: identity)
      })
    }
  }
}
