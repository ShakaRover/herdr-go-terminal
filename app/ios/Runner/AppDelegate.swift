import Flutter
import Network
import UIKit

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
    EasyTierChannel.register(with: engineBridge.applicationRegistrar.messenger())
  }
}

/// `dev.herdr/easytier` MethodChannel，与 Android 侧 MainActivity 的契约一致，
/// 背后调 easytier-ios 的 C ABI（见 easytier-ios.h）。
final class EasyTierChannel {
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "dev.herdr/easytier", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      do {
        switch call.method {
        case "startInstance":
          let config = try Self.arg(call, "config")
          try Self.checkRc(easytier_ios_run_instance(config))
          result(nil)
        case "stopInstance":
          let instanceName = try Self.arg(call, "instanceName")
          // 原生 exact-delete 不依赖有上限的实例枚举；否则
          // >10 实例时用 retain 模拟删除会误停未枚举到的实例。
          try Self.checkRc(easytier_ios_delete_instance(instanceName))
          result(nil)
        case "currentVirtualIp":
          let instanceName = try Self.arg(call, "instanceName")
          // 过滤 collectNetworkInfos 结果，只回传目标实例。
          // iOS C ABI 返回平铺 {"<name>": <info>}（无 map 包装层），
          // 过滤后包装成 Dart 侧期望的 {"map": {"<name>": <info>}}。
          guard let json = Self.takeOwnedString(easytier_ios_collect_network_infos(10)),
                let data = json.data(using: .utf8),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let info = obj[instanceName] else {
            result(nil)
            return
          }
          let filtered = try JSONSerialization.data(
            withJSONObject: ["map": [instanceName: info]])
          result(String(data: filtered, encoding: .utf8))
        case "callJsonRpc":
          let service = try Self.arg(call, "service")
          let method = try Self.arg(call, "method")
          let payload = try Self.arg(call, "payload")
          // 失败时 C ABI 返回 NULL，转成 FlutterError；响应原样回传给 Dart 解析。
          guard let response = Self.takeOwnedString(
            easytier_ios_call_json_rpc(service, method, payload)) else {
            throw Self.lastError("callJsonRpc failed")
          }
          result(response)
        case "configureDiagnosticLogging":
          let enabled = try Self.boolArg(call, "enabled")
          try DiagnosticLogController.shared.configure(enabled: enabled)
          result(nil)
        case "appendDiagnosticEvent":
          let message = try Self.arg(call, "message")
          try DiagnosticLogController.shared.append(message)
          result(nil)
        case "shareDiagnosticLogs":
          try DiagnosticLogController.shared.share { error in
            if let error {
              result(FlutterError(code: "diagnostic_logs", message: "\(error)", details: nil))
            } else {
              result(nil)
            }
          }
          return
        case "clearDiagnosticLogs":
          try DiagnosticLogController.shared.clear()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "easytier", message: "\(error)", details: nil))
      }
    }
  }

  private static func arg(_ call: FlutterMethodCall, _ name: String) throws -> String {
    guard let value = (call.arguments as? [String: Any])?[name] as? String, !value.isEmpty else {
      throw NSError(domain: "easytier", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "missing \(name)"
      ])
    }
    return value
  }

  private static func boolArg(_ call: FlutterMethodCall, _ name: String) throws -> Bool {
    guard let value = (call.arguments as? [String: Any])?[name] as? Bool else {
      throw NSError(domain: "easytier", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "missing \(name)"
      ])
    }
    return value
  }

  /// 取走 C ABI 返回的 owned 字符串并释放；NULL → nil。
  fileprivate static func takeOwnedString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { easytier_ios_free_string(ptr) }
    return String(cString: ptr)
  }

  fileprivate static func checkRc(_ rc: Int32) throws {
    if rc != 0 { throw lastError("easytier call failed: \(rc)") }
  }

  fileprivate static func lastError(_ fallback: String) -> NSError {
    let message = takeOwnedString(easytier_ios_last_error()) ?? fallback
    return NSError(domain: "easytier", code: 2, userInfo: [
      NSLocalizedDescriptionKey: message
    ])
  }
}

/// Owns persistent EasyTier diagnostics for the iOS host. EasyTier formats and
/// rotates its own trace events; this controller contributes app/network
/// markers and handles iOS storage and sharing.
final class DiagnosticLogController {
  static let shared = DiagnosticLogController()

  private let fileManager = FileManager.default
  private let pathQueue = DispatchQueue(label: "dev.herdr.diagnostic-network-path")
  private var pathMonitor: NWPathMonitor?
  private var notificationObservers: [NSObjectProtocol] = []
  private var enabled = false
  private var loggerInitialized = false

  private let knownLogNames = Set([
    "easytier.log", "easytier.1.log", "easytier.2.log", "easytier.3.log",
  ])

  private init() {}

  private var directory: URL {
    fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Diagnostics", isDirectory: true)
  }

  func configure(enabled newValue: Bool) throws {
    if newValue {
      try prepareDirectory()
      let rc = directory.path.withCString {
        easytier_ios_configure_diagnostic_logging($0, 1)
      }
      try EasyTierChannel.checkRc(rc)
      loggerInitialized = true
      if !enabled {
        enabled = true
        startObservers()
      }
      try append("diagnostic logging enabled; app=\(appVersion)")
      return
    }

    if enabled {
      try append("diagnostic logging disabled")
      stopObservers()
      enabled = false
    }
    try EasyTierChannel.checkRc(easytier_ios_configure_diagnostic_logging(nil, 0))
  }

  func append(_ message: String) throws {
    let rc = message.withCString { easytier_ios_append_diagnostic_event($0) }
    try EasyTierChannel.checkRc(rc)
  }

  func clear() throws {
    if loggerInitialized {
      try EasyTierChannel.checkRc(easytier_ios_clear_diagnostic_logs())
    } else if fileManager.fileExists(atPath: directory.path) {
      for name in knownLogNames {
        let file = directory.appendingPathComponent(name)
        if fileManager.fileExists(atPath: file.path) {
          try fileManager.removeItem(at: file)
        }
      }
    }
    if enabled {
      try append("diagnostic logs cleared")
    }
  }

  func share(completion: @escaping (Error?) -> Void) throws {
    try EasyTierChannel.checkRc(easytier_ios_flush_diagnostic_logging())
    let files = try logFiles()
    guard !files.isEmpty else {
      throw NSError(domain: "diagnostic_logs", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "No diagnostic logs are available"
      ])
    }

    let snapshot = fileManager.temporaryDirectory
      .appendingPathComponent("HerdrGoT-Diagnostics-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: snapshot, withIntermediateDirectories: true)
    do {
      for file in files {
        try fileManager.copyItem(at: file, to: snapshot.appendingPathComponent(file.lastPathComponent))
      }
    } catch {
      try? fileManager.removeItem(at: snapshot)
      throw error
    }

    DispatchQueue.main.async {
      guard let presenter = Self.presentationViewController() else {
        try? self.fileManager.removeItem(at: snapshot)
        completion(NSError(domain: "diagnostic_logs", code: 2, userInfo: [
          NSLocalizedDescriptionKey: "No active window is available for sharing"
        ]))
        return
      }
      let snapshots = files.map { snapshot.appendingPathComponent($0.lastPathComponent) }
      let activity = UIActivityViewController(activityItems: snapshots, applicationActivities: nil)
      if let popover = activity.popoverPresentationController {
        popover.sourceView = presenter.view
        popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                    y: presenter.view.bounds.midY,
                                    width: 1, height: 1)
        popover.permittedArrowDirections = []
      }
      activity.completionWithItemsHandler = { _, _, _, error in
        try? self.fileManager.removeItem(at: snapshot)
        completion(error)
      }
      presenter.present(activity, animated: true)
    }
  }

  private var appVersion: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
    let build = info?["CFBundleVersion"] as? String ?? "unknown"
    return "\(version)(\(build))"
  }

  private func prepareDirectory() throws {
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(values)
    try fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: directory.path)
  }

  private func logFiles() throws -> [URL] {
    guard fileManager.fileExists(atPath: directory.path) else { return [] }
    return try fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey],
      options: [.skipsHiddenFiles])
      .filter { knownLogNames.contains($0.lastPathComponent) }
      .filter {
        (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { $0 > 0 } ?? false
      }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  private func startObservers() {
    guard notificationObservers.isEmpty else { return }
    let center = NotificationCenter.default
    notificationObservers = [
      center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                         object: nil, queue: nil) { [weak self] _ in
        self?.appendWithoutThrowing("application did become active")
      },
      center.addObserver(forName: UIApplication.willResignActiveNotification,
                         object: nil, queue: nil) { [weak self] _ in
        self?.appendWithoutThrowing("application will resign active")
      },
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                         object: nil, queue: nil) { [weak self] _ in
        self?.appendWithoutThrowing("application did enter background")
        _ = easytier_ios_flush_diagnostic_logging()
      },
      center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                         object: nil, queue: nil) { [weak self] _ in
        self?.appendWithoutThrowing("application will enter foreground")
      },
    ]

    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      self?.appendWithoutThrowing(Self.describe(path))
    }
    pathMonitor = monitor
    monitor.start(queue: pathQueue)
  }

  private func stopObservers() {
    let center = NotificationCenter.default
    for observer in notificationObservers {
      center.removeObserver(observer)
    }
    notificationObservers.removeAll()
    pathMonitor?.cancel()
    pathMonitor = nil
  }

  private func appendWithoutThrowing(_ message: String) {
    do {
      try append(message)
    } catch {
      NSLog("[easytier-ios] failed to append diagnostic event: %@", "\(error)")
    }
  }

  private static func describe(_ path: NWPath) -> String {
    let status: String
    switch path.status {
    case .satisfied: status = "satisfied"
    case .unsatisfied: status = "unsatisfied"
    case .requiresConnection: status = "requires-connection"
    @unknown default: status = "unknown"
    }
    let interfaces: [(NWInterface.InterfaceType, String)] = [
      (.wifi, "wifi"), (.cellular, "cellular"), (.wiredEthernet, "ethernet"),
      (.loopback, "loopback"), (.other, "other"),
    ]
    let activeInterfaces = interfaces
      .filter { path.usesInterfaceType($0.0) }
      .map(\.1)
      .joined(separator: ",")
    return "network path status=\(status) interfaces=\(activeInterfaces.isEmpty ? "none" : activeInterfaces) "
      + "expensive=\(path.isExpensive) constrained=\(path.isConstrained)"
  }

  private static func presentationViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive }
      ?? scenes.first { $0.activationState == .foregroundInactive }
    guard var controller = scene?.windows.first(where: \.isKeyWindow)?.rootViewController else {
      return nil
    }
    while let presented = controller.presentedViewController {
      controller = presented
    }
    return controller
  }
}
