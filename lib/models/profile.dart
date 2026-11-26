import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:yaml/yaml.dart';

import 'clash_config.dart';

part 'generated/profile.freezed.dart';
part 'generated/profile.g.dart';

/// Why the config at the path cannot be used, or null.
typedef ValidateConfig =
    Future<String?> Function(String path, String ageSecretKey);

@freezed
abstract class SubscriptionInfo with _$SubscriptionInfo {
  const factory SubscriptionInfo({
    @Default(0) int upload,
    @Default(0) int download,
    @Default(0) int total,
    @Default(0) int expire,
  }) = _SubscriptionInfo;

  factory SubscriptionInfo.fromJson(Map<String, Object?> json) =>
      _$SubscriptionInfoFromJson(json);

  factory SubscriptionInfo.formHString(String? info) {
    if (info == null) return const SubscriptionInfo();
    final Map<String, int> map = {};
    for (final field in info.split(';')) {
      final separator = field.indexOf('=');
      if (separator == -1) continue;
      final value = _parseCount(field.substring(separator + 1).trim());
      if (value != null) {
        map[field.substring(0, separator).trim().toLowerCase()] = value;
      }
    }
    return SubscriptionInfo(
      upload: map['upload'] ?? 0,
      download: map['download'] ?? 0,
      total: map['total'] ?? 0,
      expire: map['expire'] ?? 0,
    );
  }

  static int? _parseCount(String value) {
    final count = int.tryParse(value);
    if (count != null) return count;
    final decimal = double.tryParse(value);
    return decimal != null && decimal.isFinite ? decimal.truncate() : null;
  }
}

extension SubscriptionInfoExt on SubscriptionInfo {
  double? get usage =>
      total > 0 ? ((upload + download) / total).clamp(0.0, 1.0) : null;

  DateTime? get expireDate =>
      expire > 0 ? DateTime.fromMillisecondsSinceEpoch(expire * 1000) : null;
}

@freezed
abstract class Profile with _$Profile {
  const factory Profile({
    required int id,
    @Default(ProfileType.file) ProfileType type,
    @Default('') String label,
    String? currentGroupName,
    @Default('') String url,
    @Default('') String ageSecretKey,
    DateTime? lastUpdateDate,
    required Duration autoUpdateDuration,
    SubscriptionInfo? subscriptionInfo,
    @Default(false) bool autoUpdate,
    @Default({}) Map<String, String> selectedMap,
    @Default({}) Set<String> unfoldSet,
    int? scriptId,
    @Default({}) Map<String, String> exitTargets,
    int? order,
    @Default(ProfileOverrides())
    @JsonKey(fromJson: ProfileOverrides.safeFromJson)
    ProfileOverrides overrides,
  }) = _Profile;

  factory Profile.fromJson(Map<String, Object?> json) =>
      _$ProfileFromJson(json);

  factory Profile.normal({String? label, String url = ''}) {
    final id = snowflake.id;
    return Profile(
      type: url.isEmpty ? ProfileType.file : ProfileType.url,
      label: label ?? '',
      url: url,
      id: id,
      // 自动更新默认关闭（间隔仍按 24 小时保存）；用户需要时再手动打开。
      autoUpdate: false,
      autoUpdateDuration: defaultUpdateDuration,
    );
  }

  factory Profile.custom({String? label}) {
    return Profile(
      id: snowflake.id,
      type: ProfileType.custom,
      label: label ?? '',
      lastUpdateDate: DateTime.now(),
      autoUpdate: false,
      autoUpdateDuration: defaultUpdateDuration,
    );
  }
}

/// A profile leaving out one of the global rules its extension would add.
@freezed
abstract class DisabledRule with _$DisabledRule {
  const factory DisabledRule({required int profileId, required int ruleId}) =
      _DisabledRule;
}

extension ProfilesExt on List<Profile> {
  Profile? getProfile(int? profileId) {
    final index = indexWhere((profile) => profile.id == profileId);
    return index == -1 ? null : this[index];
  }

  Profile optimizeLabel(Profile profile) {
    return profile.copyWith(
      label: uniqueLabelFor(
        profile.label,
        fallback: profile.defaultLabel,
        taken: (label) =>
            any((item) => item.label == label && item.id != profile.id),
      ),
    );
  }
}

extension ProfileExtension on Profile {
  bool get realAutoUpdate => type == ProfileType.url && autoUpdate;

  String get realLabel => label.takeFirstValid([defaultLabel]);

  String get defaultLabel => url.webUri?.host ?? id.toString();

  String get fileName => '$id.yaml';

  String get exportFileName {
    final label = realLabel;
    final lower = label.toLowerCase();
    if (lower.endsWith('.yaml') || lower.endsWith('.yml')) {
      return label;
    }
    return '$label.yaml';
  }

  String get updatingKey => 'profile_$id';

  Future<Profile?> checkAndUpdateAndCopy({
    required ValidateConfig validate,
  }) async {
    if (type != ProfileType.url) {
      return null;
    }
    final mFile = await _getFile(false);
    if (await mFile.exists()) {
      return null;
    }
    return update(validate: validate);
  }

  Future<File> _getFile([bool autoCreate = true]) async {
    final path = await appPath.getProfilePath(id.toString());
    final file = File(path);
    final isExists = await file.exists();
    if (!isExists && autoCreate) {
      return file.create(recursive: true);
    }
    return file;
  }

  Future<File> get file async {
    return _getFile();
  }

  /// 磁盘内容是密文时解密成明文（不解密失败则返回 null）。
  Future<String?> readPlaintext() async {
    final mFile = await _getFile(false);
    return ProfileContentCipher.readPlaintext(mFile, id);
  }

  Future<Profile> update({required ValidateConfig validate}) async {
    // 订阅密钥来源（按优先级）：
    //   1. 配置码 / 订阅 URL 里的 `key=`（面板生成码时带上该用户的派生密钥）；
    //   2. 站点表内置密钥 + 该 URL 的 uuid（uuid 从明文节点凭据里取）；
    // 有密钥才用面板约定的 UA + 随机 X-IV 请求；没有就按普通客户端拿明文。
    final explicitKey =
        SubscribeSite.keyFromUrl(url) ?? await SubscribeSite.cachedSiteKey(url);
    final site = SubscribeSite.forUrl(url);
    final secretKey = explicitKey ?? site?.key;
    final iv = secretKey == null ? null : SubscribeCrypto.generateIv();
    final userAgent = secretKey == null
        ? null
        : (site?.userAgent ?? 'LFExp-ios/1.0.10');
    final response = await request.getFileResponseForUrl(
      url,
      headers: {
        if (iv != null) 'X-IV': iv,
        if (userAgent != null) 'User-Agent': userAgent,
      },
    );
    final disposition = response.headers.value('content-disposition');
    final userinfo = response.headers.value('subscription-userinfo');
    Profile copyWithMeta() => copyWith(
      label: label.takeFirstValid([
        getFileNameForDisposition(disposition),
        defaultLabel,
      ]),
      subscriptionInfo: SubscriptionInfo.formHString(userinfo),
    );

    if (!SubscribeCrypto.isEncrypted(response.headers.map) ||
        secretKey == null) {
      final bytes = decompressUnlabeled(response.data ?? Uint8List(0));
      if (secretKey != null && explicitKey == null) {
        final uuid = SubscribeSite.extractUuid(
          utf8.decode(bytes, allowMalformed: true),
        );
        if (uuid != null) {
          await SubscribeSite.saveUuid(url, uuid);
        }
      }
      return copyWithMeta().saveFile(
        bytes,
        validate: validate,
      );
    }

    final cachedUuid =
        explicitKey == null ? await SubscribeSite.cachedUuid(url) : null;
    final decryptionKey = explicitKey ??
        (cachedUuid != null && site != null ? site.deriveKey(cachedUuid) : null);
    if (decryptionKey != null) {
      final decrypted = SubscribeCrypto.decryptDetailed(
        ciphertext: response.data ?? Uint8List(0),
        iv: iv!,
        key: decryptionKey,
        expectedSha: response.headers.value('x-content-sha'),
      );
      if (decrypted.plain == null) {
        throw MessageException('订阅解密失败：${decrypted.reason}');
      }
      commonPrint.log(
        '[subscribe] 加密订阅解密成功（密文 ${response.data?.length ?? 0}B）',
      );
      return copyWithMeta().saveFile(
        Uint8List.fromList(utf8.encode(decrypted.plain!)),
        validate: validate,
      );
    }

    // 首次：用普通 UA 拉一次明文，从节点凭据里取 uuid（同时本次直接用明文）。
    final plainResponse = await request.getFileResponseForUrl(url);
    final plainBytes = decompressUnlabeled(
      plainResponse.data ?? Uint8List(0),
    );
    final uuid = SubscribeSite.extractUuid(
      utf8.decode(plainBytes, allowMalformed: true),
    );
    if (uuid != null) {
      await SubscribeSite.saveUuid(url, uuid);
      commonPrint.log('[subscribe] 已从明文订阅提取 uuid，后续走加密下发');
    } else {
      commonPrint.log(
        '[subscribe] 加密订阅但明文探针未取到 uuid，本次按明文保存',
        logLevel: LogLevel.warning,
      );
    }
    return copyWithMeta().saveFile(
      plainBytes,
      validate: validate,
    );
  }



  /// 订阅里出现 lfexp 节点就按自家协议处理（加密落盘）。
  static bool _carriesLfexpProxy(List<int> bytes) {
    try {
      final raw = loadYaml(utf8.decode(bytes, allowMalformed: true));
      if (raw is! Map) return false;
      final proxies = raw['proxies'];
      if (proxies is! List) return false;
      for (final proxy in proxies) {
        if (proxy is! Map) continue;
        if ('${proxy['type']}'.toLowerCase() == 'lfexp') return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Profile> saveFile(
    Uint8List bytes, {
    required ValidateConfig validate,
  }) async {
    final path = await appPath.tempFilePath;
    final tempFile = File(path);
    await tempFile.safeWriteAsBytes(bytes);
    final issue = await validate(path, ageSecretKey);
    if (issue != null) {
      throw MessageException(issue);
    }
    final mFile = await file;
    await tempFile.copy(mFile.path);
    await tempFile.safeDelete();
    // 只有带 lfexp 节点的订阅才加密落盘：那是自家协议，磁盘不留明文。
    // 其它协议的订阅保持原版行为，明文落盘。
    if (_carriesLfexpProxy(bytes)) {
      await ProfileContentCipher.encryptInPlace(mFile, id);
    }
    return copyWith(lastUpdateDate: DateTime.now());
  }
}
