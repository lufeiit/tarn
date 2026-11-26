import 'dart:io';

import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/providers/config.dart';
import 'package:tarn/providers/state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class TarnHttpOverrides extends HttpOverrides {
  final ProviderContainer _container;

  TarnHttpOverrides(this._container);

  static String findProxyFor(ProviderContainer container, Uri url) {
    return findProxyForReader(container.read, url);
  }

  static String findProxyForReader(ProviderReader read, Uri url) {
    if ([localhost].contains(url.host)) {
      return 'DIRECT';
    }
    // iOS 的 TUN 已经接管 App 自身流量；扩展里的 mixed 端口不保证监听，
    // 再显式指过去会让 IP 质量、订阅刷新这类 App 请求全部失败（真机表现：
    // 出口 IP 有了，但「类型/组织」一直是未知）。交给 TUN 按规则走即可。
    if (system.isIOS) return 'DIRECT';
    final isStart = read(isStartProvider);
    final suspend = read(suspendProvider);
    if (!isStart || suspend) return 'DIRECT';
    final mixedPort = read(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    final authentication = read(
      networkSettingProvider.select((state) => state.authentication),
    );
    final credentials = authentication.credentials;
    final userInfo = credentials.isNotEmpty ? '${credentials.first}@' : '';
    return 'PROXY ${userInfo}localhost:$mixedPort';
  }

  static bool allowBadCertificate(
    ProviderContainer container,
    X509Certificate certificate,
    String host,
    int port,
  ) {
    return allowBadCertificateForReader(
      container.read,
      certificate,
      host,
      port,
    );
  }

  static bool allowBadCertificateForReader(
    ProviderReader read,
    X509Certificate certificate,
    String host,
    int port,
  ) {
    final checkCertificate = read(
      appSettingProvider.select((state) => state.checkCertificate),
    );
    commonPrint.log(
      'untrusted certificate for $host:$port issued by ${certificate.issuer}, '
      'check: $checkCertificate',
      logLevel: LogLevel.warning,
    );
    return !checkCertificate;
  }

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (certificate, host, port) =>
        allowBadCertificate(_container, certificate, host, port);
    client.findProxy = (url) => findProxyFor(_container, url);
    return client;
  }
}
