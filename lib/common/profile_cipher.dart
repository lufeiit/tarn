import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart';

import 'package:tarn/enum/enum.dart';

import 'common.dart';

/// 订阅配置的内容信封：磁盘上只留 AES-256-GCM 密文，App 解密后交给内核。
///
/// 布局与桌面端 `ProfileContentCipher` 同构（magic `LFPROF2!`），因此两端数据
/// 目录里的配置可以互相识别：
///
///   magic(8) | nonce(12) | ciphertext | tag(16)
///
/// 密钥 = `sha256('lfexp-data-v2|lfexp-profile-<id>-content-v2|' + installKey)`，
/// installKey 是设备级随机密钥，不进 App Group，扩展进程拿不到——内核改为经
/// `profile.base` / `config.setup` 的 content 字段拿明文。
class ProfileContentCipher {
  ProfileContentCipher._();

  static const _magic = [0x4c, 0x46, 0x50, 0x52, 0x4f, 0x46, 0x32, 0x21];
  static const _nonceLength = 12;
  static const _tagLength = 16;
  static final _algorithm = AesGcm.with256bits();

  static Future<bool> isEncrypted(File file) async {
    if (!await file.exists() ||
        await file.length() < _magic.length + _nonceLength + _tagLength) {
      return false;
    }
    final header = await _readRange(file, 0, _magic.length);
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i]) return false;
    }
    return true;
  }

  /// 把 [source] 的明文加密到 [target]（同目录临时文件 + rename，原子替换）。
  static Future<void> encryptFile(
    File source,
    File target,
    int profileId,
  ) async {
    final key = SecretKey(
      await _deriveKey('lfexp-profile-$profileId-content-v2'),
    );
    final nonce = _algorithm.newNonce();
    final temp = File('${target.path}.enc-tmp');
    await temp.parent.create(recursive: true);
    final sink = temp.openWrite();
    List<int>? tag;
    try {
      sink.add([..._magic, ...nonce]);
      await sink.addStream(
        _algorithm.encryptStream(
          source.openRead(),
          secretKey: key,
          nonce: nonce,
          aad: _magic,
          onMac: (mac) => tag = mac.bytes,
        ),
      );
      sink.add(tag!);
      await sink.flush();
      await sink.close();
      await temp.rename(target.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      await _safeDelete(temp);
      rethrow;
    }
  }

  /// 就地加密：成功才替换 [file]，失败保留明文并返回 false。
  static Future<bool> encryptInPlace(File file, int profileId) async {
    final temp = File('${file.path}.enc');
    try {
      await encryptFile(file, temp, profileId);
      await temp.rename(file.path);
      return true;
    } catch (error) {
      await _safeDelete(temp);
      commonPrint.log(
        '[profile-cipher] 内容加密失败，保留明文: $error',
        logLevel: LogLevel.warning,
      );
      return false;
    }
  }

  /// 解密 [source] 到 [target]；信封不认识或校验失败返回 false。
  static Future<bool> decryptFile(
    File source,
    File target,
    int profileId,
  ) async {
    final length = await source.length();
    final headerLength = _magic.length + _nonceLength;
    if (length < headerLength + _tagLength) return false;
    final header = await _readRange(source, 0, headerLength);
    for (var i = 0; i < _magic.length; i++) {
      if (header[i] != _magic[i]) return false;
    }
    final nonce = header.sublist(_magic.length);
    final tag = await _readRange(source, length - _tagLength, length);
    final key = SecretKey(
      await _deriveKey('lfexp-profile-$profileId-content-v2'),
    );
    final temp = File('${target.path}.dec-tmp');
    await temp.parent.create(recursive: true);
    final sink = temp.openWrite();
    try {
      await sink.addStream(
        _algorithm.decryptStream(
          source.openRead(headerLength, length - _tagLength),
          secretKey: key,
          nonce: nonce,
          mac: Mac(tag),
          aad: _magic,
        ),
      );
      await sink.flush();
      await sink.close();
      await temp.rename(target.path);
      return true;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      await _safeDelete(temp);
      return false;
    }
  }

  /// 读成明文字符串：加密文件解密，明文文件直接读。
  static Future<String?> readPlaintext(File file, int profileId) async {
    if (!await isEncrypted(file)) {
      if (!await file.exists()) return null;
      return file.readAsString();
    }
    try {
      final bytes = await file.readAsBytes();
      final start = _magic.length + _nonceLength;
      final end = bytes.length - _tagLength;
      if (end < start ||
          !_magic.asMap().entries.every(
            (entry) => bytes[entry.key] == entry.value,
          )) {
        return null;
      }
      final plaintext = await _algorithm.decrypt(
        SecretBox(
          Uint8List.sublistView(bytes, start, end),
          nonce: Uint8List.sublistView(bytes, _magic.length, start),
          mac: Mac(Uint8List.sublistView(bytes, end)),
        ),
        secretKey: SecretKey(
          await _deriveKey('lfexp-profile-$profileId-content-v2'),
        ),
        aad: _magic,
      );
      return utf8.decode(plaintext);
    } catch (_) {
      commonPrint.log(
        '[profile-cipher] 解密失败 id=$profileId',
        logLevel: LogLevel.warning,
      );
      return null;
    }
  }

  static Future<Uint8List> _deriveKey(String purpose) async {
    final installKey = await _installKey();
    return Uint8List.fromList(
      crypto.sha256.convert([
        ...utf8.encode('lfexp-data-v2|$purpose|'),
        ...installKey,
      ]).bytes,
    );
  }

  /// 设备级安装密钥：App 容器内 0600 文件，首次启动随机生成。
  ///
  /// 不使用 App Group：Network Extension 不需要它（内核拿的是 App 解密后的
  /// content），放在这里可让家里有钥匙的人变成"只有 App 进程有钥匙"。
  static Uint8List? _cachedKey;
  static Future<Uint8List> _installKey() async {
    final cached = _cachedKey;
    if (cached != null) return cached;
    final home = await appPath.homeDirPath;
    final file = File(join(home, '.lfexp-install-key'));
    if (await file.exists()) {
      try {
        final raw = base64Decode((await file.readAsString()).trim());
        if (raw.length == 32) {
          _cachedKey = Uint8List.fromList(raw);
          return _cachedKey!;
        }
      } catch (_) {}
    }
    final random = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => random.nextInt(256)),
    );
    await file.parent.create(recursive: true);
    await file.writeAsString(base64Encode(key));
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', ['600', file.path]);
      } catch (_) {}
    }
    _cachedKey = key;
    return key;
  }

  static Future<List<int>> _readRange(File file, int start, int end) async {
    final builder = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
