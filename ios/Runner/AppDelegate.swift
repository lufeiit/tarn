import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // CI 无人值守自测（2026-10-26）：只有 Beta 包（bundle id 以 .beta 结尾）保持屏幕常亮，
    // 好让 devicectl 的「启动 → 跑自测 → 抓容器日志 → 杀掉复验」这条链在没人碰手机时也能
    // 跑完；正式包不进这个分支，功耗与行为不变。
    if (Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true) {
      UIApplication.shared.isIdleTimerDisabled = true
    }
    #if targetEnvironment(simulator)
    // 模拟器没有 Network Extension：把内核链在 App 进程内，让订阅解析可用。
    SimKernel.shared.startIfNeeded()
    #endif
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    SubscriptionLinkBridge.shared.register(engineBridge.applicationRegistrar.messenger())
  }
}

final class SubscriptionLinkBridge {
  static let shared = SubscriptionLinkBridge()

  private var channel: FlutterMethodChannel?
  private var pending: [String] = []
  private var listening = false

  func register(_ messenger: FlutterBinaryMessenger) {
    listening = false
    let channel = FlutterMethodChannel(name: "com.tarn.app/link", binaryMessenger: messenger)
    self.channel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return result(FlutterMethodNotImplemented) }
      switch call.method {
      case "takeLinks":
        self.listening = true
        let links = self.pending
        self.pending.removeAll()
        result(links)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  func receive(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts {
      let url = context.url
      guard let scheme = url.scheme?.lowercased(),
            ["flowarc", "lfexp"].contains(scheme),
            url.host?.lowercased() == "install-config" else { continue }
      let link = url.absoluteString
      if listening, let channel = channel {
        channel.invokeMethod("link", arguments: link) { [weak self] response in
          if (response as AnyObject?) === FlutterMethodNotImplemented {
            self?.hold(link)
          }
        }
      } else {
        hold(link)
      }
    }
  }

  private func hold(_ link: String) {
    if pending.contains(link) { return }
    if pending.count == 16 { pending.removeFirst() }
    pending.append(link)
  }
}
