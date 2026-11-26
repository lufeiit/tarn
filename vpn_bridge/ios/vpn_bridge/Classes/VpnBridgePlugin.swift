import Flutter
import NetworkExtension
import UIKit
import Darwin
import WidgetKit

/// Tarn iOS VPN 桥插件：
/// - NETunnelProviderManager 控制 PacketTunnel 扩展（启动/停止/状态）
/// - App Group 消息队列（Message/Result JSON）用于 Dart ⇄ 扩展通信
public class VpnBridgePlugin: NSObject, FlutterPlugin {
    /// 签名相关标识全部来自宿主 Info.plist（由 xcconfig 注入），
    /// 换团队/换 Bundle ID 时只改 ios/Config/*.xcconfig，不动代码。
    public static let groupId = infoString(
        "TarnAppGroup", fallback: "group.com.tarn.app")
    public static let providerBundleId = infoString(
        "TarnProviderBundleId", fallback: "com.tarn.app.PacketTunnel")
    public static let notifyName = infoString(
        "TarnCoreNotify", fallback: "com.tarn.app.coreMsg")

    static func infoString(_ key: String, fallback: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? fallback
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.tarn.app/vpn_bridge",
            binaryMessenger: registrar.messenger())
        let instance = VpnBridgePlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    // MARK: - 方法分发

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "ensureConfigured":
            ensureConfigured(call, result: result)
        case "start":
            startVpn(result: result)
        case "stop":
            stopVpn(result: result)
        case "status":
            status(result: result)
        case "sendToExtension":
            sendToExtension(call, result: result)
        case "readResult":
            readResult(call, result: result)
        case "clearResult":
            clearResult(call, result: result)
        case "groupContainerPath":
            groupContainerPath(result: result)
        case "setCoreConfig":
            setCoreConfig(call, result: result)
        case "readExtLog":
            readExtLog(result: result)
        case "diagVersion":
            result("vpnbridge2")
        case "diagVpn":
            diagVpn(result: result)
        case "appPhysFootprint":
            appPhysFootprint(result: result)
        case "setMinMode":
            setMinMode(call, result: result)
        case "setFdBridge":
            setFdBridge(call, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func groupContainerPath(result: @escaping FlutterResult) {
        if let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupId) {
            result(url.path)
        } else {
            result(FlutterError(code: "no-group",
                                message: "App Group 不可用，请检查 entitlements",
                                details: nil))
        }
    }

    private func setCoreConfig(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let ud = groupUserDefaults
        let args = call.arguments as? [String: Any]
        if let initParams = args?["initParams"] as? String {
            ud?.set(initParams, forKey: "initParams")
            writeGroupFile("initParams.json", initParams)
        }
        if let setupParams = args?["setupParams"] as? String {
            ud?.set(setupParams, forKey: "setupParams")
            writeGroupFile("setupParams.json", setupParams)
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(Self.notifyName as CFString),
            nil, nil, true)
        result(true)
    }

    /// 将核心配置原子写入 App Group 容器文件（扩展进程读文件；
    /// 该设备上跨进程 UserDefaults 同步不可靠，文件通道已验证可用）
    private func writeGroupFile(_ name: String, _ value: String) {
        guard let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupId) else {
            return
        }
        let url = container.appendingPathComponent(name)
        try? (value + "\n").data(using: .utf8)?.write(to: url, options: .atomic)
    }

    // MARK: - 扩展诊断日志

    private func setMinMode(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        groupUserDefaults?.set(enabled, forKey: "extMinMode")
        result(true)
    }

    /// fd 桥实验开关（App Group UserDefaults，扩展启动时读取）
    private func setFdBridge(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let enabled = (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        groupUserDefaults?.set(enabled, forKey: "extFdBridge")
        result(true)
    }

    private func readExtLog(result: @escaping FlutterResult) {
        // 诊断文件位置：2026-09-11 起写 App Group 的 Library/ 下
        // （devicectl 对 App Group 域不列/不拷根级文件，落 Library/ 才能直接拉起）；
        // 根级 `extDiag.txt` 作为旧版本兼容保留，UserDefaults 最后兜底。
        var out = ""
        if let container = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupId) {
            for rel in ["Library/extDiag.txt", "extDiag.txt"] {
                if let data = try? Data(contentsOf: container.appendingPathComponent(rel)),
                   let s = String(data: data, encoding: .utf8),
                   !s.isEmpty {
                    out = s
                    break
                }
            }
        }
        if out.isEmpty {
            out = groupUserDefaults?.string(forKey: "extLog") ?? ""
        }
        // 一并带出扩展侧的写失败/探针上报（UD 通道 —— extDiag.txt 写不出来时唯一线索）
        if let err = groupUserDefaults?.string(forKey: "diagError"), !err.isEmpty {
            out += (out.isEmpty ? "" : "\n") + "===== [UD] diagError =====\n" + err
        }
        result(out)
    }

    // MARK: - VPN 配置与控制

    private func ensureConfigured(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let requestedBundleId = (call.arguments as? [String: Any])?["providerBundleId"] as? String
        let targetBundleId = requestedBundleId?.isEmpty == false
            ? requestedBundleId!
            : Self.providerBundleId
        // 已存在本应用配置则不重建：避免每次测速都删除重建导致系统重复授权/弹窗。
        // 早期版本每次 rebuild 是因为 App 更新后 nehelper 会 invalidate 旧配置的插件绑定
        // （"Plugin is not installed"）；如遇到该问题可手动删除系统 VPN 配置后重试，
        // 或临时恢复删除重建逻辑。
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                result(FlutterError(code: "load", message: error.localizedDescription, details: nil))
                return
            }
            if (managers ?? []).contains(where: { self.isOwnedManager($0, targetBundleId: targetBundleId) }) {
                // 2026-10-07：多品牌共存时 iOS 会把“非当前”配置置为 disabled，
                // 下次本 App 启动 VPN 会被拒（NEVPNErrorConfigurationDisabled）。
                // 发现即修：置回 enabled 保存。
                self.ensureEnabled(targetBundleId: targetBundleId) { _ in result(true) }
                return
            }
            // 早期版本保存过 providerBundleIdentifier 为空的配置，名字还是旧品牌。
            // 这类配置启动时找不到扩展（VPN 列表里显示旧名、隧道起不来），删除后重建。
            let stale = (managers ?? []).filter { self.providerId(of: $0).isEmpty }
            self.removeManagers(stale) {
                self.saveConfig(targetBundleId, result: result)
            }
        }
    }

    /// 确保目标配置处于 enabled（多品牌共存时 iOS 会把“非当前”配置置为 disabled，
    /// 此时 startVPNTunnel 报 NEVPNErrorDomain error 2 ⇔ ConfigurationDisabled，
    /// 表现为「打开开关后自己回退、系统 VPN 不切换到自己配置」——2026-10-07 实机修复）。
    /// App 对自己创建的配置有修改权；无配置或已 enabled 时直接回 nil。
    private func ensureEnabled(targetBundleId: String, completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(error)
                return
            }
            guard let manager = (managers ?? []).first(where: {
                self.isOwnedManager($0, targetBundleId: targetBundleId)
            }) else {
                completion(nil)
                return
            }
            if manager.isEnabled {
                completion(nil)
                return
            }
            manager.isEnabled = true
            manager.saveToPreferences { err in completion(err) }
        }
    }

    private func providerId(of manager: NETunnelProviderManager) -> String {
        (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? ""
    }

    private func isOwnedManager(_ manager: NETunnelProviderManager,
                                targetBundleId: String) -> Bool {
        providerId(of: manager) == targetBundleId
    }

    /// 逐个删除配置后再回调：删除必须在保存新配置之前完成。
    private func removeManagers(_ managers: [NETunnelProviderManager],
                                completion: @escaping () -> Void) {
        guard let manager = managers.first else {
            completion()
            return
        }
        manager.removeFromPreferences { _ in
            self.removeManagers(Array(managers.dropFirst()), completion: completion)
        }
    }

    private func ownedManager(from managers: [NETunnelProviderManager]?) -> NETunnelProviderManager? {
        managers?.first {
            isOwnedManager($0, targetBundleId: Self.providerBundleId)
        }
    }

    private func saveConfig(_ targetBundleId: String,
                            result: @escaping FlutterResult) {
        let manager = NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = targetBundleId
        proto.serverAddress = "198.18.0.1"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        // 显示名跟当前包走（本地包与 TF 包名字不同），不再写死旧品牌。
        manager.localizedDescription =
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? "Tarn"
        manager.isEnabled = true
        manager.saveToPreferences { error in
            if let error = error {
                result(FlutterError(code: "save", message: error.localizedDescription, details: nil))
                return
            }
            NETunnelProviderManager.loadAllFromPreferences { _, _ in
                result(true)
            }
        }
    }

    /// 桌面小组件状态刷新：App 侧任何 VPN 状态变化都触发 timeline 重载
    private func reloadVpnWidget() {
        if #available(iOS 14.0, *) {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func startVpn(result: @escaping FlutterResult) {
        // 2026-10-07：启动前先确保本配置 enabled（多品牌共存时 iOS 会把“非当前”
        // 配置置为 disabled ⇒ startVPNTunnel 报 error 2，开关回退）。
        ensureEnabled(targetBundleId: Self.providerBundleId) { enableErr in
            // on-demand 保持关闭：本产品的扩展是**按需拉起**（点测速 / 用户按开关），
            // 不允许系统在 App 未请求时自己把隧道拉起来（旧版残留会形成
            // 「起来 → quickSetup 失败 → 系统再拉起」的重启风暴）。
            self.setOnDemand(false) { odErr in
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    guard error == nil,
                          let manager = self.ownedManager(from: managers) else {
                        result(FlutterError(code: "no-config", message: "VPN 配置不存在，请先 ensureConfigured", details: nil))
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                        self.reloadVpnWidget()
                        result(true)
                    } catch {
                        result(FlutterError(code: "start",
                                            message: error.localizedDescription,
                                            details: odErr?.localizedDescription ?? enableErr?.localizedDescription))
                    }
                }
            }
        }
    }

    private func stopVpn(result: @escaping FlutterResult) {
        // 必须先关 on-demand：否则 terminate 之后系统会立刻按规则把隧道拉回来
        // （用户按“断开”却看到 VPN 自己又连上，就是这个原因）。
        setOnDemand(false) { _ in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if error == nil {
                    self.ownedManager(from: managers)?.connection.stopVPNTunnel()
                    self.reloadVpnWidget()
                }
                result(true)
            }
        }
    }

    // MARK: - On-Demand（系统级自动拉起）
    //
    // “VPN 被系统杀掉后不会自己回来”的根因：Flutter 侧的看门狗跑在**主 App 进程**，
    // 而 iOS 会把后台 App 挂起/回收 —— 扩展被 jetsam 杀掉时看门狗根本不在跑
    //（真机实测：被杀后一直没有重复拉起）。唯一可靠的机制是系统级 on-demand：
    // `isOnDemandEnabled = true` 时 iOS 会在隧道因崩溃/内存超限而断开后自行重启
    // 扩展。语义设计：
    //   start → 打开 on-demand（之后被杀自动回来，不依赖 App 存活）
    //   stop  → 关闭 on-demand（用户主动断开就是断开，不自动拉起）
    private func setOnDemand(_ enabled: Bool, completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error = error {
                completion(error)
                return
            }
            guard let manager = self.ownedManager(from: managers) else {
                completion(nil)
                return
            }
            if manager.isOnDemandEnabled == enabled {
                completion(nil)
                return
            }
            manager.isOnDemandEnabled = enabled
            if enabled {
                let rule = NEOnDemandRuleConnect()
                rule.interfaceTypeMatch = .any
                manager.onDemandRules = [rule]
            } else {
                manager.onDemandRules = nil
            }
            manager.saveToPreferences { err in completion(err) }
        }
    }

    private func status(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            let status = error == nil
                ? self.ownedManager(from: managers)?.connection.status ?? .invalid
                : .invalid
            switch status {
            case .connected: result("connected")
            case .connecting: result("connecting")
            case .disconnected: result("disconnected")
            case .disconnecting: result("disconnecting")
            default: result("invalid")
            }
            self.reloadVpnWidget()
        }
    }

    /// 系统里 VPN 配置的现场快照（2026-10-27，真机 CI 用）。
    /// `status` 只有五个值，把三种完全不同的故障念成同一句 `invalid`：
    ///   ① 这个 App 在系统里**没有**自己的 VPN 配置 —— 得先建，而 `saveToPreferences`
    ///      会弹系统授权框；无人值守没人点，15s 超时后 ensureKernel 直接 false。
    ///   ② 配置在，但多品牌共存时被 iOS 置成 **disabled**（39a34344 修的就是这个），
    ///      重新启用同样要走 `saveToPreferences`，一样会卡在弹窗。
    ///   ③ 配置在、也启用，只是隧道自己处于 invalid（系统没把这条配置加载成可用连接）。
    /// 三种修法各不相同，却长得一模一样 —— 所以报告必须自己讲清是哪一种。
    private func diagVpn(result: @escaping FlutterResult) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            var parts: [String] = []
            var matched = false
            for manager in (managers ?? []) {
                let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
                let provider = proto?.providerBundleIdentifier ?? ""
                let mine = provider == Self.providerBundleId
                if mine { matched = true }
                parts.append([
                    manager.localizedDescription ?? "?",
                    "provider=\(provider.isEmpty ? "-" : provider)",
                    "enabled=\(manager.isEnabled)",
                    "onDemand=\(manager.isOnDemandEnabled)",
                    "status=\(Self.vpnStatusName(manager.connection.status))",
                    mine ? "<== 本 App" : "",
                ].filter { !$0.isEmpty }.joined(separator: " "))
            }
            var line = "target=\(Self.providerBundleId) 条数=\(parts.count) "
                + "本App配置=\(matched ? "有" : "无")"
            if let error = error {
                line += " loadError=\(error.localizedDescription)"
            }
            if !parts.isEmpty {
                line += " || " + parts.joined(separator: " || ")
            }
            result(line)
        }
    }

    /// NEVPNStatus 只有 invalid/disconnected/connecting/connected/disconnecting 五个具名分支
    /// （`reconnecting` / `notLoaded` 是别的枚举，写进去直接编译不过——run 763 就是这么红的），
    /// 剩下的一律念 unknown，别为了凑名字骗过判定器。
    private static func vpnStatusName(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .invalid: return "invalid"
        @unknown default: return "unknown"
        }
    }

    // MARK: - App Group 消息队列（Dart ⇄ 扩展）

    private var groupUserDefaults: UserDefaults? {
        UserDefaults(suiteName: Self.groupId)
    }

    /// App Group 容器下子目录（不存在则建）。
    /// 文件通道用途：每条消息/结果一个文件 ⇒ **并发安全**。
    /// UserDefaults 的数组/字典是「读-改-写」，并发发送会互相覆盖丢消息，
    /// 这正是 iOS 侧测速被迫串行（`_delayTail`）的根源。
    private func groupSubdir(_ name: String) -> URL? {
        guard let base = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.groupId) else {
            return nil
        }
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sendToExtension(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let json = (call.arguments as? [String: Any])?["json"] as? String else {
            result(false)
            return
        }
        let notify = {
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(Self.notifyName as CFString),
                nil, nil, true)
        }
        // 文件队列优先（并发安全）：每条消息一个独立文件，读完即删
        if let dir = groupSubdir("msgqueue") {
            let name = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
            let url = dir.appendingPathComponent(name)
            if (try? Data(json.utf8).write(to: url, options: .atomic)) != nil {
                notify()
                result(true)
                return
            }
        }
        // 兜底：UserDefaults 数组（旧通道，串行时才安全）
        let ud = groupUserDefaults
        var queue = ud?.array(forKey: "msgQueue") as? [String] ?? []
        queue.append(json)
        ud?.set(queue, forKey: "msgQueue")
        notify()
        result(true)
    }

    private func readResult(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let id = (call.arguments as? [String: Any])?["id"] as? String else {
            result(nil)
            return
        }
        // 文件优先（扩展写 results/<id>.json，原子写 + 实时可见）。
        // 2026-10-07：不再回退读 UD `results` 字典 —— 该字典 8000+ 条 / 7.7MB，
        // 每次「未命中」都会把全量物化进 Foundation，造成 ~10-20MB 级瞬时分配。
        if let url = groupSubdir("results")?.appendingPathComponent("\(id).json"),
           let data = try? Data(contentsOf: url),
           let s = String(data: data, encoding: .utf8), !s.isEmpty {
            result(s)
            return
        }
        result(nil)
    }

    /// App 进程的 phys_footprint（字节）：iOS 的「内存」判定口径，
    /// 比 ProcessInfo.currentRss 更接近系统设置里显示的占用。
    private func appPhysFootprint(result: @escaping FlutterResult) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            result(Int(info.phys_footprint))
        } else {
            result(nil)
        }
    }

    private func clearResult(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let id = (call.arguments as? [String: Any])?["id"] as? String else {
            result(nil)
            return
        }
        // 删文件（并发安全：只影响自己这个 id）。
        // 2026-10-07：不再同步写 UD `results` 字典（同 readResult 注释，避免全量物化/回写）。
        if let url = groupSubdir("results")?.appendingPathComponent("\(id).json") {
            try? FileManager.default.removeItem(at: url)
        }
        result(nil)
    }
}
