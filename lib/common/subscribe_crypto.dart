import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;

import 'package:tarn/enum/enum.dart';

import 'print.dart';

/// 面板订阅加密（v2board `SubscribeEncryptService`）的客户端实现。
///
/// 面板侧的约定：
///   - 请求带 `X-IV`（32 个 hex 字符，取前 16 字节做 CBC IV）；
///   - 响应头 `X-Encrypted: 1` 表示 body 是密文；
///   - `X-Content-Sha` 是**明文** sha256 hex 的前 16 个字符；
///   - 可能在加密前先 gzip，并回 `X-Content-Encoding: gzip`。
///
/// 密钥 = HMAC-SHA256(站点密钥, 用户 uuid)，64 位 hex；AES 只取前 32 个字符。
class SubscribeCrypto {
  SubscribeCrypto._();

  static String generateIv() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  static bool isEncrypted(Map<String, List<String>> headers) {
    return headers['x-encrypted']?.contains('1') ?? false;
  }

  /// 解密失败时带原因，避免把密文当明文存下来（那种形态表现为「下载成功但没有节点」）。
  static ({String? plain, String reason}) decryptDetailed({
    required Uint8List ciphertext,
    required String iv,
    required String key,
    String? expectedSha,
  }) {
    if (key.isEmpty) {
      return (plain: null, reason: '订阅密钥为空');
    }
    Uint8List raw;
    try {
      raw = Uint8List.fromList(base64.decode(utf8.decode(ciphertext).trim()));
    } catch (_) {
      return (plain: null, reason: '密文不是合法 base64');
    }
    if (raw.length < 32) {
      return (plain: null, reason: '密文过短（${raw.length} 字节）');
    }
    final keyBytes = utf8.encode(key);
    final ivBytes = utf8.encode(iv);
    if (ivBytes.length < 16) {
      return (plain: null, reason: 'IV 长度不足（${ivBytes.length} 字节）');
    }
    final aesKey = Uint8List.fromList(
      keyBytes.sublist(0, keyBytes.length >= 32 ? 32 : 16),
    );
    final aesIv = Uint8List.fromList(ivBytes.sublist(0, 16));
    try {
      final encrypter = enc.Encrypter(
        enc.AES(enc.Key(aesKey), mode: enc.AESMode.cbc),
      );
      final plainBytes = encrypter.decryptBytes(
        enc.Encrypted(raw),
        iv: enc.IV(aesIv),
      );
      final shaHex = sha256.convert(plainBytes).toString();
      final want = (expectedSha ?? '').trim();
      if (want.isNotEmpty && want != '-') {
        if (shaHex.substring(0, 16) != want) {
          return (plain: null, reason: 'sha 校验不过（密钥或 IV 不一致）');
        }
      }
      var body = plainBytes;
      if (body.length > 2 && body[0] == 0x1f && body[1] == 0x8b) {
        body = gzip.decode(body);
      }
      return (plain: utf8.decode(body), reason: 'ok');
    } catch (error) {
      commonPrint.log(
        '[subscribe] 解密失败：$error',
        logLevel: LogLevel.warning,
      );
      return (plain: null, reason: 'AES-CBC 解密异常');
    }
  }
}
