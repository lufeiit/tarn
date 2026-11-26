import 'site_configs.g.dart';

/// 敏感域名脱敏与检查（加固）
///
/// 本文件在 main(桌面/安卓) 与 ios 两个分支必须逐字节相同（2026-10-25 合并：
/// 桌面补 `host:port` 后缀脱敏，iOS 补 `token:` 冒号形式与 `port=` 标签在 maskIp 内的
/// 覆盖；IPv6 两端原本都有）。
///
/// 背景：订阅中的私有域名（中转域名、私有 DoH 地址、Tarn 节点域名）
/// 不应以明文出现在可观测位置：
/// - 日志面板 / 导出日志（`Logs.add` 统一脱敏）
/// - `fake-ip-filter` / `hosts`（生成配置时自动清理）
///
/// 敏感域名来源：每次生成配置时自动提取（proxies.server、DNS 各段的域名，
/// 排除已知公共 DoH/DNS 域名），无需硬编码。
class SensitiveDomains {
  SensitiveDomains._();

  /// 打码总开关（2026-11-19 业主口径重新打开）。
  ///
  /// 只掩「配置文件里写死的东西」：节点 server、proxy-server-nameserver、
  /// IP-CIDR 规则、面板/OSS API 地址与路径、token/密钥、邮箱、设备 UUID。
  /// 用户自己访问的域名与 IP 一律原样显示。
  static const enabled = true;

  /// 配置清理（删 hosts / fake-ip-filter 里的订阅域名）与打码是两个口径：
  /// 业主只要「显示打码」，不要动用户配置，所以清理保持关闭。
  static const cleanConfigEnabled = false;

  /// 已收集的敏感域名（小写 host）
  static final Set<String> _domains = {};

  /// 节点服务器本身的 IP（订阅里直接写 IP 的那种），列表里只掩这些。
  static final Set<String> _servers = {};

  /// 展示层（连接 / 请求 / DNS 的列表与详情）需要打码的配置值：
  /// 节点 server、server:port、nameserver 地址、直连 IP-CIDR 网段等。
  /// 只收「配置文件里写死的东西」，不收 SNI 借用域名（否则用户访问
  /// cloudflare.com 这类公共站点也会被打码）。
  static final Set<String> _targets = {};

  /// 已收集的敏感 API 路径（如 /lufei/client/subscribe-hosts、/user/getSubscribe）
  /// 每个站点路径前缀可不同，按实际发起的请求动态注册。
  static final Set<String> _paths = {};

  /// host -> 脱敏显示形式
  static final Map<String, String> _maskCache = {};

  /// 常见公共 DoH/DNS 域名（不作为敏感域名）
  static const _publicDnsHosts = {
    'doh.pub',
    'dot.pub',
    'dns.alidns.com',
    'alidns.com',
    'dnspod.cn',
    'dnspod.com',
    'dns.dnspod.cn',
    'cloudflare-dns.com',
    'one.one.one.one',
    'dns.google',
    'google.com',
    'dns.quad9.net',
    'dns9.quad9.net',
    'adguard.com',
    'dns.adguard.com',
    'dns.nextdns.io',
    'doh.opendns.com',
    'dns.mullvad.net',
  };

  /// 公共 DNS 解析器 IP：nameserver 里出现时不算敏感（1.1.1.1 = Cloudflare、
  /// 8.8.8.8 = Google 等），展示层不打码。
  static const _publicDnsIps = {
    '1.1.1.1',
    '1.0.0.1',
    '8.8.8.8',
    '8.8.4.4',
    '9.9.9.9',
    '149.112.112.112',
    '208.67.222.222',
    '208.67.220.220',
    '223.5.5.5',
    '223.6.6.6',
    '119.29.29.29',
    '182.254.116.116',
    '180.76.76.76',
    '114.114.114.114',
    '114.114.115.115',
    '101.101.101.101',
    '77.88.8.8',
    '94.140.14.14',
    '76.76.2.0',
  };

  static bool _isPublicDns(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return false;
    if (_publicDnsIps.contains(text)) return true;
    final host = _dnsHostOf(text);
    return host != null && (_publicDnsIps.contains(host) || _isPublic(host));
  }

  static String? _dnsHostOf(String value) {
    final uri = Uri.tryParse(value.contains('://') ? value : '//$value');
    final host = uri?.host.toLowerCase();
    return host == null || host.isEmpty ? _hostOf(value) : host;
  }

  static bool get isEmpty => _domains.isEmpty && _servers.isEmpty;

  static bool isProprietaryOnlyConfig(Map<String, dynamic> config) {
    final proxies = config['proxies'];
    final providers = config['proxy-providers'];
    return proxies is List &&
        proxies.isNotEmpty &&
        (providers == null || (providers is Map && providers.isEmpty)) &&
        proxies.every(
          (node) =>
              node is Map && '${node['type']}'.trim().toLowerCase() == 'lfexp',
        );
  }

  /// 从订阅配置 + 补丁 DNS 配置中提取私有域名
  static ({Set<String> domains, Set<String> servers, Set<String> targets})
  extractFromConfig(
    Map<String, dynamic> rawConfig, {
    Map<String, dynamic>? patchDnsJson,
  }) {
    final domains = <String>{};
    final servers = <String>{};
    final targets = <String>{};
    // 1) proxies.server（节点/中转域名）+ sni（借用域名，也脱敏）
    final proxies = rawConfig['proxies'];
    if (proxies is List) {
      for (final p in proxies) {
        if (p is! Map) continue;
        final server = p['server'];
        if (server is String) {
          final host = _hostOf(server);
          if (_isIpLiteral(server)) {
            servers.add(server);
            targets.add(server);
          } else if (host != null) {
            domains.add(host);
            targets.add(host);
            final port = p['port'];
            if (port is num) {
              targets.add('$host:${port.toInt()}');
            }
          }
        }
        // SNI 是「借用域名」（常是 www.microsoft.com、cloudflare.com 这类公共
        // 站点），只用于日志池的泛化脱敏，不进展示层 targets —— 否则用户正常
        // 访问这些站点时，连接 / 请求列表里的目标也会被打码。
      }
    }
    // 2) 订阅自带 dns 段
    final dns = rawConfig['dns'];
    if (dns is Map) {
      _collectDnsDomains(dns, domains, targets);
    }
    // 3) 补丁 dns 段（用户 DNS 设置里可能配置了私有 DoH）
    if (patchDnsJson != null) {
      _collectDnsDomains(patchDnsJson, domains, targets);
    }
    // 4) 规则里的直连 IP 段（IP-CIDR,156.238.242.78/32,DIRECT）
    final rules = rawConfig['rules'];
    if (rules is List) {
      for (final rule in rules) {
        final text = rule?.toString() ?? '';
        for (final m in _ipCidrReg.allMatches(text)) {
          targets.add(m.group(0)!);
          targets.add(m.group(1)!);
        }
      }
    }
    return (domains: domains, servers: servers, targets: targets);
  }

  static bool _isIpLiteral(String value) {
    final host = value.split(':').first.trim();
    return RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
  }

  static void _collectDnsDomains(
    Map dns,
    Set<String> domains,
    Set<String> targets,
  ) {
    for (final key in const [
      'nameserver',
      'fallback',
      'proxy-server-nameserver',
      'default-nameserver',
    ]) {
      final value = dns[key];
      _collectServerValue(value, domains, targets);
    }
    final policy = dns['nameserver-policy'];
    if (policy is Map) {
      for (final v in policy.values) {
        _collectServerValue(v, domains, targets);
      }
    }
  }

  static void _collectServerValue(
    Object? value,
    Set<String> domains,
    Set<String> targets,
  ) {
    final items = value is List
        ? value
        : (value is String ? [value] : const []);
    for (final item in items) {
      final raw = item?.toString().trim() ?? '';
      if (raw.isEmpty) continue;
      final host = _dnsHostOf(raw);
      if (_isPublicDns(raw)) continue;
      if (host != null) {
        domains.add(host);
        targets.add(raw);
        targets.add(host.contains(':') ? '[$host]' : host);
      } else if (_isIpLiteral(raw)) {
        targets.add(raw.split('/').first);
      }
    }
  }

  static bool _isPublic(String host) {
    for (final p in _publicDnsHosts) {
      if (host == p || host.endsWith('.$p')) return true;
    }
    return false;
  }

  /// 从 server/URL 取 host（支持 host、host:port、scheme://host[:port]/path、
  /// socks5://、tls://、https:// 等），纯 IP 不算（IP 是另一维度的暴露面）。
  static String? _hostOf(String server) {
    var s = server.trim();
    if (s.isEmpty) return null;
    final schemeIdx = s.indexOf('://');
    if (schemeIdx >= 0) {
      s = s.substring(schemeIdx + 3);
    }
    // 去掉路径
    final slash = s.indexOf('/');
    if (slash >= 0) {
      s = s.substring(0, slash);
    }
    // IPv6 字面量
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end > 0) return s.substring(1, end).toLowerCase();
    }
    // host:port（仅一位冒号）
    final colon = s.lastIndexOf(':');
    if (colon > 0 && s.indexOf(':') == colon) {
      s = s.substring(0, colon);
    }
    if (s.isEmpty) return null;
    final host = s.toLowerCase();
    // 纯 IP 跳过（IPv4 与 IPv6 字面量均不纳入域名池，IP 是另一维度的暴露面）
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host)) return null;
    if (host.contains(':')) return null;
    return host;
  }

  /// 更新全局池（供日志脱敏使用）
  static void update(
    Iterable<String> domains, {
    Iterable<String> servers = const [],
    Iterable<String> targets = const [],
  }) {
    _domains
      ..clear()
      ..addAll(domains.map((e) => e.toLowerCase()).where((e) => e.isNotEmpty));
    _servers
      ..clear()
      ..addAll(servers.where((e) => e.isNotEmpty));
    _targets
      ..clear()
      ..addAll(targets.where((e) => e.isNotEmpty));
    _maskCache.clear();
    for (final d in _domains) {
      _maskCache[d] = _maskDomain(d);
    }
  }

  /// 文本是否包含敏感域名
  static bool containsDomain(String text) {
    if (!_active) return false;
    final lower = text.toLowerCase();
    for (final d in _domains) {
      if (lower.contains(d)) return true;
    }
    return false;
  }

  /// 清理配置中的 hosts / fake-ip-filter，返回检查提示（已脱敏）
  static List<String> cleanConfig(Map<String, dynamic> rawConfig) {
    final notes = <String>[];
    if (!cleanConfigEnabled) return notes;
    if (isEmpty) return notes;
    final hosts = rawConfig['hosts'];
    if (hosts is Map) {
      final badKeys = hosts.keys
          .where((k) => containsDomain(k.toString()))
          .toList();
      if (badKeys.isNotEmpty) {
        notes.add(
          'hosts 中已移除订阅域名：${badKeys.map((e) => mask(e.toString())).join(', ')}',
        );
        for (final k in badKeys) {
          hosts.remove(k);
        }
      }
    }
    final dns = rawConfig['dns'];
    if (dns is Map) {
      final filter = dns['fake-ip-filter'];
      if (filter is List) {
        final before = filter.length;
        filter.removeWhere((e) => containsDomain(e.toString()));
        if (filter.length != before) {
          notes.add('dns.fake-ip-filter 中已移除订阅域名');
        }
      }
    }
    return notes;
  }

  /// 清理用户补丁配置中的 hosts（返回新 map，未变则原引用）
  static Map<String, String> cleanPatchHosts(Map<String, String> hosts) {
    if (!cleanConfigEnabled || isEmpty || hosts.isEmpty) return hosts;
    final bad = hosts.keys.where((e) => containsDomain(e)).toList();
    if (bad.isEmpty) return hosts;
    return {
      for (final e in hosts.entries)
        if (!containsDomain(e.key)) e.key: e.value,
    };
  }

  /// 连接 / 请求 / DNS 的列表与详情里展示目标时用。
  ///
  /// 只掩「配置文件里写死的入口」：节点 server（域名与 IP）、server:port、
  /// nameserver 地址、直连 IP-CIDR 网段、站点 API/OSS 地址。用户自己访问的
  /// 其它域名与 IP 原样显示（因此 cloudflare.com 这类公共站点不会被打码）。
  static String maskEndpoint(String? text) {
    if (!_active) {
      return text ?? '';
    }
    if (text == null || text.isEmpty) return text ?? '';
    if (!maskEnabled) return text;
    var out = maskApiBase(text);
    // 长串优先，保证 host:port 先于 host 命中。
    final sorted = _targets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final target in sorted) {
      out = out.replaceAll(target, _maskTargetValue(target));
      final lower = target.toLowerCase();
      if (lower != target) {
        out = out.replaceAll(lower, _maskTargetValue(lower));
      }
    }
    // 规则里可能出现未收进池的其它 IP-CIDR 形态，统一按网段打码。
    out = out.replaceAllMapped(
      _ipCidrReg,
      (m) => '${_maskIp(m.group(1)!)}/${m.group(2)}',
    );
    return maskMaskedPorts(out);
  }

  /// host 是否属于「配置文件里写死的入口」（节点域名 / nameserver）。
  static bool isSensitiveHost(String? host) {
    if (!_active) return false;
    final h = (host ?? '').trim().toLowerCase();
    if (h.isEmpty) return false;
    if (_domains.contains(h) || _targets.contains(h)) return true;
    return _targets.any((t) => t.toLowerCase() == h);
  }

  /// 带上下文的打码：`host` 是敏感入口时，`value`（通常是它解析出的 IP /
  /// 远程目标）也要打码；否则按普通端点规则处理。
  ///
  /// 为什么需要：连接与 DNS 列表里域名已打码，但「远程目标 35.78.26.28」
  /// 是同一台节点的解析结果，只掩域名等于没掩。
  static String maskResolvedValue(String? host, String? value) {
    if (value == null || value.isEmpty) return value ?? '';
    if (!_active || !maskEnabled) return value;
    if (isSensitiveHost(host)) {
      return maskIp(value);
    }
    return maskEndpoint(value);
  }

  /// 单个 target 的展示形态：host:port / CIDR / IP / 域名 / URL。
  static String _maskTargetValue(String target) {
    final cidr = _ipCidrReg.firstMatch(target);
    if (cidr != null) {
      return '${_maskIp(cidr.group(1)!)}/${cidr.group(2)}';
    }
    if (target.contains('://') || target.startsWith('[')) {
      final uri = Uri.tryParse(target.startsWith('[') ? '//$target' : target);
      if (uri != null && uri.host.isNotEmpty) {
        final host = _maskHost(uri.host);
        final authority = target
            .split('://')
            .last
            .split(RegExp(r'[/#?]'))
            .first;
        final port = RegExp(r':\d{1,5}$').hasMatch(authority) ? ':***' : '';
        return uri.hasScheme
            ? '${uri.scheme}://$host$port/***'
            : '[$host]$port';
      }
    }
    final colon = target.lastIndexOf(':');
    if (colon > 0 && target.indexOf(':') == colon && !target.contains('/')) {
      final host = target.substring(0, colon);
      final port = target.substring(colon + 1);
      if (RegExp(r'^\d{1,5}$').hasMatch(port)) {
        return '${_maskHost(host)}:***';
      }
    }
    if (_ipCidrReg.hasMatch(target)) {
      return _maskIp(target);
    }
    if (RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(target)) {
      return _maskIp(target);
    }
    return _maskHost(target);
  }

  /// IP-CIDR / IP-CIDR6 规则里的 IPv4 网段（`156.238.242.78/32`）。
  static final RegExp _ipCidrReg = RegExp(
    r'\b(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})\b',
  );

  static String _maskIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return ip;
    return '${parts[0]}.${parts[1]}.*.*';
  }

  /// 日志/文本脱敏：把文本中的敏感域名替换为脱敏形式
  static String mask(String? text) {
    if (!_active) {
      return text ?? '';
    }
    if (text == null || text.isEmpty || isEmpty) return text ?? '';
    var out = text;
    for (final entry in _maskCache.entries) {
      final host = entry.key;
      if (host.isEmpty) continue;
      out = out.replaceAll(host, entry.value);
    }
    return out;
  }

  static final RegExp _ipv4Reg = RegExp(
    r'\b(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}\b(?::\d{1,5})?',
  );

  /// 方括号 IPv6 字面量（如 [240e::1]、[::ffff:1.2.3.4]），整体打码（含端口）
  static final RegExp _ipv6BracketReg = RegExp(
    r'\[[0-9a-fA-F:.]+\](?::\d{1,5})?',
  );

  /// 裸 IPv6：覆盖完整 8 组与压缩 :: 形式。前后用捕获组限定边界
  /// （非字母数字），避免误伤时间（21:53:18）、命名空间（std::string）等。
  static final RegExp _ipv6Reg = RegExp(
    r'(^|[^0-9a-zA-Z])(?:'
    r'(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'
    r'|(?:[0-9a-fA-F]{1,4}:){1,7}:'
    r'|(?:[0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}'
    r'|(?:[0-9a-fA-F]{1,4}:){1,5}(?::[0-9a-fA-F]{1,4}){1,2}'
    r'|(?:[0-9a-fA-F]{1,4}:){1,4}(?::[0-9a-fA-F]{1,4}){1,3}'
    r'|(?:[0-9a-fA-F]{1,4}:){1,3}(?::[0-9a-fA-F]{1,4}){1,4}'
    r'|(?:[0-9a-fA-F]{1,4}:){1,2}(?::[0-9a-fA-F]{1,4}){1,5}'
    r'|[0-9a-fA-F]{1,4}:(?::[0-9a-fA-F]{1,4}){1,6}'
    r'|:(?::[0-9a-fA-F]{1,4}){1,7}'
    r'|::'
    r')(?::\d{1,5})?([^0-9a-zA-Z]|$)',
  );

  /// 日志/文本中的 IP 脱敏：
  /// - IPv4 保留前两段，后两段打掩码（如 47.103.***.***；含端口）
  /// - IPv6 整体打码（如 v6:***，方括号形式 [v6]***）
  /// - `port=28001` 这类显式端口字段 → `port=***`（内核 `dial ok node=x port=…` 形态）
  static String maskIp(String? text) {
    if (!_active) {
      return text ?? '';
    }
    if (text == null || text.isEmpty) return text ?? '';
    // 顺序：方括号 IPv6 优先（避免内部 IPv4 段被单独命中），再 IPv4，最后裸 IPv6
    var out = text.replaceAllMapped(_ipv6BracketReg, (_) => '[v6]***');
    out = out.replaceAllMapped(_ipv4Reg, (m) => '${m[1]}.***.***');
    out = out.replaceAllMapped(
      _ipv6Reg,
      (m) => '${m[1]}v6:***${m[m.groupCount]}',
    );
    out = out.replaceAllMapped(_portLabelReg, (m) => '${m[1]}***');
    return out;
  }

  /// 面板 API base（含品牌前缀/安全路径），日志中整体脱敏为 host.***.***.***/***
  static final List<String> _apiBases = [];

  /// 站点配置里写死的 OSS/API 地址：`updateApiBases` 会用面板地址整表覆盖，
  /// 不单独保留就会被冲掉（启动日志里 OSS 域名因此一直明文）。
  static final List<String> _fixedBases = [];

  /// 站点配置里写死的 OSS/API 地址（启动时注册一次）。
  /// 订阅拉取前的日志（remote config 签名缺失、OSS 探测）就带着这些地址，
  /// 只靠订阅提取的池覆盖不到，启动阶段会整段明文打出来。
  static void registerFixedUrls(Iterable<String> urls) {
    for (final u in urls) {
      final b = u.trim();
      if (b.isEmpty || _fixedBases.contains(b)) continue;
      _fixedBases.add(b);
      if (!_apiBases.contains(b)) _apiBases.add(b);
    }
  }

  /// 单条 API base 追加（请求发出时用：登录阶段的日志在 applyProfile 之前，
  /// 那时站点列表还没注册，结果 [PANEL] 日志里 host 与端口全是明文）。
  static void addApiBase(String base) {
    final b = base.trim();
    if (b.isEmpty || _apiBases.contains(b)) return;
    _apiBases.add(b);
  }

  /// 学到一个节点的解析 IP：节点域名在 DNS 查询里解析出来的地址，就是连接
  /// 详情里「远程目标」会显示的那个 IP，只掩域名等于没掩。
  static void learnResolved(String? host, Iterable<String> values) {
    if (!_active || !isSensitiveHost(host)) return;
    for (final raw in values) {
      final value = raw.trim();
      if (value.isEmpty) continue;
      final isV4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(value);
      final isV6 = value.contains(':') && !value.contains('://');
      if (!isV4 && !isV6) continue;
      _targets.add(value);
    }
  }

  /// 更新 API base 列表（来自站点远程 domain / 登录探测到的面板地址）
  static void updateApiBases(Iterable<String> bases) {
    _apiBases
      ..clear()
      ..addAll(bases.map((e) => e.trim()).where((e) => e.isNotEmpty));
    for (final b in _fixedBases) {
      if (!_apiBases.contains(b)) _apiBases.add(b);
    }
  }

  // 注：不要使用 lookbehind（(?<!...)）与内联修饰符（(?i)）——Dart VM 运行时
  // 会抛 FormatException: Invalid group。大小写用 caseSensitive: false 控制。
  static final RegExp _querySensitiveReg = RegExp(
    r'(^|[^a-zA-Z0-9_])(token|key|secret|auth|authorization|password|subscribe_?_?key|access[_-]?key|session)\s*[:=]\s*[^\s&#,;:]+',
    caseSensitive: false,
  );

  /// 令牌/密钥值脱敏（token=xxx / key=xxx / session=xxx，含 `token: xxx` 冒号形式 → 值替换为 ***。
  /// 冒号形式必须有：IPC data 里是 `{token: xxx}` 形态，只有等号形式会漏（2026-10-25 跨端合并）。
  static String maskQueryParams(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(
      _querySensitiveReg,
      (m) => '${m[1]}${m[2]}=***',
    );
  }

  /// 任意 scheme URL 整体脱敏（不依赖 _apiBases）：
  /// https://v2-test.123155.xyz/lufei/user/getSubscribe?token=xxx
  ///   → https://v2-test.***.xyz/***
  static final RegExp _urlReg = RegExp(
    r'''(https?|socks5?|tls|hysteria2?)://[^\s"'<>]+''',
    caseSensitive: false,
  );

  static String maskUrls(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_urlReg, (m) {
      final raw = m.group(0)!;
      final uri = Uri.tryParse(raw);
      if (uri == null || uri.host.isEmpty) return raw;
      return '${uri.scheme}://${_maskHost(uri.host)}/***';
    });
  }

  /// 注册敏感路径（实际请求过的面板 API 路径，含站点前缀）
  static void addPath(String path) {
    final p = path.trim();
    if (p.isEmpty || !p.startsWith('/')) return;
    _paths.add(p);
  }

  static void addPaths(Iterable<String> paths) {
    for (final p in paths) {
      addPath(p);
    }
  }

  /// 日志中的路径脱敏：已注册的 API 路径（含 query 前部分）替换为 /***
  /// 长路径优先（如 /lufei/client/subscribe-hosts 先于 /client/subscribe-hosts）。
  static String maskPaths(String? text) {
    if (text == null || text.isEmpty || _paths.isEmpty) return text ?? '';
    final sorted = _paths.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    var out = text;
    for (final p in sorted) {
      out = out.replaceAll(p, '/***');
    }
    return out;
  }

  /// API base 整体脱敏（域名+路径+订阅 URL 段）：
  /// https://v2-test.123155.xyz/lufei/client/subscribe?token=... → v2-test.***.xyz/***
  static String maskApiBase(String? text) {
    if (!_active || text == null || text.isEmpty || _apiBases.isEmpty) {
      return text ?? '';
    }
    var out = text;
    for (final base in _apiBases) {
      if (base.isEmpty) continue;
      final uri = Uri.tryParse(base);
      if (uri == null) continue;
      final host = uri.host;
      if (host.isEmpty) continue;
      final maskedHost = _maskHost(host);
      // 以 host 开头的 URL 段整体替换（含端口与 path/query）。
      // 保留 IPv4 CIDR 的 /32 等网段长度，不把它当 API 路径。
      final esc = RegExp.escape(host.contains(':') ? '[$host]' : host);
      final urlRe = RegExp(
        '''(^|[^A-Za-z0-9_.-])$esc(?::([0-9]{1,5}))?'''
        r'''(?![A-Za-z0-9_.:-])([/?#][^\s"'<>,]*)?''',
        caseSensitive: false,
      );
      out = out.replaceAllMapped(urlRe, (m) {
        final path = m[3];
        final suffix = path == null
            ? ''
            : _isIpLiteral(host) &&
                  m[2] == null &&
                  RegExp(r'^/\d{1,2}$').hasMatch(path)
            ? path
            : '/***';
        return '${m[1]}$maskedHost${m[2] == null ? '' : ':***'}$suffix';
      });
    }
    return out;
  }

  /// 域名掩码：保留首段与顶级域，中间段打 *（如 v2-test.***.xyz）；
  /// IPv4 保留前两段，后两段打 *（如 47.103.***.***）；IPv6 整体打码。
  static String _maskHost(String host) {
    if (_ipv4Reg.hasMatch(host)) {
      final parts = host.split('.');
      return '${parts[0]}.${parts[1]}.***.***';
    }
    if (host.contains(':')) return 'v6:***';
    return _maskDomain(host);
  }

  /// 端口脱敏：`host:28001` → `host:***`（仅 4~5 位端口）。
  ///
  /// 2026-09-14：用户报告「客户端日志里仍能看到节点连接端口」。原因是域名/IP 掩码
  /// 只处理 host，**端口原样保留**（`hk01.***.xyz:28001`、`npc-v6.cloud:28001`），
  /// 而 mihomo 内核日志的 `[TCP] ... --> host:port` 正是日志页最常见的形态。
  /// 不用 lookbehind（Dart VM 运行时会抛 FormatException），用捕获组。
  static final RegExp _portReg = RegExp(r'([a-zA-Z0-9.\]]):(\d{4,5})(?![0-9])');

  /// 显式端口字段：`port=28001` / `port: 28001` → `port=***`。
  ///
  /// 内核 `dial ok node=... port=%d`（Tarn client）属这种形态，不是 host:port，
  /// 2026-09-14 真机日志里 `port=28001` 出现 3985 次。注意不用内联修饰符
  /// （`(?i)`），Dart VM 运行时会抛 FormatException —— 用 caseSensitive 控制。
  static final RegExp _portLabelReg = RegExp(
    r'(port\s*[=:]\s*)\d{1,5}(?![0-9])',
    caseSensitive: false,
  );

  static String maskPort(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    var out = text.replaceAllMapped(_portReg, (m) => '${m[1]}:***');
    out = out.replaceAllMapped(_portLabelReg, (m) => '${m[1]}***');
    return out;
  }

  /// —— 通用主机名脱敏（2026-10-26 改口径：不再依赖订阅白名单）——
  ///
  /// 站点的 OSS 地址、API 域名、镜像域名以后会随时换，靠 [extractFromConfig]
  /// 从订阅里收集的池子永远慢一拍（真机日志里的漏网实例：`ip-api.com`、
  /// `Failed host lookup: 'v6.ip.zxinc.org'`）。现在改成：日志里出现的
  /// **每一个像主机名的串都打掩**（首段.***.末段，与旧口径同形）。三类放过：
  /// 1. 文件名 / 成员访问后缀（`.dart`、`.json`、`d.path`、`e.message` …，
  ///    见 [_wordSuffixes]）；首段只有一个字母的（`d.path`、`e.id`）一律放过。
  /// 2. 末段不是纯字母、或末段不在 [_knownTlds] 且整串不足三段的 —— 挡掉
  ///    版本号（`1.0.6`、`3.44.1`）与 `state.ipInfo` 这类代码串。
  /// 3. 已经打过掩的（`*` 不在字符类里，`a.***.b` 天然不会被再匹配）。
  ///
  /// 注：Dart VM 不支持后顾 `(?<!)`，边界一律用捕获组（与本文件既有写法一致）。
  static const Set<String> _wordSuffixes = {
    // 文件名 / 资源后缀
    'dart', 'json', 'yaml', 'yml', 'txt', 'log', 'csv', 'md', 'xml', 'html',
    'htm', 'js', 'ts', 'py', 'sh', 'so', 'ipa', 'apk', 'arb', 'png', 'jpg',
    'jpeg', 'gif', 'webp', 'zip', 'gz', 'bin', 'db', 'conf', 'ini', 'lock',
    'tpl', 'tmpl', 'patch', 'diff',
    // 成员访问 / 代码里常见的「.xxx」
    'path', 'trim', 'first', 'last', 'length', 'value', 'host', 'port',
    'name', 'data', 'list', 'text', 'code', 'type', 'time', 'date', 'keys',
    'index', 'count', 'size', 'url', 'uri', 'msg', 'message', 'error', 'err',
    'state', 'result', 'query', 'group', 'item', 'self', 'this', 'args',
    'line', 'lines', 'file', 'dir', 'body', 'head', 'header', 'headers',
    'status', 'config', 'env', 'user', 'users', 'token', 'secret',
    'src', 'dst', 'dest', 'target', 'server', 'client', 'proxy', 'proxies',
    'node', 'id', 'uid', 'sid', 'min', 'max', 'total', 'num', 'ok', 'res',
    'req', 'resp', 'out', 'key', 'hash', 'sig', 'ver', 'build', 'model',
  };

  /// 允许「两段式」域名被打掩的顶级域（三段及以上只要末段是 2~6 个字母即可）
  static const Set<String> _knownTlds = {
    'com',
    'cn',
    'net',
    'org',
    'xyz',
    'cc',
    'top',
    'icu',
    'vip',
    'club',
    'shop',
    'site',
    'online',
    'tech',
    'info',
    'me',
    'io',
    'co',
    'dev',
    'app',
    'cloud',
    'link',
    'space',
    'store',
    'live',
    'run',
    'zone',
    'art',
    'blog',
    'fun',
    'lol',
    'wiki',
    'pro',
    'mobi',
    'asia',
    'email',
    'fyi',
    'game',
    'host',
    'pw',
    'work',
    'chat',
    'fan',
    'fit',
    'cafe',
    'plus',
    'one',
    'ai',
    'tv',
    'gg',
    'sh',
    'ly',
    'fm',
    'am',
    'to',
    'im',
    'je',
    'ki',
    'ms',
    'nu',
    'tl',
    'vu',
    'ws',
    'yt',
    'ac',
    'eu',
    'as',
    'hk',
    'jp',
    'sg',
    'kr',
    'tw',
    'de',
    'fr',
    'ru',
    'ua',
    'kz',
    'vn',
    'th',
    'id',
    'in',
    'br',
    'mx',
    'za',
    'tr',
    'sa',
    'ae',
    'il',
    'pl',
    'nl',
    'it',
    'es',
    'uk',
    'us',
    'ca',
    'au',
    'nz',
    'ar',
    'at',
    'be',
    'bg',
    'by',
    'ch',
    'cl',
    'cz',
    'dk',
    'ee',
    'eg',
    'fi',
    'gr',
    'hr',
    'hu',
    'ie',
    'is',
    'li',
    'lt',
    'lu',
    'lv',
    'ma',
    'md',
    'mk',
    'mt',
    'my',
    'no',
    'pe',
    'pt',
    'ro',
    'rs',
    'se',
    'si',
    'sk',
    'sy',
    'tj',
    'tm',
    'tn',
    'tt',
    'uy',
    'uz',
    've',
    'vg',
    'gov',
    'edu',
  };

  static final RegExp _hostLikeReg = RegExp(
    r'(^|[^0-9A-Za-z_.\-])([A-Za-z0-9][A-Za-z0-9\-]*(?:\.[A-Za-z0-9\-]+){1,})'
    r'(?![0-9A-Za-z\-])',
    caseSensitive: false,
  );
  static final RegExp _lettersOnlyReg = RegExp(r'^[A-Za-z]+$');
  static final RegExp _hasLetterReg = RegExp(r'[A-Za-z]');

  static String maskHostnames(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_hostLikeReg, (m) {
      final token = m.group(2)!;
      if (!_hasLetterReg.hasMatch(token)) return m[0]!;
      final labels = token.split('.');
      final first = labels.first;
      final last = labels.last.toLowerCase();
      if (first.length < 2) return m[0]!;
      if (last.length < 2 || !_lettersOnlyReg.hasMatch(last)) return m[0]!;
      if (_wordSuffixes.contains(last)) return m[0]!;
      final known = _knownTlds.contains(last);
      if (!known && (labels.length < 3 || last.length > 6)) return m[0]!;
      return '${m[1]}${_maskDomain(token.toLowerCase())}';
    });
  }

  /// 设备容器 UUID（`/var/mobile/Containers/Shared/AppGroup/<UUID>`、
  /// `…/Data/Application/<UUID>`）：不含密钥，但足以标识某一次安装，
  /// 日志能导出给用户之后一并打掩（2026-10-26）。
  static final RegExp _uuidReg = RegExp(
    r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'
    r'[0-9A-Fa-f]{12}',
  );

  static String maskDeviceIds(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_uuidReg, (_) => '***');
  }

  /// 域名掩码：**按实际段数**打码，不凭空补一段。
  ///
  /// 2026-11-19 业主口径：`server` 本来就是两段/三段/多段域名，打码要保留原段数：
  /// - `npc-b.cloud`（两段）→ `***.cloud`
  /// - `a.b.cloud`（三段）→ `a.***.cloud`
  /// - `a.b.c.cloud`（四段）→ `a.***.***.cloud`
  ///
  /// 以前把两段式补成 `npc-b.***.cloud`，看起来像三段，业主明确要求改掉。
  static String _maskDomain(String domain) {
    final parts = domain.split('.').where((e) => e.isNotEmpty).toList();
    if (parts.length <= 1) return '***';
    if (parts.length == 2) return '***.${parts.last}';
    return [
      parts.first,
      ...List.filled(parts.length - 2, '***'),
      parts.last,
    ].join('.');
  }

  /// 邮箱：用户名只留前两位、域名只留顶级域（`ab***@***.com`）。日志一旦能导出给
  /// 用户/运维看，邮箱就是明确的个人信息；而面板的报错文案里常带邮箱，所以这条
  /// 必须排在最前面（后面的通用主机名规则会把 `a@gmail.com` 改成 `a.gmail.***.com`
  /// 之类的形状，邮箱规则就匹配不到了）。
  static final RegExp _emailReg = RegExp(
    r'([A-Za-z0-9._%+\-][A-Za-z0-9._%+\-]*)@([A-Za-z0-9.\-]+\.[A-Za-z]{2,})',
  );

  static String maskEmails(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_emailReg, (m) {
      final local = m.group(1)!;
      final tld = m.group(2)!.toLowerCase().split('.').last;
      final head = local.length <= 2 ? local : local.substring(0, 2);
      return '$head***@***.$tld';
    });
  }

  /// 是否启用脱敏。**默认开**：普通用户的屏幕日志、导出、发给我们的诊断包一律脱敏。
  /// 唯一的关闭入口是开发者模式的「调试明文」开关（[setMaskEnabled]）——
  /// 关掉时屏幕与上传的诊断包一起变明文，口径一致。（iOS 端该开关由
  /// `common/log_mask_mode.dart` 落地、内核/扩展侧读 App Group 同名开关；桌面端
  /// 暂无对应设置页入口，保留同名开关与默认值以保证掩码口径两端一致。）
  static bool maskEnabled = true;

  /// 仅 Tarn 协议配置参与打码：切到 anytls 等其他协议时整体关闭，
  /// 避免把普通订阅的节点/域名也掩掉。
  static bool maskScopeEnabled = false;

  static void setMaskScopeEnabled(bool enabled) {
    maskScopeEnabled = enabled;
    if (!enabled) {
      update(const []);
      updateApiBases(const []);
    }
  }

  static bool get _active => enabled && maskEnabled && maskScopeEnabled;

  /// 切换脱敏（开发者模式「调试明文」= setMaskEnabled(false)）。
  static void setMaskEnabled(bool enabled) {
    maskEnabled = enabled;
  }

  /// 已打码 host 后面的端口：`156.238.***.***:18181` → `:...:***`、
  /// `***.cloud:28001` → `***.cloud:***`。
  ///
  /// 业主口径是「域名、IP、端口、API 路径都要打码」；只掩 host 会把端口留出来。
  static final RegExp _maskedHostPortReg = RegExp(
    r'(\d{1,3}\.\d{1,3}\.\*{3}\.\*{3}|\[v6:\*{3}\]|v6:\*{3}|\*{3}(?:\.[A-Za-z0-9*-]+)*):\d{1,5}(?!\d)',
  );

  /// 协议字样（Tarn / 品牌 slug）：业主口径是日志里不要出现自研协议名，
  /// 避免被检索后针对性识别。统一替换成 `***`（`[LFEXP] padding` → `[***] padding`）。
  ///
  /// 品牌 slug 取自生成常量（只含本站点）：写死多个品牌 slug 会把
  /// 另一品牌的标识带进本品牌的二进制。
  static final RegExp _protocolWordReg = RegExp(
    r'\b(lfexp|lfe|' + genSiteNameEn + r')\b',
    caseSensitive: false,
  );

  static String maskProtocolWords(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_protocolWordReg, (_) => '***');
  }

  static String maskMaskedPorts(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    return text.replaceAllMapped(_maskedHostPortReg, (m) => '${m[1]}:***');
  }

  /// 统一日志脱敏入口（2026-11-19 业主口径）。
  ///
  /// 顺序：邮箱 → 查询参数 → API 路径 → API base（OSS 地址）→ 订阅里提取的
  /// targets（节点 server / nameserver / CIDR）→ 配置字段（server / type /
  /// IP-CIDR）→ 设备 UUID。
  ///
  /// **不再全量打码**：以前会把日志里所有像主机名的串、所有 IP、所有端口都掩掉，
  /// 连用户自己访问的站点也看不出来。现在只掩配置文件里写死的东西。
  static String maskAll(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    // 调试明文模式下原样返回（改一处，日志页 / CommonPrint / 连接与请求列表 / 诊断包
    // 四个出口一起跟着走，不会出现"屏幕明文、上传掩码"这种分裂口径）。
    if (!_active) return text;
    var out = maskEmails(text);
    out = maskQueryParams(out);
    out = maskPaths(out);
    out = maskApiBase(out);
    out = maskTargets(out);
    out = maskConfigFields(out);
    out = maskDeviceIds(out);
    out = maskProtocolWords(out);
    out = maskMaskedPorts(out);
    return out;
  }

  /// 订阅里提取的入口（server / host:port / nameserver / CIDR）按 targets 打码。
  static String maskTargets(String? text) {
    if (text == null || text.isEmpty || _targets.isEmpty) return text ?? '';
    var out = text;
    final sorted = _targets.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final target in sorted) {
      out = out.replaceAll(target, _maskTargetValue(target));
      final lower = target.toLowerCase();
      if (lower != target) {
        out = out.replaceAll(lower, _maskTargetValue(lower));
      }
    }
    return out;
  }

  /// 配置文件里的敏感字段：`server:` / `proxy-server-nameserver:` / `type:`，
  /// 以及 `IP-CIDR,1.2.3.4/32,DIRECT,no-resolve` 这类规则里的网段。
  static final RegExp _configHostFieldReg = RegExp(
    r'((?:server|proxy-server-nameserver)\s*:\s*)([^\s,}\]]+)',
    caseSensitive: false,
  );

  static final RegExp _configTypeFieldReg = RegExp(
    r'(type\s*:\s*)([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  );

  static String maskConfigFields(String? text) {
    if (text == null || text.isEmpty) return text ?? '';
    var out = text.replaceAllMapped(
      _configHostFieldReg,
      (m) => '${m[1]}${_maskHostText(m.group(2)!)}',
    );
    out = out.replaceAllMapped(_configTypeFieldReg, (m) => '${m[1]}***');
    out = out.replaceAllMapped(
      _ipCidrReg,
      (m) => '${_maskIp(m.group(1)!)}/${m.group(2)}',
    );
    return out;
  }

  static String _maskHostText(String value) {
    final cleaned = value.replaceAll(RegExp(r'''^['"]+|['"]+$'''), '');
    if (cleaned.isEmpty) return '***';
    final host = Uri.tryParse('//$cleaned')?.host;
    if (host == null || host.isEmpty) return _maskHost(cleaned);
    return _maskHost(host);
  }
}
