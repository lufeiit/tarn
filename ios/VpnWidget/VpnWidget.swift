import AppIntents
import NetworkExtension
import UIKit
import WidgetKit
import SwiftUI

/// 控制中心 VPN 快捷开关（2026-10-24 终局方向：用户决定不做桌面小组件，
/// 专攻控制中心）。
///
/// 渲染约束（真机多轮实证，勿回退）：
///   1. 控制模板只吃**静态声明**：运行时文件读取/UIImage 加载会让整个标签
///      渲染失败（全 ?）——只允许静态 Label/Text/Image。
///   2. 本扩展编译出的 Asset Catalog（car）此前在渲染进程解析失败——本轮
///      实验以 ASSETCATALOG_COMPILER_OPTIMIZATION=speed（不压缩 car）+
///      单尺度 imageset 重试静态 Label(image:)；若再失败，定格 SF Symbol。
///   3. 自定义 SF Symbol 需苹果图形工具导出档案，不可脚本化。

@main
struct VpnWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 18.0, *) {
            VpnControl()
        }
    }
}

/// 控制中心按钮上的品牌名。
let vpnBrandDisplayName = "Tarn"

/// 控制中心图标：自定义符号需 Apple 图形工具导出，首版用系统盾牌。
let vpnSiteMarkSystemSymbol = "shield.lefthalf.filled"

// MARK: - 开关意图

@available(iOS 17.0, *)
struct ToggleVpnIntent: ControlConfigurationIntent {
    static let title: LocalizedStringResource = LocalizedStringResource("vpn.widget.toggle.title")
    static let description = IntentDescription(LocalizedStringResource("vpn.widget.toggle.description"))

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 从扩展自身 bundle id 派生隧道扩展 id（<base>.VpnWidget → <base>.PacketTunnel）
        let bid = Bundle.main.bundleIdentifier ?? ""
        let base = bid.hasSuffix(".VpnWidget") ? String(bid.dropLast(".VpnWidget".count)) : bid
        let providerId = base + ".PacketTunnel"
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        guard let manager = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerId
        }) else {
            return .result(dialog: IntentDialog(LocalizedStringResource("vpn.widget.dialog.noConfig")))
        }
        // 多品牌共存时 iOS 会把非当前配置置为 disabled（NEVPNErrorConfigurationDisabled），
        // 与主 App 的 ensureEnabled 同一处理：发现即修。
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await NETunnelProviderManager.loadAllFromPreferences()
        }
        let connected = manager.connection.status == .connected
            || manager.connection.status == .connecting
        if connected {
            try manager.connection.stopVPNTunnel()
        } else {
            try manager.connection.startVPNTunnel()
        }
        return .result(dialog: connected
            ? IntentDialog(LocalizedStringResource("vpn.widget.dialog.disconnected"))
            : IntentDialog(LocalizedStringResource("vpn.widget.dialog.connecting")))
    }
}

// MARK: - 控制中心（iOS 18+）

@available(iOS 18.0, *)
struct VpnControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        // 站点标志自定义 SF Symbol（2026-10-24，参照 Crunchy Bagel 配方）：
        // 控制模板只支持 SF Symbol（系统或自定义），普通图片资产/运行时图片
        // 一律 ?（Apple 限制，与签名无关）。站点 site.png 剪影 → potrace →
        // SwiftDraw --format sfsymbol → SiteMark.symbolset（template 渲染=无色）。
        // 引用：Image/Label(image:) 按名解析，名字指向 symbolset 时即为符号
        // （SwiftUI 无独立 Label(symbol:) 初始化器，文章口径与 SDK 有出入）。
        // 符号源文件按站点入库（assets/sites/<id>/symbol/），brand.py 复制。
        // 2026-10-24 定稿：lufei=海贼旗原始线稿（自定义符号）；标志天生彩色的
        // 站点（迷途：蓝渐变球+白月牙，剪影失真）改用系统符号，brand.py 按
        // yaml iosControlSymbol 注入 vpnSiteMarkSystemSymbol。
        AppIntentControlConfiguration(kind: "VpnQuickToggleControl", intent: ToggleVpnIntent.self) { intent in
            ControlWidgetButton(action: intent) {
                // 常量三元 ⇒ 每品牌构建折叠为单一分支，不产生条件视图层级
                Label(vpnBrandDisplayName, image: vpnSiteMarkSystemSymbol.isEmpty ? "SiteMark" : vpnSiteMarkSystemSymbol)
            }
        }
        .displayName(LocalizedStringResource("vpn.widget.displayName"))
    }
}
