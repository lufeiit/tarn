import 'dart:convert';
import 'dart:io';

import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/models/models.dart';
import 'package:yaml/yaml.dart';

/// iOS 无内核（未开 VPN / PacketTunnel 扩展未运行）时的本地兜底：
/// 直接解析当前订阅 Profile 的 YAML（App Group 容器内主 App 可读，加密订阅解密到内存），
/// 构造与内核 handleGetProxies 一致形状的 ProxiesData，使「未开 VPN」也能展示节点。
class IosLocalProxies {
  IosLocalProxies._();

  static const _kernelDefaultTestUrl = 'https://www.gstatic.com/generate_204';

  /// 由应用入口（main.dart）注册，返回当前 Profile（可为空）。
  static Profile? Function()? currentProfileGetter;

  /// 由应用入口（main.dart）注册，返回当前**出站模式**（simple / global / split）。
  ///
  /// 为什么必须注册：Tarn 订阅**一次性下发两套完整配置**
  /// （`lfexp-simple-proxy-groups` 与 `lfexp-split-proxy-groups`），离线兜底必须按当
  /// 前模式选套，与在线路径保持一致。未注册时按规则模式处理。
  static Mode Function()? outboundModeGetter;

  static void register({
    Profile? Function()? currentProfile,
    Mode Function()? outboundMode,
  }) {
    currentProfileGetter = currentProfile;
    outboundModeGetter = outboundMode;
  }

  /// 兜底链路的失败必须留痕：2026-09-19 真机上「分组不出现」曾无任何日志可查，
  /// 只能靠猜（实际上是选套漏了模式，见 _pickProxyGroups）。
  static void _log(String msg) {
    commonPrint.log('IosLocalProxies: $msg', logLevel: LogLevel.warning);
  }

  /// 读取当前 Profile 配置内容（加密订阅走 Profile.decryptSubscribeContent 解密）。
  static Future<String?> readCurrentProfileYaml() async {
    final profile = currentProfileGetter?.call();
    if (profile == null) {
      _log(
        '本地兜底跳过：当前 Profile 为空（回调${currentProfileGetter == null ? '未注册' : '已注册但返回 null'}）',
      );
      return null;
    }
    final path = await appPath.getProfilePath('${profile.id}');
    final file = File(path);
    if (!await file.exists()) {
      _log('本地兜底失败：订阅文件不存在 $path');
      return null;
    }
    // 订阅一律密文落盘：直接 readAsString 拿到的是
    // `LFPROF2!` 信封，YAML 解析必然失败，表现为「订阅导入成功但没有策略组」。
    if (await ProfileContentCipher.isEncrypted(file)) {
      final plain = await ProfileContentCipher.readPlaintext(file, profile.id);
      if (plain == null) {
        _log('本地兜底失败：订阅已加密且解密失败 $path');
        return null;
      }
      return plain;
    }
    final text = await file.readAsString();
    return text;
  }

  static Future<ProxiesData?> buildProxiesData() async {
    final yamlString = await readCurrentProfileYaml();
    if (yamlString == null || yamlString.isEmpty) return null;
    final data = proxiesDataFromYamlString(yamlString);
    if (data == null) {
      _log('本地兜底失败：订阅 YAML 解析为空（长度 ${yamlString.length}）');
      return null;
    }
    if (data.all.isEmpty) {
      _log(
        '本地兜底得到 0 个分组：模式=${outboundModeGetter?.call().name ?? '未注册'}，'
        '订阅里 proxy-groups / lfexp-simple-proxy-groups / lfexp-split-proxy-groups 均为空',
      );
    }
    return data;
  }

  static Future<ProxiesData> alignKernelTestUrls(
    ProxiesData live, {
    Future<ProxiesData?> Function() readLocal = buildProxiesData,
  }) async {
    final candidates = live.all.where((name) {
      final group = live.proxies[name];
      if (group is! Map) return false;
      final url = group['testUrl'];
      return url == null || url == '' || url == _kernelDefaultTestUrl;
    }).toList();
    if (candidates.isEmpty) return live;
    final local = await readLocal();
    if (local == null) return live;
    // mihomo may supply gstatic (or omit it for selectors). Prefer the YAML
    // for those ambiguous values so a refresh does not change the delay key.
    final proxies = {...live.proxies};
    var changed = false;
    for (final name in candidates) {
      final savedGroup = local.proxies[name];
      final runtimeGroup = live.proxies[name] as Map;
      if (savedGroup is! Map || savedGroup['testUrl'] is! String) continue;
      final url = savedGroup['testUrl'];
      if (runtimeGroup['testUrl'] == url) continue;
      proxies[name] = {
        ...Map<String, dynamic>.from(runtimeGroup),
        'testUrl': url,
      };
      changed = true;
    }
    return changed ? live.copyWith(proxies: proxies) : live;
  }

  /// getConfig 兜底：返回当前 Profile 的原始配置 Map（**已按当前模式选好组/规则套**）。
  static Future<Map<String, dynamic>?> buildConfigMap() async {
    final yamlString = await readCurrentProfileYaml();
    if (yamlString == null || yamlString.isEmpty) return null;
    return configMapFromYamlString(yamlString);
  }

  /// 把一份订阅 YAML 解析成配置 Map（按当前出站模式选套）。
  ///
  /// 公开出来是给 `profile.outbounds` 的本地兜底用：扩展没运行时，节点/分组
  /// 列表也得有东西可展示（官方协议里这一步本来在内核里）。
  static Map<String, dynamic>? configMapFromYamlString(
    String yamlString, {
    Mode? mode,
  }) {
    if (yamlString.isEmpty) return null;
    try {
      final raw = loadYaml(yamlString);
      if (raw is! Map) {
        _log('本地兜底失败：订阅 YAML 顶层不是 Map（实际 ${raw.runtimeType}）');
        return null;
      }
      final map = _toPlainMap(raw);
      _applyOutboundMode(map, mode: mode);
      return map;
    } catch (e) {
      _log('本地兜底失败：订阅 YAML 解析异常 $e');
      return null;
    }
  }

  /// 交给内核的配置正文（`SetupBase.content`）：按出站模式选好组/规则再编码。
  ///
  /// Tarn 订阅一次下发两套（simple / split），面板的 `proxy-groups` 固定是 simple。
  /// 内核只认 `proxy-groups` / `rules`，不认 `lfexp-*` 扩展键 ⇒ 不在这里换套，
  /// 分流模式会拿到默认的简单组和简单规则。
  static String? prepareKernelContent(
    String? yamlString,
    Mode mode, {
    String deviceId = '',
    String deviceName = '',
  }) {
    if (yamlString == null || yamlString.isEmpty) return yamlString;
    final split =
        mode == Mode.rule &&
        yamlString.contains('lfexp-split-proxy-groups') &&
        yamlString.contains('lfexp-split-rules');
    // iOS 不提供 MITM：即使订阅里带 mitm 段也剥掉，不留可被远程开启的能力。
    final hasMitm = RegExp(r'^mitm:', multiLine: true).hasMatch(yamlString);
    if (!split &&
        !hasMitm &&
        (deviceId.isEmpty || !yamlString.contains('lfexp'))) {
      return yamlString;
    }
    final map = configMapFromYamlString(yamlString, mode: mode);
    if (map == null) return yamlString;
    final strippedMitm = map.remove('mitm') != null;
    if (!setLfexpDevice(map, deviceId, deviceName) && !split && !strippedMitm) {
      return yamlString;
    }
    try {
      // JSON 是 YAML 的子集，内核的 yaml 解析器直接吃。
      return jsonEncode(map);
    } catch (e) {
      _log('按模式重编码配置失败（保留原文）：$e');
      return yamlString;
    }
  }

  static bool setLfexpDevice(
    Map<String, dynamic> config,
    String id,
    String name,
  ) {
    final proxies = config['proxies'];
    if (id.isEmpty || proxies is! List) return false;
    var changed = false;
    for (final proxy in proxies) {
      if (proxy is Map && proxy['type'] == 'lfexp') {
        proxy['device-id'] = id;
        proxy['device-name'] = name;
        changed = true;
      }
    }
    return changed;
  }

  /// 订阅没给 `proxy-server-nameserver` 时补 DoH over IP。
  ///
  /// iOS 的 TUN 带 `dns-hijack: any:53`，内核自己发往 UDP 53 的查询会被自己劫持，
  /// 节点域名解析不出来（历史故障：AnyTLS 全部 dns resolve failed）。
  /// 面板的 Tarn 订阅自带私有 DoH（50101/33037），**有就必须保留**——
  /// `npc-a.cloud` 这类入口域名只有面板的 DNS 能解，公网 DoH 查不到。
  static void ensureProxyServerNameserver(Map<String, dynamic> config) {
    final dns = config['dns'];
    final map = dns is Map
        ? Map<String, dynamic>.from(dns)
        : <String, dynamic>{};
    final existing = map['proxy-server-nameserver'];
    if (existing is List && existing.isNotEmpty) return;
    map['proxy-server-nameserver'] = const [
      'https://223.5.5.5/dns-query',
      'https://1.12.12.12/dns-query',
    ];
    config['dns'] = map;
  }

  /// 与桌面一致：只有完整的分流组和规则同时存在时才换套。
  static void _applyOutboundMode(Map<String, dynamic> map, {Mode? mode}) {
    if ((mode ?? outboundModeGetter?.call() ?? Mode.rule) != Mode.rule) return;
    final groups = map['lfexp-split-proxy-groups'];
    final rules = map['lfexp-split-rules'];
    if (groups is! List || rules is! List) return;
    map['proxy-groups'] = groups;
    map['rules'] = rules.map((e) => '$e').toList();
    final providers = map['lfexp-split-rule-providers'];
    if (providers is Map && providers.isNotEmpty) {
      map['rule-providers'] = providers;
    }
  }

  /// 将订阅 YAML 转为与内核 handleGetProxies 一致形状的 ProxiesData。
  static ProxiesData? proxiesDataFromYamlString(String yamlString) {
    final raw = configMapFromYamlString(yamlString);
    if (raw == null) return null;

    // 内置节点（内核侧同样存在 DIRECT / REJECT）
    final proxies = <String, dynamic>{
      'DIRECT': <String, dynamic>{'name': 'DIRECT', 'type': 'Direct'},
      'REJECT': <String, dynamic>{'name': 'REJECT', 'type': 'Reject'},
    };

    final proxyList = raw['proxies'];
    if (proxyList is List) {
      for (final item in proxyList) {
        if (item is! Map) continue;
        final name = item['name'];
        if (name is! String || name.isEmpty) continue;
        final plain = <String, dynamic>{};
        for (final entry in item.entries) {
          plain['${entry.key}'] = _plainValue(entry.value);
        }
        proxies[name] = plain;
      }
    }

    final all = <String>[];
    var hasGlobal = false;
    final groupsRaw = raw['proxy-groups'];
    final groupList = groupsRaw is List ? groupsRaw : const [];
    for (final item in groupList) {
      if (item is! Map) continue;
      final name = item['name'];
      if (name is! String || name.isEmpty) continue;
      final yamlType = item['type'];
      if (yamlType is! String) continue;
      final groupType = _groupType(yamlType);
      if (groupType == null) continue;
      if (name == GroupName.GLOBAL.name) {
        hasGlobal = true;
      }
      final members = item['proxies'];
      final allList = (members is List)
          ? members.whereType<String>().toList()
          : <String>[];
      final testUrl = _groupTestUrl(item, raw['proxy-providers']);
      proxies[name] = <String, dynamic>{
        'name': name,
        'type': groupType.name,
        'all': allList,
        'hidden': item['hidden'] ?? false,
        'testUrl': testUrl,
        if (item['icon'] is String) 'icon': item['icon'],
      };
      all.add(name);
    }
    if (!hasGlobal) {
      all.insert(0, GroupName.GLOBAL.name);
      proxies[GroupName.GLOBAL.name] = <String, dynamic>{
        'name': GroupName.GLOBAL.name,
        'type': GroupType.Selector.name,
        'all': proxies.keys.toList(),
        // 分流/简单模式不该出现 GLOBAL；hidden 让规则模式的过滤把它剔掉，
        // 全局模式（不做 hidden 过滤）仍然拿得到。
        'hidden': true,
      };
    }
    return ProxiesData(proxies: proxies, all: all);
  }

  static String _groupTestUrl(Map group, Object? providers) {
    final configured = group['url'];
    var url = configured is String ? configured : '';
    final use = group['use'];
    if (url.isEmpty && use is List && providers is Map) {
      for (final name in use) {
        final provider = providers[name];
        final healthCheck = provider is Map ? provider['health-check'] : null;
        final candidate = healthCheck is Map ? healthCheck['url'] : null;
        if (candidate is String && candidate.isNotEmpty) {
          url = candidate;
          break;
        }
      }
    }
    return url;
  }

  static GroupType? _groupType(String type) {
    final lower = type.toLowerCase();
    for (final value in GroupType.values) {
      if (value.value == lower) return value;
    }
    return null;
  }

  static Object? _plainValue(Object? value) {
    if (value is Map) return _toPlainMap(value);
    if (value is List) return value.map(_plainValue).toList();
    return value;
  }

  static Map<String, dynamic> _toPlainMap(Map map) {
    final result = <String, dynamic>{};
    for (final entry in map.entries) {
      result['${entry.key}'] = _plainValue(entry.value);
    }
    return result;
  }
}
