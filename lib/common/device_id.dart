import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart' show LogLevel;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

// 安装级标识：device-id.json 记录派生来源，secret 落在应用支持目录。
// L1 = sha256('lfexp-device-v1|' + install id); L2 =
// sha256('lfexp-device-v2|' + install id + '|' + uppercase UUID secret)。
// 源是每次安装随机生成的值，不含任何硬件标识。

/// 随机安装 ID：不读任何硬件标识，重装即变，不跨 App、不跨设备。
///
/// 只用于连接自建节点时的在线会话去重与名额统计，不进入任何 HTTP 请求。
Future<String?> _hardwareId() async {
  try {
    final dir = await _deviceIdDataDir();
    final file = File(join(dir.path, 'install-id'));
    if (await file.exists()) {
      final value = (await file.readAsString()).trim();
      if (value.isNotEmpty) return 'install:$value';
    }
    final random = Random.secure();
    final value = base64UrlEncode(
      List<int>.generate(24, (_) => random.nextInt(256)),
    );
    await file.writeAsString(value);
    return 'install:$value';
  } catch (_) {
    return null;
  }
}

const deviceIdL1Derivation = 'lfexp-device-v1|';
const deviceIdL2Derivation = 'lfexp-device-v2|';
const deviceIdKeychainKey = 'lfexp_device_secret';
const String? deviceIdAccessGroup =
    null; // Main app only; Network Extension is not connected.
// 官方基座没有 flutter_secure_storage 依赖：诊断用的设备密钥改为应用支持目录下的
// 本地文件。该值只在连接自建节点时用于在线会话去重，不进入任何 HTTP 请求。
Future<Directory> _deviceIdDataDir() async => getApplicationSupportDirectory();

Future<String?> _readDeviceSecret() async {
  try {
    final dir = await _deviceIdDataDir();
    final file = File(join(dir.path, '.device_secret'));
    if (!await file.exists()) return null;
    return (await file.readAsString()).trim();
  } catch (_) {
    return null;
  }
}

Future<void> _writeDeviceSecret(String value) async {
  final dir = await _deviceIdDataDir();
  final file = File(join(dir.path, '.device_secret'));
  await file.writeAsString(value);
}

String _deviceIdForHardware(String hw) => sha256
    .convert(utf8.encode('$deviceIdL1Derivation$hw'))
    .toString()
    .substring(0, 32);

String _deviceIdForSecret(String hw, String secret) => sha256
    .convert(utf8.encode('$deviceIdL2Derivation$hw|$secret'))
    .toString()
    .substring(0, 32);

/// 面板代际迁移记账用：当前上报 ID 实际用的派生代际（v2 = 混了 Keychain 密钥，
/// v1 = 只有硬件源）。读不到密钥退回 v1 时如实报 v1，不硬写成 v2。
String _deviceIdSource = 'v1';

String deviceIdDerivationSource() => _deviceIdSource;

bool _isValidDeviceId(String value) =>
    RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

String _newDeviceSecret() {
  final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
}

Future<String?> _loadOrCreateDeviceSecret() async {
  try {
    final value = await _readDeviceSecret();
    if (value != null) {
      if (RegExp(
        r'^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$',
      ).hasMatch(value)) {
        return value;
      }
      commonPrint.log(
        'device id Keychain secret is malformed; use disk binding',
        logLevel: LogLevel.warning,
      );
      return null;
    }
    final created = _newDeviceSecret();
    await _writeDeviceSecret(created);
    return created;
  } catch (error) {
    commonPrint.log(
      'device id Keychain unavailable; use disk binding: $error',
      logLevel: LogLevel.warning,
    );
    return null;
  }
}

Future<String>? _deviceIdInFlight;

Future<String> getLocalDeviceId() => _deviceIdInFlight ??= _readLocalDeviceId()
    .whenComplete(() {
      _deviceIdInFlight = null;
    });

Future<String> _readLocalDeviceId() async {
  final dir = await _deviceIdDataDir();
  final bindingFile = File(join(dir.path, 'device-id.json'));
  final legacyFile = File(join(dir.path, 'device-id'));
  Map<String, dynamic>? binding;
  try {
    final raw = jsonDecode(await bindingFile.readAsString());
    if (raw is Map<String, dynamic> &&
        raw['v'] is int &&
        raw['hw'] is String &&
        raw['id'] is String &&
        _isValidDeviceId(raw['id'] as String)) {
      binding = raw;
    }
  } catch (_) {}

  // 老绑定没有 src/prev 两个字段 ⇒ 按 v1、无上一代处理（换代首拉时面板走兜底判据）
  final boundSrc = binding?['src'];
  _deviceIdSource = boundSrc is String && boundSrc.isNotEmpty ? boundSrc : 'v1';

  final hw = await _hardwareId();
  if (hw == null && binding != null) {
    commonPrint.log(
      'device id hardware source unavailable; reusing persisted binding',
      logLevel: LogLevel.warning,
    );
    return binding['id'] as String;
  }
  if (hw == null) {
    try {
      final legacy = (await legacyFile.readAsString()).trim();
      if (_isValidDeviceId(legacy)) {
        await _writeDeviceIdBinding(bindingFile, hw: 'unavailable', id: legacy);
        commonPrint.log(
          'device id hardware source unavailable; migrated legacy binding',
          logLevel: LogLevel.warning,
        );
        return legacy;
      }
    } catch (_) {}
  }

  final hardware = hw ?? 'unavailable';
  final oldHardware = binding?['hw'] as String?;
  var id = binding != null && oldHardware == hardware
      ? binding['id'] as String
      : '';
  if (hw != null) {
    final secret = system.isIOS ? await _loadOrCreateDeviceSecret() : null;
    if (secret != null) {
      id = _deviceIdForSecret(hw, secret);
      _deviceIdSource = 'v2';
    } else if (id.isEmpty) {
      id = _deviceIdForHardware(hw);
      _deviceIdSource = 'v1';
    }
  } else if (id.isEmpty) {
    final random = Random.secure();
    id = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }

  if (binding == null || oldHardware != hardware || binding['id'] != id) {
    // 换代前最后一次上报的 ID 记进 prev：面板据此精确挪席位（判据 A），不用靠设备名猜
    final oldId = (binding?['id'] as String?) ?? '';
    final hadPrev = (binding?['prev'] as String?) ?? '';
    await _writeDeviceIdBinding(
      bindingFile,
      hw: hardware,
      id: id,
      src: _deviceIdSource,
      prev: hadPrev.isNotEmpty ? hadPrev : oldId,
    );
  }
  return id;
}

/// 面板代际迁移判据 A 用：上一代（v1 口径）的设备 ID。
///
/// 优先取绑定里的 prev（换代前最后一次上报的 ID —— 硬件源换过也只有它对得上面板已绑的
/// key）；老绑定没 prev 时用持久化的 hw 现算 v1（换代时硬件源没变 ⇒ 与已绑 key 相同）。
/// 都没有 ⇒ 空串，让面板退回「系统同族 + 设备名唯一同名」的兜底判据（宁缺勿误迁）。
Future<String> getLegacyDeviceId() async {
  try {
    final dir = await _deviceIdDataDir();
    final raw = jsonDecode(
      await File(join(dir.path, 'device-id.json')).readAsString(),
    );
    if (raw is! Map) return '';
    final prev = raw['prev'];
    if (prev is String && _isValidDeviceId(prev)) return prev;
    final src = raw['src'];
    if (src is String && src == 'v2') return ''; // 没记下换代前的 ID ⇒ 不猜
    final hw = raw['hw'];
    if (hw is String &&
        hw.isNotEmpty &&
        hw != 'unavailable' &&
        raw['id'] is String) {
      final v1 = _deviceIdForHardware(hw);
      return v1 == raw['id'] ? '' : v1; // 当前仍是 v1 ⇒ 没有上一代要交
    }
  } catch (_) {}
  return '';
}

Future<void> _writeDeviceIdBinding(
  File file, {
  required String hw,
  required String id,
  String src = 'v1',
  String prev = '',
}) async {
  try {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      jsonEncode({'v': 2, 'hw': hw, 'id': id, 'src': src, 'prev': prev}),
      flush: true,
    );
    await tmp.rename(file.path);
  } catch (error) {
    commonPrint.log(
      'device id binding write failed: $error',
      logLevel: LogLevel.warning,
    );
  }
}

String getSystemDeviceName() {
  final os = Platform.operatingSystem;
  final ver = Platform.operatingSystemVersion;
  String pretty;
  switch (os) {
    case 'macos':
      pretty = 'macOS ${_extractVersion(ver)}';
    case 'windows':
      pretty = 'Windows ${_windowsVersion(ver)}';
    case 'linux':
      pretty = 'Linux ${_extractVersion(ver)}';
    case 'android':
      pretty = 'Android ${_extractVersion(ver)}';
    case 'ios':
      pretty = 'iOS ${_extractVersion(ver)}';
    default:
      pretty = os;
  }
  return pretty;
}

String _extractVersion(String v) {
  final m = RegExp(r'(\d+\.\d+(\.\d+)?)').firstMatch(v);
  return m?.group(1) ?? v;
}

String _windowsVersion(String v) {
  if (v.contains('10.0.22000') || v.contains('10.0.22631')) return '11';
  if (v.contains('10.0')) return '10';
  return _extractVersion(v);
}

// 本机持久化的设备名（幂等：已存在则复用；首次生成 = 系统名 版本）
Future<String> getLocalDeviceName() async {
  final dir = await _deviceIdDataDir();
  final f = File(join(dir.path, 'device-name'));
  try {
    if (await f.exists()) {
      final existing = (await f.readAsString()).trim();
      if (existing.isNotEmpty) return existing;
    }
  } catch (_) {}
  final name = getSystemDeviceName();
  try {
    await f.writeAsString(name);
  } catch (_) {}
  return name;
}
