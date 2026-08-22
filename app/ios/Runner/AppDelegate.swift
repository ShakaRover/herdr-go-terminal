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
    EasyTierChannel.register(with: engineBridge.binaryMessenger)
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
          try Self.checkRc(easytier_ios_retain_instances(nil))
          result(nil)
        case "currentVirtualIp":
          // 原样返回 collectNetworkInfos 的 JSON，解析在 Dart 侧。
          result(Self.takeOwnedString(easytier_ios_collect_network_infos(10)))
        case "startForwarder":
          let instanceName = try Self.arg(call, "instanceName")
          let targetIp = try Self.arg(call, "targetIp")
          let targetPort = try Self.intArg(call, "targetPort")
          let port = easytier_ios_start_tcp_forwarder(
            instanceName, targetIp, UInt16(clamping: targetPort), 0)
          if port <= 0 { throw Self.lastError("startForwarder failed: \(port)") }
          result(Int(port))
        case "stopForwarder":
          let localPort = try Self.intArg(call, "localPort")
          // 与 Android 一致：stop 的返回码不当作错误（转发器可能已随实例消失）。
          _ = easytier_ios_stop_tcp_forwarder(Int32(clamping: localPort))
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

  private static func intArg(_ call: FlutterMethodCall, _ name: String) throws -> Int {
    guard let value = (call.arguments as? [String: Any])?[name] as? Int else {
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
