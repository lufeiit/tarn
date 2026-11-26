import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart' show DioException;

import 'package:tarn/enum/enum.dart';

import 'common.dart';

/// 两段码：`LF.<base64url(兑换地址)>.<用户码>`
///
/// 服务商段编码的是该面板的兑换地址（无中心目录），用户段是面板签发的用户码。
typedef AccessCodeResult = ({String url, String? key, String? name});

class AccessCodeException implements Exception {
  const AccessCodeException(this.message);

  final String message;

  factory AccessCodeException.fromResponse(Object? code, int? status) =>
      AccessCodeException(switch (code) {
        'device_limit' ||
        'device_quota_exceeded' ||
        'device_binding_limit' => '设备名额已满，请到服务商面板解绑一台设备后重试。',
        'device_name_not_allowed' => '此设备名称不在服务商允许列表中。',
        'device_id_required' => '服务商未能完成本次导入，请稍后重试或联系服务商。',
        'code_bound' => '配置码已绑定其他设备，请联系服务商。',
        'code_invalid' || 'user_not_found' => '配置码已失效，请重新获取。',
        _ when status == null => '无法连接服务商，请检查网络后重试。',
        _ => '服务商未能兑换配置码，请稍后重试。',
      });
}

class AccessCode {
  const AccessCode({required this.exchangeUrl, required this.userCode});

  final String exchangeUrl;
  final String userCode;

  /// 平台公钥（Ed25519，base64url）。服务商改插件也拿不到私钥，
  /// 客户端只接受平台签过名的码。
  static const platformPublicKey =
      'RAaMVpQEu4YPvhD_npwrjJWt3_1SPfIfhvKwto0Dg3M';

  static Future<AccessCode?> parseVerified(String raw) async {
    final text = raw.trim();
    final parts = text.split('.');
    // 旧的三段码没有签名，不再接受。
    if (parts.length != 4 || parts[0] != 'LF') {
      return null;
    }
    final message = '${parts[0]}.${parts[1]}.${parts[2]}';
    try {
      final publicKey = SimplePublicKey(
        base64Url.decode(base64Url.normalize(platformPublicKey)),
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        base64Url.decode(base64Url.normalize(parts[3])),
        publicKey: publicKey,
      );
      final ok = await Ed25519().verify(
        utf8.encode(message),
        signature: signature,
      );
      if (!ok) {
        commonPrint.log(
          '[access-code] 签名校验失败，拒绝导入',
          logLevel: LogLevel.warning,
        );
        return null;
      }
    } catch (error) {
      commonPrint.log('[access-code] 验签异常：$error', logLevel: LogLevel.warning);
      return null;
    }
    return _fromParts(parts);
  }

  static AccessCode? parse(String raw) {
    final text = raw.trim();
    final parts = text.split('.');
    if (parts.length != 3 || parts[0] != 'LF') {
      return null;
    }
    return _fromParts(parts);
  }

  static AccessCode? _fromParts(List<String> parts) {
    try {
      final url = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        return null;
      }
      if (parts[2].isEmpty) {
        return null;
      }
      return AccessCode(exchangeUrl: url, userCode: parts[2]);
    } catch (_) {
      return null;
    }
  }

  /// 兑换并返回订阅地址与可选密钥；失败返回 null。
  ///
  /// 只提交配置码本身：不在请求里附带任何终端信息，隐私清单因此可以声明
  /// 不收集任何数据。服务端按请求来源统计名额。
  Future<AccessCodeResult?> exchange() async {
    try {
      final response = await request.postJson<dynamic>(exchangeUrl, {
        'code': userCode,
      });
      final body = response.data;
      if (body is! Map) {
        return null;
      }
      final data = body['data'];
      if (data is! Map) {
        return null;
      }
      final url = data['url'];
      if (url is! String || url.isEmpty) {
        return null;
      }
      final key = data['key'];
      final name = data['name'];
      return (
        url: url,
        key: key is String && key.isNotEmpty ? key : null,
        name: name is String && name.isNotEmpty ? name : null,
      );
    } on DioException catch (error) {
      final body = error.response?.data;
      throw AccessCodeException.fromResponse(
        body is Map ? body['code'] : null,
        error.response?.statusCode,
      );
    } catch (_) {
      throw const AccessCodeException('无法读取设备信息，请重启 App 后重试。');
    }
  }
}
