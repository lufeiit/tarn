import 'dart:convert';
import 'dart:io';

import 'common.dart';
import 'request.dart';

/// 服务商（provider）档案：品牌与入口信息，全部来自配置码或远程 provider.json。
///
/// 与协议无关：订阅内容是什么协议都行，这里只描述「这是谁家的服务」。
class ProviderProfile {
  const ProviderProfile({
    required this.id,
    required this.name,
    this.logo,
    this.home,
    this.faq,
    this.customerService,
    this.notice,
    this.themeColor,
    this.baseUrl,
    this.configUrl,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final String? logo;
  final String? home;
  final String? faq;
  final String? customerService;
  final String? notice;
  final String? themeColor;

  /// 可选：远程 provider.json 地址，定期刷新档案（等价 Karing 的 base.json）。
  final String? baseUrl;

  /// 远程 config.json 地址（码里的 config=）。
  final String? configUrl;
  final int updatedAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (logo != null) 'logo': logo,
    if (home != null) 'home': home,
    if (faq != null) 'faq': faq,
    if (customerService != null) 'customer-service': customerService,
    if (notice != null) 'notice': notice,
    if (themeColor != null) 'theme-color': themeColor,
    if (baseUrl != null) 'base': baseUrl,
    if (configUrl != null) 'config': configUrl,
    'updated-at': updatedAt,
  };

  static ProviderProfile? fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty || name is! String || name.isEmpty) {
      return null;
    }
    String? str(String key) {
      final value = json[key];
      return value is String && value.isNotEmpty ? value : null;
    }

    return ProviderProfile(
      id: id,
      name: name,
      logo: str('logo'),
      home: str('home'),
      faq: str('faq'),
      customerService: str('customer-service') ?? str('cs'),
      notice: str('notice'),
      themeColor: str('theme-color') ?? str('theme'),
      baseUrl: str('base'),
      configUrl: str('config'),
      updatedAt: json['updated-at'] is int ? json['updated-at'] as int : 0,
    );
  }
}

class ProviderStore {
  ProviderStore._();

  static Map<String, ProviderProfile>? _cache;
  static String? _currentId;

  static Future<File> _file() async {
    final dir = await appPath.homeDirPath;
    return File('$dir/providers.json');
  }

  static Future<Map<String, ProviderProfile>> _load() async {
    if (_cache != null) {
      return _cache!;
    }
    final result = <String, ProviderProfile>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map) {
          final providers = raw['providers'];
          final source = providers is Map ? providers : raw;
          if (providers is Map && raw['current'] is String) {
            _currentId = raw['current'] as String;
          }
          for (final entry in source.entries) {
            final value = entry.value;
            if (value is Map) {
              final profile = ProviderProfile.fromJson(
                Map<String, dynamic>.from(value),
              );
              if (profile != null) {
                result[profile.id] = profile;
              }
            }
          }
        }
      }
    } catch (_) {}
    return _cache = result;
  }

  static Future<ProviderProfile?> get(String id) async {
    return (await _load())[id];
  }

  /// 当前生效的服务商：优先用户选定的，否则取最近更新的一个。
  static Future<ProviderProfile?> current() async {
    final all = await _load();
    if (all.isEmpty) {
      return null;
    }
    final id = _currentId;
    if (id != null && all[id] != null) {
      return all[id];
    }
    final list = all.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list.first;
  }

  static Future<List<ProviderProfile>> all() async {
    final list = (await _load()).values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  static Future<void> setCurrent(String id) async {
    final all = await _load();
    if (!all.containsKey(id)) return;
    _currentId = id;
    await _write(all);
  }

  static Future<void> remove(String id) async {
    final all = await _load();
    if (all.remove(id) == null) return;
    if (_currentId == id) {
      _currentId = null;
    }
    await _write(all);
  }

  /// 按 baseUrl 拉远程档案（等价 Karing 的 base.json），3 小时节流。
  /// 失败静默：品牌信息过期不影响订阅。
  static Future<ProviderProfile?> refreshIfNeeded(
    ProviderProfile profile,
  ) async {
    final base = profile.baseUrl;
    if (base == null || base.isEmpty) {
      return null;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - profile.updatedAt < const Duration(hours: 3).inMilliseconds) {
      return null;
    }
    try {
      final response = await request.getTextResponseForUrl(base);
      final raw = jsonDecode(response.data ?? '');
      if (raw is! Map) {
        return null;
      }
      final merged = <String, dynamic>{
        ...profile.toJson(),
        ...Map<String, dynamic>.from(raw),
        'id': profile.id,
        'updated-at': now,
      };
      final next = ProviderProfile.fromJson(merged);
      if (next == null) {
        return null;
      }
      await upsert(next);
      return next;
    } catch (_) {
      return null;
    }
  }

  static Future<void> upsert(ProviderProfile profile) async {
    final all = await _load();
    all[profile.id] = profile;
    await _write(all);
  }

  static Future<void> _write(Map<String, ProviderProfile> all) async {
    try {
      final file = await _file();
      await file.safeWriteAsString(
        jsonEncode({
          'current': _currentId,
          'providers': {
            for (final entry in all.entries) entry.key: entry.value.toJson(),
          },
        }),
      );
    } catch (_) {
      // 写失败只影响品牌展示，不影响订阅。
    }
  }
}