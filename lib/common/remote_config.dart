import 'dart:convert';
import 'dart:io';

import 'common.dart';

/// 远程 config.json：服务商在不发版的前提下调整客户端行为与文案。
///
/// 码里带 `config=<url>` 时生效；结构：
///   { "flags": { "providerCard": true }, "texts": { "notice": "..." } }
/// 本地缓存一份，启动时先用缓存（同步可见），后台再刷新。
class RemoteConfig {
  RemoteConfig._();

  static Map<String, dynamic>? _flags;
  static Map<String, dynamic>? _texts;
  static String? _sourceUrl;
  static bool _loaded = false;

  static Future<File> _file() async {
    final dir = await appPath.homeDirPath;
    return File('$dir/remote_config.json');
  }

  /// 启动时调用：把缓存读进内存，保证 UI 首帧就能拿到 flag。
  static Future<void> loadCached() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      _apply(Map<String, dynamic>.from(raw));
    } catch (_) {}
  }

  /// 后台刷新：失败静默，保留旧缓存。
  static Future<void> refresh(String url) async {
    if (url.isEmpty) return;
    try {
      final response = await request.getTextResponseForUrl(url);
      final raw = jsonDecode(response.data ?? '');
      if (raw is! Map) return;
      final data = Map<String, dynamic>.from(raw);
      _apply(data);
      _sourceUrl = url;
      final file = await _file();
      await file.safeWriteAsString(
        jsonEncode({...data, 'source': url, 'fetched-at': DateTime.now().millisecondsSinceEpoch}),
      );
    } catch (_) {}
  }

  static void _apply(Map<String, dynamic> data) {
    final flags = data['flags'];
    if (flags is Map) {
      _flags = Map<String, dynamic>.from(flags);
    }
    final texts = data['texts'];
    if (texts is Map) {
      _texts = Map<String, dynamic>.from(texts);
    }
  }

  static bool flag(String name, {bool fallback = true}) {
    final value = _flags?[name];
    return value is bool ? value : fallback;
  }

  static String? text(String name) {
    final value = _texts?[name];
    return value is String && value.isNotEmpty ? value : null;
  }

  static String? get sourceUrl => _sourceUrl;
}