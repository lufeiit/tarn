import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:rust_api/link.dart';

import 'constant.dart';
import 'print.dart';
import 'protocol.dart';
import 'string.dart';

String? profileUrlFromQrCodes(Iterable<String?> values) {
  for (final value in values) {
    final text = value?.trim();
    if (text == null || text.isEmpty) {
      continue;
    }
    if (text.isUrl || text.isShareLink) {
      return text;
    }
    final uri = Uri.tryParse(text);
    if (uri == null) {
      continue;
    }
    final url = _installConfigUrl(uri);
    if (url != null && url.isUrl) {
      return url;
    }
  }
  return null;
}

String? _installConfigUrl(Uri uri) {
  final url = installConfigTarget(uri)?.url;
  return url == null || url.isEmpty ? null : url;
}

/// 配置码（`clash://install-config?url=...&name=...&key=...`）的解析结果。
///
/// Karing 的约定里 `isp-name` / `isp-url` / `isp-faq` 只用于展示，这里不取；
/// `key` 是面板生成码时可选附加的用户派生密钥（有它就能解加密订阅）。
({
  String url,
  String? code,
  String? name,
  String? key,
  String? provider,
  String? home,
  String? faq,
  String? cs,
  String? logo,
  String? notice,
  String? theme,
  String? base,
  String? config,
  String? hide,
})?
installConfigTarget(Uri uri) {
  if (uri.host != 'install-config' ||
      !(protocolSchemes.contains(uri.scheme) ||
          uri.scheme == 'karing' ||
          uri.scheme == 'flowarc')) {
    return null;
  }
  final url = uri.queryParameters['url']?.trim() ?? '';
  final code = uri.queryParameters['code']?.trim();
  if (!url.isUrl && (code == null || code.isEmpty)) {
    return null;
  }
  String? field(String name) {
    final value = uri.queryParameters[name]?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  return (
    url: url,
    code: code == null || code.isEmpty ? null : code,
    name: field('name'),
    key: field('key'),
    provider: field('provider'),
    home: field('home'),
    faq: field('faq'),
    cs: field('cs'),
    logo: field('logo'),
    notice: field('notice'),
    theme: field('theme'),
    base: field('base'),
    config: field('config'),
    hide: field('hide'),
  );
}

const _linkChannel = MethodChannel('$packageName/link');

/// Native mobile delegates hold links until `takeLinks`, then push new links.
@visibleForTesting
Stream<Uri> mobileLinks([MethodChannel channel = _linkChannel]) {
  late final StreamController<Uri> controller;
  void add(Object? link) {
    final uri = link is String ? Uri.tryParse(link) : null;
    if (uri != null) {
      controller.add(uri);
    }
  }

  controller = StreamController<Uri>(
    onListen: () async {
      channel.setMethodCallHandler((call) async {
        if (call.method != 'link') {
          throw MissingPluginException();
        }
        add(call.arguments);
      });
      final pending = await channel.invokeListMethod<String>('takeLinks');
      pending?.forEach(add);
    },
    onCancel: () {
      channel.setMethodCallHandler(null);
      return controller.close();
    },
  );
  return controller.stream;
}

class LinkManager {
  static LinkManager? _instance;
  StreamSubscription? subscription;

  LinkManager._internal();

  @visibleForTesting
  Stream<Uri> Function() uriLinkStream = () =>
      Platform.isAndroid || Platform.isIOS ? mobileLinks() : desktopLinks();

  Future<void> initAppLinksListen(
    Function(Uri uri) installConfigCallBack,
  ) async {
    destroy();
    subscription = uriLinkStream().listen((uri) {
      _handle(uri, installConfigCallBack);
    });
  }

  void _handle(Uri uri, Function(Uri uri) installConfigCallBack) {
    commonPrint.log('onAppLink: ${uri.scheme}://${uri.host}');
    if (installConfigTarget(uri) != null) {
      installConfigCallBack(uri);
    }
  }

  void destroy() {
    if (subscription != null) {
      subscription?.cancel();
      subscription = null;
    }
  }

  factory LinkManager() {
    _instance ??= LinkManager._internal();
    return _instance!;
  }
}

final linkManager = LinkManager();
