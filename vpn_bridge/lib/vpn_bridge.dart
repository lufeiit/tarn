import 'package:flutter/services.dart';

/// iOS VPN 桥：控制 PacketTunnel 扩展（NEVPNManager）+ App Group 消息转发。
/// 其余平台调用会抛出 UnsupportedError。
class VpnBridge {
  VpnBridge._();

  static const MethodChannel _channel =
      MethodChannel('com.tarn.app/vpn_bridge');

  /// 确保 VPN 配置存在（首次创建 NETunnelProvider 配置并保存）
  static Future<bool> ensureConfigured({String providerBundleId = ''}) async {
    return await _channel.invokeMethod<bool>(
          'ensureConfigured',
          {'providerBundleId': providerBundleId},
        ) ??
        false;
  }

  /// 启动 VPN（连接 PacketTunnel 扩展）
  static Future<bool> start() async {
    return await _channel.invokeMethod<bool>('start') ?? false;
  }

  /// 停止 VPN
  static Future<bool> stop() async {
    return await _channel.invokeMethod<bool>('stop') ?? false;
  }

  /// 当前 VPN 状态：disconnected/connecting/connected/disconnecting/invalid
  static Future<String> status() async {
    return await _channel.invokeMethod<String>('status') ?? 'unknown';
  }

  /// 向扩展发送一条 Action JSON（经 App Group 消息队列 + Darwin notify）
  static Future<bool> sendToExtension(String actionJson) async {
    return await _channel.invokeMethod<bool>(
          'sendToExtension',
          {'json': actionJson},
        ) ??
        false;
  }

  /// 读取扩展回写的结果 JSON（id 对应 Action.id），无则返回 null
  static Future<String?> readResult(String id) async {
    return await _channel.invokeMethod<String>('readResult', {'id': id});
  }

  /// 清除某条结果
  static Future<void> clearResult(String id) async {
    await _channel.invokeMethod('clearResult', {'id': id});
  }

  /// 获取 App Group 容器路径（主 App 与扩展共享数据目录）
  static Future<String?> groupContainerPath() async {
    return await _channel.invokeMethod<String>('groupContainerPath');
  }

  /// 写入核心初始化参数到 App Group（扩展启动时 quickSetup 读取）
  static Future<bool> setCoreConfig({
    String? initParamsJson,
    String? setupParamsJson,
  }) async {
    return await _channel.invokeMethod<bool>('setCoreConfig', {
      if (initParamsJson != null) 'initParams': initParamsJson,
      if (setupParamsJson != null) 'setupParams': setupParamsJson,
    }) ??
        false;
  }

  /// 读取扩展进程写入的诊断日志（App Group extLog key）
  static Future<String> readExtLog() async {
    return await _channel.invokeMethod<String>('readExtLog') ?? '';
  }

  /// 诊断：当前 vpn_bridge 插件原生版本标记（用于确认新代码已装上真机）
  static Future<String> diagVersion() async {
    return await _channel.invokeMethod<String>('diagVersion') ?? 'unknown';
  }

  /// 诊断：系统里 VPN 配置的现场快照（几条、每条归属哪个 provider、是否启用、隧道状态）。
  /// `status()` 只能回 invalid，分不出「没配置」「被别的品牌挤成 disabled」「隧道自己
  /// notLoaded」——三种修法不同。真机自测把它写进 selftest.txt，报告才讲得清原因。
  static Future<String> diagVpn() async {
    try {
      // 必须带超时：这个快照走的也是 loadAllFromPreferences，而它正是会「不返回」的那个
      // 调用（run 762 里 ensureConfigured 就是这么卡满 15 秒超时的）。不罩住的话，
      // 自测会因为拍快照而永远跑不到收尾行，报告就只能念「没有汇总行」。
      return await _channel
              .invokeMethod<String>('diagVpn')
              .timeout(const Duration(seconds: 6)) ??
          'unknown';
    } catch (e) {
      return '调用异常:$e';
    }
  }

  /// 诊断：设置扩展最小隧道模式（true=跳过 Go 内核，仅纯 Swift 建隧道）
  static Future<void> setMinMode(bool enabled) async {
    await _channel.invokeMethod('setMinMode', {'enabled': enabled});
  }

  static Future<void> setFdBridge(bool enabled) async {
    await _channel.invokeMethod('setFdBridge', {'enabled': enabled});
  }

  /// App 进程 phys_footprint（字节）；iOS 内存卡片用它与内核同一口径。
  static Future<int?> appPhysFootprint() async {
    return _channel.invokeMethod<int>('appPhysFootprint');
  }
}
