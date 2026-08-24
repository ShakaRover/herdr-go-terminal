import Flutter
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
    let loggingRc = easytier_ios_enable_diagnostic_logging()
    if loggingRc != 0 {
      let message = takeOwnedString(easytier_ios_last_error()) ?? "unknown error"
      NSLog("[easytier-ios] diagnostic logging unavailable: %@", message)
    }
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

  /// 取走 C ABI 返回的 owned 字符串并释放；NULL → nil。
  private static func takeOwnedString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    defer { easytier_ios_free_string(ptr) }
    return String(cString: ptr)
  }

  private static func checkRc(_ rc: Int32) throws {
    if rc != 0 { throw lastError("easytier call failed: \(rc)") }
  }

  private static func lastError(_ fallback: String) -> NSError {
    let message = takeOwnedString(easytier_ios_last_error()) ?? fallback
    return NSError(domain: "easytier", code: 2, userInfo: [
      NSLocalizedDescriptionKey: message
    ])
  }
}
