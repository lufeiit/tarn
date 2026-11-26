import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:tarn/common/common.dart';
import 'package:tarn/core/core.dart';
import 'package:tarn/core/interface.dart';
import 'package:tarn/core/spill.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/plugins/app.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:path/path.dart';

/// Every [CoreHandlerInterface] method passes through unless redeclared here.
extension type CoreController._(CoreHandlerInterface _interface)
    implements CoreHandlerInterface {
  static CoreController? _instance;

  factory CoreController() {
    return _instance ??= CoreController._(
      system.isAndroid ? coreLib! : coreService!,
    );
  }

  @visibleForTesting
  factory CoreController.test(CoreHandlerInterface interface) {
    return _instance = CoreController._(interface);
  }

  @visibleForTesting
  CoreController.scoped(this._interface);

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  static Future<void> ensureHomeDir() async {
    final homePath = await appPath.homeDirPath;
    final homeDir = Directory(homePath);
    final isExists = await homeDir.exists();
    if (!isExists) {
      await homeDir.create(recursive: true);
    }
    await system.grantHomeDirAccess(homePath);
  }

  static Future<void> initGeo() async {
    final homePath = await appPath.homeDirPath;
    const geoFileNameList = [MMDB, GEOIP, GEOSITE, ASN];
    try {
      for (final geoFileName in geoFileNameList) {
        final geoFile = File(join(homePath, geoFileName));
        final isExists = await geoFile.exists();
        if (isExists) {
          continue;
        }
        final asset = 'assets/data/$geoFileName';
        // rootBundle inflates the asset on the platform thread, which Android
        // shares with the UI: the four files stall frames for over 100 ms.
        if (app case final app?) {
          await app.extractAsset(asset, geoFile.path);
          continue;
        }
        final data = await rootBundle.load(asset);
        final List<int> bytes = data.buffer.asUint8List();
        await geoFile.writeAsBytes(bytes, flush: true);
      }
    } catch (e) {
      commonPrint.log(
        'Failed to initialize geo data: $e',
        logLevel: LogLevel.error,
      );
      rethrow;
    }
  }

  Future<void> init(int version) async {
    await ensureHomeDir();
    await initGeo();
    final homeDirPath = await appPath.homeDirPath;
    await _interface.init(InitParams(homeDir: homeDirPath, version: version));
  }

  /// An age-encrypted config is rewritten in place into its plaintext, and a
  /// share-link list into a config of its proxies.
  Future<String?> validateProfile(
    String path, [
    String ageSecretKey = '',
  ]) async {
    final file = File(path);
    if (await file.isAgeEncrypted) {
      if (ageSecretKey.isEmpty) {
        throw const AgeSecretKeyRequiredException();
      }
      await file.safeWriteAsString(
        await _interface.decryptConfig(path, ageSecretKey),
      );
    }
    final issue = await _interface.validateConfig(path);
    if (issue == null) {
      return null;
    }
    final List<Map<String, dynamic>> proxies;
    try {
      proxies = await _interface.convertProxies(path);
    } on Exception {
      return issue;
    }
    if (proxies.isEmpty) {
      return issue;
    }
    await file.safeWriteAsString(await encodeYamlTask({'proxies': proxies}));
    return _interface.validateConfig(path);
  }

  Future<Map<int, String>> validateProxies(List<Map<String, dynamic>> proxies) {
    if (proxies.isEmpty) {
      return Future.value(const {});
    }
    return _interface.validateProxies(proxies);
  }

  Future<Map<int, String>> validateFilters(List<String> filters) {
    if (filters.isEmpty) {
      return Future.value(const {});
    }
    return _interface.validateFilters(filters);
  }

  Future<List<String>> encodeShareLinks(List<Map<String, dynamic>> proxies) {
    if (proxies.isEmpty) {
      return Future.value(const []);
    }
    return _interface.encodeShareLinks(proxies);
  }

  Future<List<List<Map<String, dynamic>>>> decodeShareLinks(
    List<String> lines,
  ) {
    if (lines.isEmpty) {
      return Future.value(const []);
    }
    return _interface.decodeShareLinks(lines);
  }

  Future<String?> validateConfigWithData(List<int> data) async {
    final path = await appPath.tempFilePath;
    final file = File(path);
    await file.safeWriteAsBytes(data);
    try {
      return await _interface.validateConfig(path);
    } finally {
      await file.safeDelete();
    }
  }

  Future<void> setupConfig({
    required SetupParams params,
    Future<void> Function()? preloadInvoke,
  }) async {
    if (preloadInvoke == null) {
      return _interface.setupConfig(params);
    }
    await (_interface.setupConfig(params), preloadInvoke()).wait;
  }

  Future<List<Group>> getProxiesGroups({
    required ProxiesSortType sortType,
    required DelayMap delayMap,
    required Map<String, String> selectedMap,
    required String defaultTestUrl,
  }) async {
    final proxiesData = await _interface.getProxies();
    return toGroupsTask(
      ComputeGroupsState(
        proxiesData: proxiesData,
        sortType: sortType,
        delayMap: delayMap,
        selectedMap: selectedMap,
        defaultTestUrl: defaultTestUrl,
      ),
    );
  }

  Future<Map<String, dynamic>> readConfig(int id) async {
    final path = await appPath.getProfilePath(id.toString());
    // 不可见订阅磁盘上是密文：内核只认明文文件，这里临时解密一份再读。
    final file = File(path);
    final temp = File('$path.read');
    var readPath = path;
    if (await ProfileContentCipher.isEncrypted(file)) {
      if (!await ProfileContentCipher.decryptFile(file, temp, id)) {
        throw const MessageException('配置解密失败，请刷新订阅或重新导入配置码');
      }
      readPath = temp.path;
    }
    final Map<String, dynamic> data;
    try {
      data = await _interface.readConfig(readPath);
    } finally {
      if (readPath != path) {
        try {
          await temp.delete();
        } catch (_) {}
      }
    }
    data['rules'] = data['rule'];
    data.remove('rule');
    return data;
  }

  Future<Map<String, dynamic>> getProfileOutbounds(int id) async {
    return _interface.getProfileOutbounds(
      await appPath.getProfilePath(id.toString()),
    );
  }

  Future<String> buildProfile(SetupBase base) async {
    return readSpilledText(await _interface.buildProfile(base));
  }

  Future<String?> getProfileMatchTarget(int id) async {
    final path = await appPath.getProfilePath(id.toString());
    return lastMatchTarget((await _interface.getProfileBase(path)).matchRules);
  }

  Future<({ProfileBase base, String path})> getProfileBase(
    int id, {
    String? content,
  }) async {
    final path = await appPath.getProfilePath(id.toString());
    // content 非空时内核直接解析它（配置不可见的订阅磁盘上是密文）。
    final argument = content == null
        ? path
        : jsonEncode({'path': path, 'content': content});
    final base = await _interface.getProfileBase(argument);
    final config = Map<String, dynamic>.from(base.config)..remove('rule');
    return (base: base.copyWith(config: config), path: path);
  }
}

final coreController = CoreController();
