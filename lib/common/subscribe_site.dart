import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'common.dart';

/// 加密订阅的站点侧信息：密钥、UA、用户 uuid 的获取与缓存。
///
/// 面板的加密密钥是 `HMAC-SHA256(站点密钥, 用户 uuid)`：
///   - 站点密钥是站点级常量（`v2board.subscribe_encrypt_key`）；
///   - 用户 uuid 在**明文订阅**的节点凭据里（v2board 用 uuid 生成 ss/vmess/
///     vless/lfexp 的凭据），所以客户端可以先拉一次明文拿到 uuid，再派生密钥
///     去解加密订阅，全程不需要用户输入。
///
/// 站点密钥按域名后缀匹配。公共构建可以留空（此时不会主动要求加密订阅，
/// 面板按 UA 回什么就存什么）；品牌构建在 [sites] 里加自己站点的一行即可。
class SubscribeSite {
  const SubscribeSite({
    required this.hostSuffix,
    required this.key,
    required this.userAgent,
  });

  final String hostSuffix;
  final String key;
  final String userAgent;

  /// 默认不内置任何站点密钥：多站点各不相同，硬编码会跟着发版。
  /// 需要加密订阅时由面板在配置码里带 `key=`（用户级派生密钥），客户端读到即用。
  /// 品牌构建若确实要内置，按下面格式加一行即可（不建议对生产站点这么做）。
  static const sites = <SubscribeSite>[];

  /// 按 host 后缀匹配；没有匹配返回 null（走普通 UA，不参与加密）。
  static SubscribeSite? forUrl(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) {
      return null;
    }
    for (final site in sites) {
      if (host == site.hostSuffix || host.endsWith('.${site.hostSuffix}')) {
        return site;
      }
    }
    return null;
  }

  /// 配置码里显式带的用户密钥（`...&key=<HMAC>`），优先于站点表 + uuid。
  static String? keyFromUrl(String url) {
    final key = Uri.tryParse(url)?.queryParameters['key']?.trim();
    return key == null || key.isEmpty ? null : key;
  }

  static Map<String, String>? _keyCache;

  static Future<File> _keyCacheFile() async {
    final dir = await appPath.homeDirPath;
    return File('$dir/subscribe_keys.json');
  }

  static Future<String?> cachedSiteKey(String url) async {
    _keyCache ??= await _readMap(_keyCacheFile());
    return _keyCache![url];
  }

  static Future<void> saveSiteKey(String url, String key) async {
    _keyCache ??= await _readMap(_keyCacheFile());
    if (_keyCache![url] == key) {
      return;
    }
    _keyCache![url] = key;
    try {
      await (await _keyCacheFile()).safeWriteAsString(jsonEncode(_keyCache));
    } catch (_) {}
  }

  /// 面板派生密钥：HMAC-SHA256(站点密钥, uuid)，hex 输出。
  String deriveKey(String uuid) {
    return Hmac(sha256, utf8.encode(key)).convert(utf8.encode(uuid)).toString();
  }

  /// 从明文订阅里取用户 uuid。
  ///
  /// v2board 的节点凭据就是用户 uuid：ss 的 `password`、vmess/vless 的
  /// `uuid`、lfexp 的 `uuid` 都是同一个 32 位 hex（老库是带连字符的 36 位）。
  static String? extractUuid(String plain) {
    final match = RegExp(
      r"(?:^|[\s,{])(?:uuid|password):\s*'?([0-9a-fA-F]{8}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{4}-?[0-9a-fA-F]{12})'?",
      multiLine: true,
    ).firstMatch(plain);
    final value = match?.group(1);
    if (value == null) {
      return null;
    }
    return value.replaceAll('-', '').toLowerCase();
  }

  // ── uuid 缓存（按订阅 URL）───────────────────────────────────────────────
  // 缓存只用于少跑一次明文探针；丢了也不影响正确性。

  static Map<String, String>? _cache;

  static Future<File> _cacheFile() async {
    final dir = await appPath.homeDirPath;
    return File('$dir/subscribe_uuids.json');
  }

  static Future<String?> cachedUuid(String url) async {
    _cache ??= await _readCache();
    return _cache![url];
  }

  static Future<void> saveUuid(String url, String uuid) async {
    _cache ??= await _readCache();
    if (_cache![url] == uuid) {
      return;
    }
    _cache![url] = uuid;
    try {
      final file = await _cacheFile();
      await file.safeWriteAsString(jsonEncode(_cache));
    } catch (_) {
      // 缓存写失败只是多一次探针，不影响订阅本身。
    }
  }

  static Future<Map<String, String>> _readCache() => _readMap(_cacheFile());

  static Future<Map<String, String>> _readMap(Future<File> fileFuture) async {
    try {
      final file = await fileFuture;
      if (!await file.exists()) {
        return {};
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', '$value'));
      }
    } catch (_) {}
    return {};
  }
}
