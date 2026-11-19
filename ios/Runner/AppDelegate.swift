import Flutter
import Security
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    SecureKeyBridge.register(messenger: messenger)
    FanqieLoginBridge.register(messenger: messenger)
    IosFilesBridge.register(messenger: messenger)
  }
}

/// 本机密钥库（iOS）：Keychain 通用密码项。
///
/// 取代 `flutter_secure_storage`（它在 Windows 端把 `win32` 钉在 5.x，挡住了
/// `wakelock_plus` / `package_info_plus` 的 Built-in Kotlin 版本，见 #205）。
///
/// - 每个条目 = 一个 account，service 固定为 `<bundle id>.secure_keys`；
/// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`：后台朗读/播放需要
///   设备首次解锁后即可读取，且绝不随备份恢复到另一台设备；
/// - 查询失败必须区分 `errSecItemNotFound`（真的没有）与其他错误：后者抛给
///   Dart，让 `SecureKeyProvider` 失败关闭，而不是当成“没有密钥”另建一把。
final class SecureKeyBridge {
  private static let service = "\(Bundle.main.bundleIdentifier ?? "fqapp").secure_keys"

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/secure_keys", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard let arguments = call.arguments as? [String: Any],
        let key = arguments["key"] as? String,
        !key.isEmpty
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 key", details: nil))
        return
      }
      do {
        switch call.method {
        case "read":
          result(try read(key))
        case "write":
          guard let value = arguments["value"] as? String else {
            result(FlutterError(code: "BAD_ARGUMENT", message: "缺少 value", details: nil))
            return
          }
          try write(key, value)
          result(nil)
        case "delete":
          try delete(key)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "KEYCHAIN", message: error.localizedDescription, details: nil))
      }
    }
  }

  private static func query(_ key: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
  }

  private static func read(_ key: String) throws -> String? {
    var lookup = query(key)
    lookup[kSecReturnData as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess else { throw KeychainError(status) }
    guard let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func write(_ key: String, _ value: String) throws {
    let data = Data(value.utf8)
    var update = query(key)
    update[kSecValueData as String] = data
    let updated = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
    if updated == errSecSuccess { return }
    if updated != errSecItemNotFound { throw KeychainError(updated) }
    var insert = query(key)
    insert[kSecValueData as String] = data
    insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(insert as CFDictionary, nil)
    guard added == errSecSuccess else { throw KeychainError(added) }
  }

  private static func delete(_ key: String) throws {
    let status = SecItemDelete(query(key) as CFDictionary)
    if status == errSecSuccess || status == errSecItemNotFound { return }
    throw KeychainError(status)
  }
}

struct KeychainError: LocalizedError {
  init(_ status: OSStatus) {
    self.status = status
  }

  let status: OSStatus

  var errorDescription: String? {
    SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 错误 \(status)"
  }
}

// MARK: - 番茄登录窗口（iOS）

/// 番茄书架采集的登录入口。
///
/// Android 有原生登录页，Windows/Linux 用 `webview_windows`；iOS 上两者都没有，
/// 这里用 `WKWebView` 打开官方登录页，用户完成登录后点「读取书架」，把
/// `fanqienovel.com` 的 cookie 交回 Dart（`FanqieLibraryCaptureService.collect`
/// 拿到 cookie 后由 Rust/Dart 侧直接请求采集接口）。
///
/// 与桌面版同一套约束：只允许官方域名（离开就拦下并提示），读取时要求存在
/// `sessionid` / `sessionid_ss` / `sid_tt` 之一且非空，整串不超过 12 KB。
final class FanqieLoginBridge: NSObject {
  private static let allowedHosts = [
    "fanqienovel.com", "snssdk.com", "bytedance.com", "zijieapi.com",
  ]
  private static let loginURL = URL(string: "https://fanqienovel.com/main/writer/login")!
  private static var active: FanqieLoginBridge?

  private let result: FlutterResult
  private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
  private let controller = UIViewController()
  private var finished = false

  private init(result: @escaping FlutterResult) {
    self.result = result
    super.init()
  }

  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/fanqie_account", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "login":
        let arguments = call.arguments as? [String: Any] ?? [:]
        let dark = arguments["dark"] as? Bool ?? false
        DispatchQueue.main.async {
          login(dark: dark, result: result)
        }
      case "cancelLogin":
        DispatchQueue.main.async {
          active?.finish(nil, result: nil)
          result(nil)
        }
      case "clearSession":
        DispatchQueue.main.async {
          clearSession(completion: { result(nil) })
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func login(dark: Bool, result: @escaping FlutterResult) {
    guard active == nil else {
      result(FlutterError(code: "BUSY", message: "登录窗口已打开", details: nil))
      return
    }
    guard let host = topViewController() else {
      result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
      return
    }
    let bridge = FanqieLoginBridge(result: result)
    active = bridge
    bridge.present(from: host, dark: dark)
  }

  private func present(from host: UIViewController, dark: Bool) {
    controller.view.backgroundColor = .systemBackground
    controller.title = "番茄登录"
    controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancelTapped))
    controller.navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "读取书架", style: .done, target: self, action: #selector(readTapped))

    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self
    webView.allowsBackForwardNavigationGestures = false
    controller.view.addSubview(webView)
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
      webView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
    ])
    if dark {
      controller.overrideUserInterfaceStyle = .dark
      webView.overrideUserInterfaceStyle = .dark
    }
    let navigation = UINavigationController(rootViewController: controller)
    navigation.modalPresentationStyle = .pageSheet
    host.present(navigation, animated: true)
    webView.load(URLRequest(url: Self.loginURL))
  }

  @objc private func cancelTapped() {
    finish(nil, result: result, dismissedByUser: true)
  }

  @objc private func readTapped() {
    webView.evaluateJavaScript("document.title") { [weak self] _, _ in
      self?.readCookies()
    }
  }

  private func readCookies() {
    WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self else { return }
      let scoped = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".")
          ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let names = ["sessionid", "sessionid_ss", "sid_tt"]
      let hasLogin = scoped.contains { cookie in
        names.contains(cookie.name) && !cookie.value.isEmpty
      }
      guard hasLogin else {
        DispatchQueue.main.async { self.alert("尚未取得登录态", "请先在官方页面完成登录与验证，再点「读取书架」。") }
        return
      }
      let value = scoped.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
      guard value.utf8.count <= 12 * 1024 else {
        DispatchQueue.main.async { self.alert("登录态过大", "读取失败，请重试。") }
        return
      }
      DispatchQueue.main.async { self.finish(value, result: self.result) }
    }
  }

  private func alert(_ title: String, _ message: String) {
    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "好", style: .default))
    controller.present(alert, animated: true)
  }

  /// 关闭窗口并把结果交回 Dart；`finished` 保证只回调一次。
  private func finish(_ value: String?, result: FlutterResult?, dismissedByUser: Bool = false) {
    guard !finished else { return }
    finished = true
    Self.active = nil
    let navigation = controller.navigationController
    let complete = {
      result?(value)
    }
    if dismissedByUser, let navigation {
      navigation.dismiss(animated: true) { complete() }
    } else {
      navigation?.dismiss(animated: true) { complete() }
    }
  }

  private static func clearSession(completion: @escaping () -> Void) {
    let store = WKWebsiteDataStore.default()
    store.httpCookieStore.getAllCookies { cookies in
      let targets = cookies.filter { cookie in
        let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return domain == "fanqienovel.com" || domain.hasSuffix(".fanqienovel.com")
      }
      let group = DispatchGroup()
      for cookie in targets {
        group.enter()
        store.httpCookieStore.delete(cookie) { group.leave() }
      }
      group.notify(queue: .main) { completion() }
    }
  }

  static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
      ?? scene?.windows.first?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}

extension FanqieLoginBridge: WKNavigationDelegate {
  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else {
      decisionHandler(.cancel)
      return
    }
    if url.scheme != "https" || url.user != nil || url.password != nil {
      decisionHandler(.cancel)
      return
    }
    let host = url.host ?? ""
    let allowed = FanqieLoginBridge.allowedHosts.contains { entry in
      host == entry || host.hasSuffix(".\(entry)")
    }
    if allowed {
      decisionHandler(.allow)
    } else {
      decisionHandler(.cancel)
      alert("已拦截跳转", "请留在番茄官方登录页面完成登录。")
    }
  }
}

// MARK: - 文件导出（iOS 分享面板）

/// `saveBackup` / `exportFanqieCapture` / `saveText` 在桌面上弹「另存为」，
/// iOS 没有等价的选择器，改为写临时文件再弹系统分享面板（存储到「文件」、
/// 发微信、AirDrop 都行）。Dart 侧拿到的是临时文件路径。
final class IosFilesBridge {
  static func register(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "fqapp/ios_files", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "saveFile" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let arguments = call.arguments as? [String: Any],
        let name = arguments["name"] as? String,
        let data = arguments["bytes"] as? FlutterStandardTypedData
      else {
        result(FlutterError(code: "BAD_ARGUMENT", message: "缺少文件内容", details: nil))
        return
      }
      presentShare(name: name, data: data.data, result: result)
    }
  }

  private static func presentShare(
    name: String, data: Data, result: @escaping FlutterResult
  ) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fqapp-share", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(sanitize(name))
    do {
      try data.write(to: url, options: .atomic)
    } catch {
      result(FlutterError(code: "WRITE", message: error.localizedDescription, details: nil))
      return
    }
    DispatchQueue.main.async {
      guard let host = FanqieLoginBridge.topViewController() else {
        result(FlutterError(code: "NO_WINDOW", message: "窗口尚未就绪", details: nil))
        return
      }
      let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
      if let popover = activity.popoverPresentationController,
        UIDevice.current.userInterfaceIdiom == .pad
      {
        popover.sourceView = host.view
        popover.sourceRect = CGRect(
          x: host.view.bounds.midX, y: host.view.bounds.midY, width: 0, height: 0)
        popover.permittedArrowDirections = []
      }
      var reported = false
      activity.completionWithItemsHandler = { _, _, _, _ in
        guard !reported else { return }
        reported = true
        result(url.path)
      }
      host.present(activity, animated: true)
    }
  }

  private static func sanitize(_ name: String) -> String {
    let cleaned = name.replacingOccurrences(
      of: "[\\\\/:*?\"<>|]", with: "_", options: .regularExpression)
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "fqapp-export" : trimmed
  }
}
