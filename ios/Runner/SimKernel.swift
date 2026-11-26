#if targetEnvironment(simulator)
import Foundation

// MARK: - 模拟器专用内核桥
//
// iOS 模拟器不支持 Network Extension，而 FlClash 的订阅解析、节点列表、
// 测速全部在 PacketTunnel 扩展里的 Go 内核执行。没有扩展，App 侧发到
// App Group 的消息永远没人处理，`config.validate` / `profile.base` 只能超时。
//
// 这里把同一份 libclash（模拟器切片）链进 Runner target，在 App 进程内
// 复刻扩展的最小职责：
//   1. quickSetup(initParams, "{}") 把内核拉起来（只做解析，不起 TUN）；
//   2. 监听与扩展相同的 Darwin 通知，消费 App Group `msgqueue/`；
//   3. 用与扩展相同的 `results/<id>.json` 约定回写结果。
//
// 真机包不会编译这个文件（#if targetEnvironment(simulator)）。
@_silgen_name("quickSetup")
private func simCoreQuickSetup(
    _ callback: UnsafeMutableRawPointer?,
    _ initParams: UnsafeMutablePointer<CChar>?,
    _ setupParams: UnsafeMutablePointer<CChar>?
)

@_silgen_name("invokeAction")
private func simCoreInvokeAction(
    _ callback: UnsafeMutableRawPointer?,
    _ params: UnsafeMutablePointer<CChar>?
)

@_silgen_name("setIOSResultHandler")
private func simCoreSetResultHandler(
    _ fn: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>?) -> Void,
    _ ctx: UnsafeMutableRawPointer?,
    _ releaseFn: @convention(c) (UnsafeMutableRawPointer?) -> Void
)

final class SimKernel {
    static let shared = SimKernel()

    private static let groupId = infoString(
        "LFExpAppGroup", fallback: "group.com.tarn.app")
    private static let notifyName = infoString(
        "LFExpCoreNotify", fallback: "com.tarn.app.coreMsg")

    private static func infoString(_ key: String, fallback: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
    }

    private let queue = DispatchQueue(label: "com.tarn.app.simkernel")
    private let container: URL?
    private let resultsDir: URL?
    private let msgQueueDir: URL?
    private var started = false
    private var observerInstalled = false

    private init() {
        container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupId)
        resultsDir = container?.appendingPathComponent("results", isDirectory: true)
        msgQueueDir = container?.appendingPathComponent("msgqueue", isDirectory: true)

        for dir in [resultsDir, msgQueueDir] {
            if let dir {
                try? FileManager.default.createDirectory(
                    at: dir, withIntermediateDirectories: true)
            }
        }
    }

    /// App 启动最早时机调用：Dart 侧发来的消息可能已经排在队列里。
    func startIfNeeded() {
        guard !started, let container else {
            NSLog("[simkernel] start skipped (started=\(started), container=\(self.container != nil))")
            return
        }
        started = true

        // home 必须落在 App 自己的沙盒里：FlClash 的 profiles/ 在
        // Application Support 下，内核只放行 home 子树内的路径
        // （否则报 “path is not subpath of home directory”）。
        let home = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        installResultHandler()
        installObserver()

        let initParams = #"{"home-dir":"\#(home.path)","version":1}"#
        NSLog("[simkernel] quickSetup home=\(home.path)")
        simCoreQuickSetup(nil, strdup(initParams), strdup("{}"))

        // quickSetup 是异步的；内核初始化完成前后都扫一遍队列（重复的请求
        // 在初始化前会失败并被 App 重试，这里保守地稍后再扫一次）。
        scheduleProcess()
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.processPending()
        }
    }

    // MARK: - 结果回写（与扩展同一约定）

    private func installResultHandler() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        simCoreSetResultHandler({ ctx, data in
            guard ctx != nil, let data else { return }
            autoreleasepool {
                SimKernel.shared.writeResult(String(cString: data))
            }
        }, ctx) { _ in }
    }

    fileprivate func writeResult(_ message: String) {
        guard let resultsDir,
              let data = message.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else {
            return
        }
        let url = resultsDir.appendingPathComponent("\(id).json")
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - 请求消费

    private func installObserver() {
        guard !observerInstalled else { return }
        observerInstalled = true
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let kernel = Unmanaged<SimKernel>.fromOpaque(observer).takeUnretainedValue()
                kernel.scheduleProcess()
            },
            Self.notifyName as CFString,
            nil,
            .deliverImmediately)
    }

    private func scheduleProcess() {
        queue.async { [weak self] in
            self?.processPending()
        }
    }

    private func processPending() {
        guard let msgQueueDir else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: msgQueueDir, includingPropertiesForKeys: nil)) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            // 先删再投递：Go 侧已把内容读进内存，重放同一个请求只会重复执行。
            try? FileManager.default.removeItem(at: url)
            guard let params = strdup(text) else { continue }
            simCoreInvokeAction(nil, params)
        }
    }
}
#endif
