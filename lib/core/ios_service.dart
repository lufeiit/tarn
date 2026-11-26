import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:tarn/common/common.dart';
import 'package:tarn/common/diag_bundle.dart';
import 'package:tarn/common/diag_pending.dart';
import 'package:tarn/common/ios_local_proxies.dart';
import 'package:tarn/common/sensitive_domain.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/models/core.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vpn_bridge/vpn_bridge.dart';

import 'desktop/model.dart';
import 'event.dart';
import 'interface.dart';
import 'ios_diag_flag.dart';
import 'method.dart';
import 'spill.dart';

/// iOS 核心适配。
///
/// 传输层：`VpnBridge` 拉起/停止 PacketTunnel 扩展，官方 [CoreMethod.wireName]
/// 原样投递给扩展里的 Go 桥，轮询 `results/<id>.json` 取回结果。
///
/// 在这之上带一套**诊断版运行逻辑**（从生产二开移植，见 Gitea `ios` 分支）：
///
///  * 启动隧道必须**等到 `connected` 再返回**，不能 `startVPNTunnel()` 一返回就发
///    业务 IPC —— 扩展 `startTunnel` 里还要 quickSetup（内核 + 全量节点），实测
///    这几十秒里发出去的 `provider.list` 只能等在 msgqueue 里直到 15s 超时。
///  * `setupParams` 落 App Group：扩展启动时自己读，不依赖 App 当时是否还没连上。
///  * 看门狗每 5s 查一次：状态说 connected 但扩展不回话，连续 3 次才判死。
///  * 每一步写 `Documents/vpnlog.txt`（`--dart-define=IOS_DIAG=true` 或面板开关
///    打开时），失败时把扩展 `extDiag.txt` + `diagVpn` 现场一起落盘，一次拉全。
class CoreIos extends CoreHandlerInterface with WidgetsBindingObserver {
  CoreIos();

  static const Duration _defaultTimeout = Duration(seconds: 15);
  static const Duration _pollInterval = Duration(milliseconds: 120);
  static const Duration _hardTimeoutGrace = Duration(seconds: 6);

  /// 扩展「启动宽限」：刚 connected 的这段时间里不判死（正在跑 quickSetup）。
  static const Duration _startupGrace = Duration(seconds: 60);

  /// 本次 App 主动拉起隧道的时刻（epoch ms）；null = 不是本进程拉起的。
  int? _tunnelReqAt;

  static const Duration _dpReadyMaxWait = Duration(seconds: 5);
  static const Duration _dpReadySettle = Duration(milliseconds: 300);

  final Random _random = Random.secure();
  int _revision = 0;

  String? _lastInitParamsJson;
  String? _lastSetupParamsJson;

  String? _prevVpnStatus;
  DateTime? _connectedSince;
  int _deadExtStreak = 0;
  int _healCountInWindow = 0;
  DateTime? _healWindowStart;
  Timer? _watchdog;
  Timer? _activityTimer;
  bool _observesActivity = false;
  bool _readingActivity = false;
  int _activitySession = 0;

  bool? _hasIpv6;
  bool _fdBridgeLogged = false;

  Future<void>? _dpReadyFuture;

  void Function(bool connected)? _tunnelStateListener;
  bool? _tunnelStateNotified;

  // MARK: - 生命周期

  @override
  void setTunnelStateListener(void Function(bool connected)? listener) {
    _tunnelStateListener = listener;
    // 新监听者要在建立时就知道当前状态，而不是等下一次 5 秒心跳；否则 App
    // 启动后即使隧道没开也会沿用 startCore 记下的「已连接」。
    _tunnelStateNotified = null;
    if (listener != null) {
      unawaited(_vpnWatchdogTick());
    }
  }

  /// 隧道（= iOS 上的内核）连通状态变化时通知 App 层，让「运行中」与系统里
  /// 实际在跑的隧道保持一致：扩展可能由测速、切节点或系统 VPN 开关拉起，
  /// 单看 App 自己的 setRunning 记录对不上。
  void _notifyTunnelState(String status) {
    // connecting 也算运行中：否则拉起过程中先报 false 再报 true，卡片会闪。
    final connected = status == 'connected' || status == 'connecting';
    if (connected == _tunnelStateNotified) return;
    _tunnelStateNotified = connected;
    _activitySession++;
    _syncActivityPolling();
    _tunnelStateListener?.call(connected);
  }

  bool get _shouldReadActivity =>
      _observesActivity &&
      _tunnelStateNotified == true &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _syncActivityPolling();

  void _syncActivityPolling() {
    if (!_shouldReadActivity) {
      _activityTimer?.cancel();
      _activityTimer = null;
      return;
    }
    if (_activityTimer != null) return;
    _activityTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => unawaited(_readActivity()),
    );
    unawaited(_readActivity());
  }

  Future<void> _readActivity() async {
    if (_readingActivity || !_shouldReadActivity) return;
    _readingActivity = true;
    final session = _activitySession;
    try {
      final data = await _invokeWire(
        'ios.readActivity',
        timeout: const Duration(seconds: 2),
      );
      if (session != _activitySession || !_observesActivity) return;
      for (final event in coreEventsFromData(data)) {
        coreEventManager.sendEvent(event);
      }
    } catch (_) {
      // Older extensions do not implement this optional feed.
    } finally {
      _readingActivity = false;
    }
  }

  CoreLifecycleResult _lifecycle(CoreLifecycleOutcome outcome) {
    _revision++;
    return CoreLifecycleResult(revision: _revision, outcome: outcome);
  }

  @override
  Future<bool> get isInit async {
    final dir = await VpnBridge.groupContainerPath();
    if (dir == null || dir.isEmpty) return false;
    final has = File('$dir/initParams.json').existsSync();
    _vpnlog('isInit group=${dir.isEmpty ? 'empty' : 'ok'} hasInitParams=$has');
    return has;
  }

  @override
  Future<void> init(InitParams params) async {
    // 首次启动：把核心初始化参数写入 App Group（扩展启动 quickSetup 读取）。
    _lastInitParamsJson = jsonEncode(params.toJson());
    _vpnlog('init params: $_lastInitParamsJson');
    try {
      // setupParams 只有本次进程真的拿到过才传：Swift 侧对 null 不写文件，
      // 传 '{}' 反而会把上一次的有效配置抹成空。
      await VpnBridge.setCoreConfig(
        initParamsJson: _lastInitParamsJson,
        setupParamsJson: _lastSetupParamsJson,
      );
    } catch (error) {
      _vpnlog('init: setCoreConfig failed: $error');
    }
  }

  /// 冷启动时停掉上一次会话残留的隧道。
  ///
  /// 扩展是按需拉起的，所以 App 启动时系统里若还有隧道在跑，一定是残留：
  /// 停掉并关掉 on-demand，否则旧版遗留的 on-demand 会让系统反复拉起扩展
  /// （起来 → quickSetup 失败 → 系统再拉起，形成重启风暴）。
  ///
  /// 不能放在 [init] 里：`initCore` 只在 App Group 没有 initParams 时才调
  /// `init`，第二次冷启动就跳过了 —— 实测残留隧道因此一直没被停。
  Future<void> _stopStaleSession() async {
    try {
      final st = await VpnBridge.status().timeout(const Duration(seconds: 2));
      if (st == 'connected' || st == 'connecting') {
        final ageMs = await _vpnSessionAgeMs();
        _vpnlog('start: 停掉残留隧道 st=$st age=${ageMs ?? 'unknown'}');
        await VpnBridge.stop().timeout(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(milliseconds: 800));
      } else {
        _vpnlog('start: 没有在跑的隧道（st=$st）');
      }
    } catch (error) {
      _vpnlog('start: 停残留隧道失败 $error');
    }
  }

  @override
  Future<CoreLifecycleResult> start() async {
    if (!_observesActivity) {
      _observesActivity = true;
      WidgetsBinding.instance.addObserver(this);
      _syncActivityPolling();
    }
    // iOS 的扩展按需拉起：App 启动 / 应用配置只把参数落盘，不建立隧道。
    // 二开客户端一直是这个语义 —— 没配置时启动内核没有任何意义，反而会在
    // iOS 上白占一份扩展内存。真正需要内核的动作（测速、切节点、用户按开关）
    // 由 [_ensureKernelActive] 拉起。
    _startWatchdog();
    // fd 桥开关必须在任何隧道建立之前落到 App Group。
    await _applyFdBridgeFlag();
    // 诊断标记文件：内核 + 扩展落盘诊断的总开关。
    await DiagPolicy.restoreUserFlag();
    await DiagPolicy.syncFlagFile();
    unawaited(_diagProbeContainer());
    unawaited(_probeIpv6());
    if (DiagPolicy.active) {
      unawaited(_reportDiagBundleAtStart());
    }
    await _stopStaleSession();
    final st = await _vpnStatus();
    _notifyTunnelState(st);
    if (st == 'connected' || st == 'connecting') {
      await _awaitDataPlaneReady();
    }
    _vpnlog('start: 不主动拉起隧道（status=$st）');
    return _lifecycle(CoreLifecycleOutcome.applied);
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    // 用户按下仪表盘开关 = 明确要内核：这里才真正拉起扩展。
    final st = await _vpnStatus();
    if (st == 'connected' || st == 'connecting') {
      await VpnBridge.stop();
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    final ok = await _ensureKernelActive();
    if (!ok) {
      throw const CoreMethodException(
        code: 'vpn_start_failed',
        message: 'The tunnel extension did not reach connected state',
      );
    }
    _notifyTunnelState('connected');
    return _lifecycle(CoreLifecycleOutcome.applied);
  }

  @override
  Future<CoreLifecycleResult> stop() async {
    _prevVpnStatus = null;
    _connectedSince = null;
    _deadExtStreak = 0;
    _tunnelReqAt = null;
    _dpReadyFuture = null;
    await VpnBridge.stop();
    _notifyTunnelState('disconnected');
    _vpnlog('stop requested');
    return _lifecycle(CoreLifecycleOutcome.applied);
  }

  /// iOS 没有独立的监听进程：开始/停止「监听」就是拉起/断开隧道，
  /// 否则仪表盘的开始按钮只会拿到 transport_disconnected。
  @override
  Future<void> startListener() async {
    if (!await _ensureKernelActive()) {
      throw const CoreMethodException(
        code: 'vpn_start_failed',
        message: 'The tunnel extension did not reach connected state',
      );
    }
    _notifyTunnelState('connected');
  }

  @override
  Future<void> stopListener() async {
    await VpnBridge.stop();
    _notifyTunnelState('disconnected');
  }

  @override
  Future<CoreLifecycleResult> close() {
    if (_observesActivity) {
      WidgetsBinding.instance.removeObserver(this);
      _observesActivity = false;
      _activitySession++;
      _syncActivityPolling();
    }
    return stop();
  }

  // MARK: - 配置

  @override
  Future<void> updateConfig(UpdateParams params) async {
    if (await _extensionActive()) await super.updateConfig(params);
  }

  /// `setupParams` 必须**先落盘**再尝试 IPC：扩展启动时 `loadConfigFromAppGroup`
  /// 读的就是它。当前症状（`config.setup` 15s 超时）正是只走 IPC、扩展又没起。
  @override
  Future<void> setupConfig(SetupParams params) async {
    final payload = params.toJson();
    _lastSetupParamsJson = jsonEncode(payload);
    try {
      final base = payload['base'];
      final Object? overlay = base is Map
          ? base['overlay']
          : base is SetupBase
          ? base.overlay
          : null;
      _vpnlog(
        'setupConfig: base=${base == null ? 'null' : base.runtimeType} '
        'overlayLen=${overlay is String ? overlay.length : 'n/a'}',
      );
      if (overlay is String) {
        // 落一份到 Documents（devicectl 能直接拉），排障时看实际下发的
        // overlay 有没有 dns/tun 这些段。
        try {
          final docs = await getApplicationDocumentsDirectory();
          File('${docs.path}/overlay.yaml').writeAsStringSync(overlay);
        } catch (_) {}
        final map = IosLocalProxies.configMapFromYamlString(overlay);
        final overlayRuleProviders = map?['rule-providers'];
        final overlayProxyProviders = map?['proxy-providers'];
        _vpnlog(
          'setupConfig: overlay rule-providers='
          '${overlayRuleProviders is Map ? overlayRuleProviders.length : 0} '
          'proxy-providers='
          '${overlayProxyProviders is Map ? overlayProxyProviders.length : 0} '
          'lfexpSplit=${map?.containsKey('lfexp-split-rule-providers') == true}',
        );
        final dns = map?['dns'];
        if (dns is Map) {
          _vpnlog(
            'setupConfig: overlay dns enable=${dns['enable']} '
            'mode=${dns['enhanced-mode']} '
            'psns=${dns['proxy-server-nameserver']}',
          );
        } else {
          _vpnlog(
            'setupConfig: overlay 没有 dns 段（overlayLen=${overlay.length}）',
          );
        }
      }
    } catch (_) {}
    try {
      await VpnBridge.setCoreConfig(
        initParamsJson: _lastInitParamsJson,
        setupParamsJson: _lastSetupParamsJson,
      );
      _vpnlog('setupConfig: 已落盘 setupParams.json');
    } catch (error) {
      _vpnlog('setupConfig: 落盘失败 $error');
    }
    // 扩展已在跑 ⇒ 立刻生效；没跑 ⇒ 不抛，等它启动时从文件读。
    if (await _extensionActive()) {
      try {
        await _invokeExt(
          CoreMethod.configSetup,
          arguments: payload,
          timeout: const Duration(seconds: 10),
        );
        _vpnlog('setupConfig: IPC ok');
      } catch (error) {
        _vpnlog('setupConfig: IPC failed ($error)，已由落盘兜底');
      }
    } else {
      _vpnlog('setupConfig: 扩展未运行，跳过 IPC');
    }
  }

  @override
  Future<ProxiesData> getProxies() async {
    if (await _extensionActive()) {
      try {
        final live = await super.getProxies();
        try {
          return await IosLocalProxies.alignKernelTestUrls(live);
        } catch (error) {
          _vpnlog('getProxies: test URL alignment failed ($error)');
          return live;
        }
      } catch (error) {
        _vpnlog('getProxies: IPC failed ($error)，回退本地解析');
      }
    }
    final local = await IosLocalProxies.buildProxiesData();
    if (local != null) return local;
    return const ProxiesData(proxies: <String, dynamic>{}, all: <String>[]);
  }

  /// 节点/分组/规则解析。扩展未运行时直接从订阅 YAML 本地解析，不发 IPC。
  ///
  /// 这一步是「按需拉起」的配套：官方协议把它放在内核里，而我们的扩展
  /// 只在测速/切节点时才起，进节点页这一刻还没有内核可用。
  @override
  Future<Map<String, dynamic>> getProfileOutbounds(String path) async {
    if (await _extensionActive()) {
      try {
        return await super.getProfileOutbounds(path);
      } catch (error) {
        _vpnlog('getProfileOutbounds: IPC failed ($error)，回退本地解析');
      }
    }
    final local = await _readProfileOutboundsLocally(path);
    if (local.isEmpty) {
      _vpnlog('getProfileOutbounds: 本地解析为空（$path）');
    }
    return local;
  }

  Future<Map<String, dynamic>> _readProfileOutboundsLocally(String path) async {
    try {
      final text = await _readProfileText(path);
      if (text == null) return const <String, dynamic>{};
      return IosLocalProxies.configMapFromYamlString(text) ??
          const <String, dynamic>{};
    } catch (error) {
      _vpnlog('getProfileOutbounds: 本地解析失败 $error');
      return const <String, dynamic>{};
    }
  }

  /// 读订阅内容：配置不可见的订阅磁盘上是密文，能解就解。
  Future<String?> _readProfileText(String path) async {
    final file = File(path);
    if (!await file.exists()) return null;
    if (await ProfileContentCipher.isEncrypted(file)) {
      final id = int.tryParse(path.split('/').last.split('.').first);
      if (id != null) {
        final plain = await ProfileContentCipher.readPlaintext(file, id);
        if (plain != null) return plain;
      }
    }
    return file.readAsString();
  }

  /// 配置校验。扩展未运行时用本地 YAML 解析做最小校验（能解析、顶层是 Map）。
  ///
  /// 添加订阅必须能完成：这一步在官方协议里由内核做，而我们的扩展是按需
  /// 拉起的，不能因为「内核没跑」就拒绝添加配置。
  @override
  Future<String?> validateConfig(String path) async {
    if (await _extensionActive()) {
      try {
        return await super.validateConfig(path);
      } catch (error) {
        _vpnlog('validateConfig: IPC failed ($error)，回退本地校验');
      }
    }
    try {
      final text = await _readProfileText(path);
      if (text == null) return 'file not found: $path';
      if (text.trim().isEmpty) return 'config is empty';
      final map = IosLocalProxies.configMapFromYamlString(text);
      if (map == null) return 'invalid yaml: cannot parse config';
      if (map['proxies'] is! List && map['proxy-providers'] is! Map) {
        return 'no proxies found in config';
      }
      return null;
    } catch (error) {
      return 'invalid yaml: $error';
    }
  }

  /// profile 基础信息（配置主体 + MATCH 规则 + 计数）。扩展未运行时本地算，
  /// 语义与内核 `handleGetProfileBaseOfficial` 对齐：proxies / proxy-groups /
  /// rules / sub-rules 从 config 里摘掉，交给内核按 path 读取。
  @override
  Future<ProfileBase> getProfileBase(String path) async {
    if (await _extensionActive()) {
      try {
        return await super.getProfileBase(path);
      } catch (error) {
        _vpnlog('getProfileBase: IPC failed ($error)，回退本地解析');
      }
    }
    var filePath = path;
    String? content;
    if (path.trimLeft().startsWith('{')) {
      try {
        final obj = jsonDecode(path);
        if (obj is Map) {
          filePath = '${obj['path'] ?? ''}';
          content = obj['content'] as String?;
        }
      } catch (_) {}
    }
    final text = content ?? await _readProfileText(filePath);
    if (text == null) {
      _vpnlog('getProfileBase: 读不到配置 path=$filePath');
      return ProfileBase(config: <String, dynamic>{}, digest: '');
    }
    final map = IosLocalProxies.configMapFromYamlString(text) ?? {};
    final proxies = map['proxies'];
    final groups = map['proxy-groups'];
    final rules = map['rules'];
    final matchRules = <String>[
      if (rules is List)
        for (final rule in rules)
          if ('$rule'.toLowerCase().trim().startsWith('match')) '$rule',
    ];
    final config = Map<String, dynamic>.from(map)
      ..remove('proxies')
      ..remove('proxy-groups')
      ..remove('rules')
      ..remove('sub-rules');
    _vpnlog(
      'getProfileBase: local path=$filePath yamlLen=${text.length} '
      'proxies=${proxies is List ? proxies.length : 0} '
      'groups=${groups is List ? groups.length : 0} '
      'rules=${rules is List ? rules.length : 0}',
    );
    return ProfileBase(
      config: config,
      digest: sha256.convert(utf8.encode(text)).toString(),
      matchRules: matchRules,
      proxies: proxies is List ? proxies.length : 0,
      proxyGroups: groups is List ? groups.length : 0,
      rules: rules is List ? rules.length : 0,
    );
  }

  // MARK: - IPC

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) async {
    // 只有用户明确要内核数据的动作才拉起扩展；其余在扩展未运行时立即失败，
    // 不要把一个请求挂在 msgqueue 里等 15 秒（那正是首页红条的来源）。
    if (_needsKernel.contains(method)) {
      if (!await _ensureKernelActive()) {
        throw const CoreMethodException(
          code: 'transport_disconnected',
          message: 'The tunnel extension is not running',
        );
      }
    } else if (!await _extensionActive()) {
      _vpnlog('invoke ${method.wireName}: 扩展未运行，快速失败');
      throw const CoreMethodException(
        code: 'transport_disconnected',
        message: 'The tunnel extension is not running',
      );
    }
    final result = await _invokeExt(
      method,
      arguments: arguments,
      timeout: timeout,
    );
    return model == null ? result : model(result);
  }

  /// 需要把扩展真正拉起来的动作。测速与切节点是用户明确操作；其余的读取类
  /// 请求扩展没跑就直接失败，交给调用方兜底（列表页空着、proxies 走本地解析）。
  static const Set<CoreMethod> _needsKernel = {
    CoreMethod.proxyTestDelay,
    CoreMethod.proxySelect,
  };

  /// 外部资源提供者列表：扩展没跑时直接返回空，不发起 IPC。
  @override
  Future<List<ExternalProvider>> getExternalProviders() async {
    if (!await _extensionActive()) return const <ExternalProvider>[];
    return super.getExternalProviders();
  }

  Future<Object?> _invokeExt(
    CoreMethod method, {
    Object? arguments,
    Duration? timeout,
  }) => _invokeWire(method.wireName, arguments: arguments, timeout: timeout);

  Future<Object?> _invokeWire(
    String wireName, {
    Object? arguments,
    Duration? timeout,
  }) async {
    final wait = timeout ?? _defaultTimeout;
    final watch = Stopwatch()..start();
    final id =
        '${DateTime.now().microsecondsSinceEpoch}'
        '-${_random.nextInt(1 << 31)}';
    final st = await _vpnStatus();
    _vpnlog(
      'invoke $wireName id=$id vpn=$st '
      'timeout=${wait.inSeconds}s',
    );
    final sent = await VpnBridge.sendToExtension(
      jsonEncode(<String, Object?>{
        'id': id,
        'method': wireName,
        'data': arguments,
      }),
    );
    if (!sent) {
      _vpnlog('invoke $wireName: sendToExtension=false');
      throw const CoreMethodException(
        code: 'transport_disconnected',
        message: 'The tunnel extension is not reachable',
      );
    }

    final deadline = DateTime.now().add(wait + _hardTimeoutGrace);
    while (DateTime.now().isBefore(deadline)) {
      final raw = await VpnBridge.readResult(id);
      if (raw != null && raw.isNotEmpty) {
        await VpnBridge.clearResult(id);
        _vpnlog(
          'invoke $wireName -> ${raw.length}B in '
          '${watch.elapsedMilliseconds}ms',
        );
        return _decode(wireName, raw);
      }
      await Future<void>.delayed(_pollInterval);
    }

    _vpnlog(
      'invoke $wireName TIMEOUT after ${watch.elapsedMilliseconds}ms '
      'vpn=${await _vpnStatus()}',
    );
    // 超时是排查的现场：把扩展诊断 + VPN 配置快照留下，再抛。
    if (wireName != 'ios.readActivity') {
      unawaited(_vpnlogExtDiag(force: true));
      unawaited(_diagVpnSnapshot(tag: 'timeout $wireName'));
    }
    try {
      await VpnBridge.clearResult(id);
    } catch (_) {}
    throw TimeoutException(
      'Core method $wireName timed out after ${wait.inSeconds}s',
      wait,
    );
  }

  Object? _decode(String wireName, String raw) {
    final Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException catch (error) {
      throw CoreMethodException(
        code: 'bad_result',
        message: 'Core answered $wireName with invalid JSON',
        details: error.message,
      );
    }
    if (parsed is! Map) {
      throw CoreMethodException(
        code: 'bad_result',
        message: 'Core answered $wireName with an unexpected payload',
      );
    }
    final code = parsed['code'];
    if (code is int && code != 0) {
      final data = parsed['data'];
      _vpnlog('invoke $wireName: core code=$code data=$data');
      throw CoreMethodException(
        code: 'core_$code',
        message: '${data ?? 'core error'}',
      );
    }
    return parsed['data'];
  }

  // MARK: - 拉起隧道

  Future<bool> _ensureKernelActive() async {
    try {
      return await _doEnsureKernelActive();
    } catch (error) {
      _vpnlog('ensureKernel failed: $error');
      return false;
    }
  }

  Future<bool> _doEnsureKernelActive() async {
    await _applyFdBridgeFlag();
    var status = await _vpnStatus();
    if (status == 'disconnecting') {
      _vpnlog('ensureKernel: disconnecting，等它落定');
      for (var i = 0; i < 150; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final s = await _vpnStatus();
        if (s == 'disconnected' || s == 'connected' || s == 'connecting') {
          status = s;
          break;
        }
      }
    }
    _vpnlog('ensureKernel begin status=$status');
    await _diagVpnSnapshot(tag: 'ensureKernel begin');

    if (status == 'connected') {
      _vpnlog('ensureKernel fastpath connected');
      // 状态会骗人：connected 但扩展不回话时，后面的 IPC 全会超时。
      if (await _extensionResponds()) {
        await _awaitDataPlaneReady();
        return true;
      }
      _vpnlog('ensureKernel: status=connected 但扩展无响应，重启隧道');
      await VpnBridge.stop();
      await Future<void>.delayed(const Duration(seconds: 1));
      status = await _vpnStatus();
    }

    if (status != 'connecting') {
      try {
        await VpnBridge.setMinMode(false).timeout(const Duration(seconds: 3));
        // 启动前把最新 init/setup 再落一次盘，确保扩展 startTunnel 读到最新配置。
        if (_lastInitParamsJson != null || _lastSetupParamsJson != null) {
          await VpnBridge.setCoreConfig(
            initParamsJson: _lastInitParamsJson,
            setupParamsJson: _lastSetupParamsJson,
          ).timeout(const Duration(seconds: 5));
          _vpnlog('ensureKernel: 已重落 init/setup params');
        }
        final configured = await VpnBridge.ensureConfigured().timeout(
          const Duration(seconds: 15),
        );
        _vpnlog('ensureKernel: ensureConfigured=$configured');
        if (!configured) return false;
        _markTunnelStartRequested();
        final started = await VpnBridge.start().timeout(
          const Duration(seconds: 10),
        );
        _vpnlog('ensureKernel: startVPNTunnel=$started');
        if (!started) {
          await _diagVpnSnapshot(tag: 'start returned false');
          return false;
        }
      } catch (error) {
        _vpnlog('ensureKernel: autostart failed: $error');
        await _diagVpnSnapshot(tag: 'autostart exception');
        return false;
      }
    }

    // 关键：等到 connected 再返回，最多 30s。
    var last = status;
    for (var i = 0; i < 150; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      last = await _vpnStatus();
      if (last == 'connected') {
        _vpnlog('ensureKernel: connected after ${(i + 1) * 200}ms');
        await _awaitDataPlaneReady();
        return true;
      }
    }
    _vpnlog('ensureKernel: 30s 内未 connected，最后状态=$last');
    // 等 quickSetup 窗口过去再看扩展日志（此时 extDiag 才写完）。
    await Future<void>.delayed(const Duration(seconds: 12));
    await _vpnlogExtDiag(force: true);
    await _diagVpnSnapshot(tag: 'connect timeout last=$last');
    return false;
  }

  Future<String> _vpnStatus() async {
    try {
      return await VpnBridge.status().timeout(const Duration(seconds: 3));
    } catch (_) {
      return 'unknown';
    }
  }

  Future<bool> _extensionActive() async {
    final st = await _vpnStatus();
    return st == 'connected' || st == 'connecting';
  }

  /// 扩展是否**真的**响应 —— VPN 状态会骗人。
  ///
  /// 探活必须无参：带参方法漏参会让 Go 侧类型断言 panic，被 recover 成错误响应，
  /// 于是「健康隧道」被看门狗当成死的。
  Future<bool> _extensionResponds({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      await _invokeExt(CoreMethod.coreInitialized, timeout: timeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  // MARK: - 看门狗

  void _startWatchdog() {
    _watchdog ??= Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_vpnWatchdogTick()),
    );
  }

  Future<void> _vpnWatchdogTick() async {
    final st = await _vpnStatus();
    _notifyTunnelState(st);
    if (st != _prevVpnStatus) {
      _prevVpnStatus = st;
      _connectedSince = st == 'connected' ? DateTime.now() : null;
      _vpnlog('watchdog: status -> $st');
    }
    final inGrace =
        _connectedSince != null &&
        DateTime.now().difference(_connectedSince!) < _startupGrace;
    if (st != 'connected' || inGrace) return;

    if (await _extensionResponds()) {
      _deadExtStreak = 0;
      return;
    }
    _deadExtStreak++;
    _vpnlog('watchdog: connected 但扩展无响应（第 $_deadExtStreak 次）');
    if (_deadExtStreak < 3) return;

    _deadExtStreak = 0;
    final now = DateTime.now();
    final windowStart = _healWindowStart;
    if (windowStart == null ||
        now.difference(windowStart) > const Duration(minutes: 10)) {
      _healWindowStart = now;
      _healCountInWindow = 0;
    }
    if (_healCountInWindow >= 3) {
      _vpnlog('watchdog: 10 分钟内自愈 3 次，熔断不再动隧道');
      return;
    }
    _healCountInWindow++;
    _vpnlog('watchdog: 判死扩展，第 $_healCountInWindow 次自愈');
    await _diagVpnSnapshot(tag: 'watchdog heal');
    await VpnBridge.stop();
    await Future<void>.delayed(const Duration(seconds: 1));
    await _ensureKernelActive();
  }

  // MARK: - 数据面就绪门禁

  void _markTunnelStartRequested() {
    _tunnelReqAt = DateTime.now().millisecondsSinceEpoch;
    _dpReadyFuture = null;
  }

  Future<void> _awaitDataPlaneReady() =>
      _dpReadyFuture ??= _waitDataPlaneReady();

  Future<void> _waitDataPlaneReady() async {
    final t0 = DateTime.now();
    final String? group;
    try {
      group = await VpnBridge.groupContainerPath().timeout(
        const Duration(seconds: 3),
      );
    } catch (_) {
      _vpnlog('dataPlaneReady: 拿不到组容器路径，跳过');
      return;
    }
    if (group == null || group.isEmpty) return;
    final file = File('$group/Library/dp-ready.json');
    final reqAt = _tunnelReqAt;
    while (DateTime.now().difference(t0) < _dpReadyMaxWait) {
      try {
        if (file.existsSync()) {
          final obj = jsonDecode(file.readAsStringSync());
          final at = (obj is Map ? obj['at'] as num? : null)?.toInt() ?? 0;
          if (reqAt == null || at >= reqAt - 3000) {
            await Future<void>.delayed(_dpReadySettle);
            _vpnlog(
              'dataPlaneReady ok after '
              '${DateTime.now().difference(t0).inMilliseconds}ms',
            );
            return;
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    _vpnlog('dataPlaneReady TIMEOUT(${_dpReadyMaxWait.inSeconds}s)，放行');
  }

  Future<int?> _vpnSessionAgeMs() async {
    try {
      final group = await VpnBridge.groupContainerPath().timeout(
        const Duration(seconds: 1),
      );
      if (group == null || group.isEmpty) return null;
      final file = File('$group/Library/dp-ready.json');
      if (!file.existsSync()) return null;
      final obj = jsonDecode(file.readAsStringSync());
      final at = (obj is Map ? obj['at'] as num? : null)?.toInt();
      if (at == null) return null;
      return DateTime.now().millisecondsSinceEpoch - at;
    } catch (_) {
      return null;
    }
  }

  // MARK: - 诊断

  Future<void> _applyFdBridgeFlag() async {
    try {
      await VpnBridge.setFdBridge(true).timeout(const Duration(seconds: 3));
      if (!_fdBridgeLogged) {
        _fdBridgeLogged = true;
        _vpnlog('fdBridge flag=true applied');
      }
    } catch (error) {
      if (!_fdBridgeLogged) {
        _fdBridgeLogged = true;
        _vpnlog('fdBridge setFlag failed: $error');
      }
    }
  }

  Future<String>? _vpnlogDir;
  int _vpnlogBytes = -1;

  static const int _vpnlogMaxBytes = 2 * 1024 * 1024;
  static const int _vpnlogKeepBytes = 512 * 1024;

  void _vpnlog(String msg) {
    if (!DiagPolicy.active) return;
    try {
      final data = utf8.encode(
        '${DateTime.now().toIso8601String()} ${SensitiveDomains.maskAll(msg)}\n',
      );
      _vpnlogDir ??= getApplicationDocumentsDirectory()
          .then((d) => d.path)
          .catchError((_) => '');
      _vpnlogDir!.then((dir) {
        if (dir.isEmpty) return;
        try {
          final f = File('$dir/vpnlog.txt');
          if (_vpnlogBytes < 0) {
            _vpnlogBytes = f.existsSync() ? f.lengthSync() : 0;
          }
          if (_vpnlogBytes > _vpnlogMaxBytes) {
            _rotateVpnlog(f);
          }
          f.writeAsBytesSync(data, mode: FileMode.append, flush: true);
          _vpnlogBytes += data.length;
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _rotateVpnlog(File f) {
    try {
      final all = f.readAsBytesSync();
      var start = all.length > _vpnlogKeepBytes
          ? all.length - _vpnlogKeepBytes
          : 0;
      while (start < all.length && all[start] != 0x0A) {
        start++;
      }
      final head = utf8.encode(
        '${DateTime.now().toIso8601String()} '
        '===== vpnlog 轮转（超过 ${_vpnlogMaxBytes ~/ 1024}KB，仅保留尾部）=====\n',
      );
      final tail = start < all.length ? all.sublist(start + 1) : <int>[];
      f.writeAsBytesSync([...head, ...tail], flush: true);
      _vpnlogBytes = head.length + tail.length;
    } catch (_) {
      _vpnlogBytes = 0;
    }
  }

  int _extDiagTick = 0;
  static const int _extDiagEvery = 20;

  /// 把扩展侧（Swift `extLog` / Go 日志）诊断转发进 vpnlog：只拉一个文件就能
  /// 看到两侧落盘。取**尾部**，追加写的文件头部永远是最早那几行。
  Future<void> _vpnlogExtDiag({bool force = false}) async {
    if (!DiagPolicy.active) return;
    _extDiagTick++;
    if (!force && _extDiagTick % _extDiagEvery != 0) return;
    try {
      final log = await VpnBridge.readExtLog().timeout(
        const Duration(seconds: 2),
      );
      if (log.isEmpty) {
        _vpnlog('extDiag: empty（扩展可能从未启动）');
        return;
      }
      const chunk = 800;
      const max = 4000;
      final start = log.length > max ? log.length - max : 0;
      for (var i = start; i < log.length; i += chunk) {
        final end = (i + chunk) > log.length ? log.length : (i + chunk);
        _vpnlog('_extdiag[${(i - start) ~/ chunk}]: ${log.substring(i, end)}');
      }
    } catch (error) {
      _vpnlog('extDiag: read failed $error');
    }
  }

  /// VPN 配置现场快照：provider bundle id、enabled、on-demand、系统状态。
  /// 「扩展为什么没被拉起」最先要看的就是这几项对不对。
  Future<void> _diagVpnSnapshot({String tag = ''}) async {
    try {
      final text = await VpnBridge.diagVpn().timeout(
        const Duration(seconds: 3),
      );
      _vpnlog('diagVpn[$tag]: $text');
    } catch (error) {
      _vpnlog('diagVpn[$tag]: failed $error');
    }
  }

  /// App Group 容器可写性探针：一次定性路径对不对、根目录能不能写。
  Future<void> _diagProbeContainer() async {
    try {
      String? p;
      try {
        p = await VpnBridge.groupContainerPath().timeout(
          const Duration(seconds: 3),
        );
      } catch (error) {
        _vpnlog('probe: groupContainerPath EXC: $error');
        return;
      }
      _vpnlog('probe: groupContainerPath=$p');
      if (p == null || p.isEmpty) {
        _vpnlog('probe: groupContainerPath EMPTY/nil');
        return;
      }
      final dir = Directory(p);
      _vpnlog('probe: exists=${dir.existsSync()}');
      try {
        final entries = <String>[];
        for (final e in dir.listSync()) {
          entries.add('${e.path.split('/').last}${e is Directory ? '/' : ''}');
        }
        _vpnlog('probe: entries=[${entries.join(', ')}]');
      } catch (error) {
        _vpnlog('probe: listSync EXC: $error');
      }
      try {
        final f = File('$p/probe-dart.txt');
        f.writeAsStringSync(
          '${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append,
          flush: true,
        );
        _vpnlog('probe: write root OK size=${f.lengthSync()}');
      } catch (error) {
        _vpnlog('probe: write root EXC: $error');
      }
      try {
        Directory('$p/probe-dart-dir').createSync(recursive: true);
        _vpnlog('probe: mkdir root OK');
      } catch (error) {
        _vpnlog('probe: mkdir root EXC: $error');
      }
      try {
        final lf = File('$p/Library/probe-dart.txt');
        lf.writeAsStringSync(
          '${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append,
          flush: true,
        );
        _vpnlog('probe: write Library OK size=${lf.lengthSync()}');
      } catch (error) {
        _vpnlog('probe: write Library EXC: $error');
      }
    } catch (error) {
      _vpnlog('probe: EXC: $error');
    }
  }

  Future<void> _probeIpv6() async {
    if (_hasIpv6 != null) return;
    _hasIpv6 = false;
    for (final host in const ['2606:4700:4700::1111', '2400:3200::1']) {
      try {
        final s = await Socket.connect(
          InternetAddress(host),
          53,
          timeout: const Duration(seconds: 2),
        );
        s.destroy();
        _hasIpv6 = true;
        break;
      } catch (_) {}
    }
    _vpnlog('diag.ipv6 hasIpv6=$_hasIpv6');
  }

  static Timer? _diagReportTimer;
  static int _diagReportTries = 0;
  static const Duration _minCollectAge = Duration(seconds: 60);
  static const int _maxDiagReportTries = 1;

  /// 工具型客户端不向服务端上传诊断：这里只在本地留一份整包（DiagPending），
  /// `devicectl device copy from` 可直接拉走。
  Future<void> _reportDiagBundleAtStart() async {
    if (DiagPolicy.collectReason == 'bootstrap') return;
    final from = DiagPolicy.collectFrom;
    final age = from == null
        ? const Duration(days: 1)
        : DateTime.now().difference(from);
    if (age < _minCollectAge) {
      _scheduleDiagReport(_minCollectAge - age + const Duration(seconds: 5));
      return;
    }
    if (_diagReportTries >= _maxDiagReportTries) return;
    _diagReportTries++;
    try {
      final text = await buildDiagBundle(
        appName: appName,
        memoryLines: const <String>[],
      );
      await DiagPending.save(text, source: 'boot');
      _vpnlog('diag bundle saved (${text.length}B)');
    } catch (error) {
      _vpnlog('diag bundle failed: $error');
    }
  }

  void _scheduleDiagReport(Duration delay) {
    _diagReportTimer?.cancel();
    _diagReportTimer = Timer(delay, () {
      _diagReportTimer = null;
      unawaited(_reportDiagBundleAtStart());
    });
  }
}

/// 回前台后清理「只发不收」的陈旧连接（iOS 专用）。
///
/// iOS 息屏/切网后回前台，常见「上行在发、下行永不来」——隧道看着已连接
/// 但页面打不开。内核侧 `unlockGuard` 动作会按 outbound 扫描近期活跃连接，
/// 把 upload>0 且 download==0 的关掉并重置 DNS 连接；这里只负责触发与记日志。
Future<void> runIosUnlockGuard() async {
  if (!Platform.isIOS) return;
  final id = 'unlockGuard-${DateTime.now().microsecondsSinceEpoch}';
  final bool sent;
  try {
    sent = await VpnBridge.sendToExtension(
      jsonEncode(<String, Object?>{'id': id, 'method': 'unlockGuard'}),
    );
  } catch (error) {
    commonPrint.log('[unlock-guard] 发送失败：$error', logLevel: LogLevel.warning);
    return;
  }
  if (!sent) return;
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline)) {
    final raw = await VpnBridge.readResult(id);
    if (raw != null && raw.isNotEmpty) {
      await VpnBridge.clearResult(id);
      commonPrint.log('[unlock-guard] $raw');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  commonPrint.log('[unlock-guard] 未在 3s 内取到结果', logLevel: LogLevel.warning);
}
