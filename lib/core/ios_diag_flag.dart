/// 诊断层开关（Dart 侧）——三个来源，任一为真即打开落盘诊断。
///
/// 1. **编译期** `iosDiag`：`--dart-define=IOS_DIAG=true` 的诊断包。
///    **自检闭环与压力循环只认这一条**——那两类会持续吃 CPU / 内存，在 50 MB
///    扩展内存上限面前，不敢靠远程开关在正式版里打开。
/// 2. **面板远程开关**（oss-config 的 `diag-logs`）：全站生效，给「登不上」这类
///    线上问题留抓手，不用给用户重装测试包。
/// 3. **账号级开关**（面板用户字段 `lfexp_diag_report`，随 `/user/getSubscribe`
///    以 `diag_report` 下发）：只开在他自己这个账号上，值存本地，下次启动即
///    生效（不必等第一次 getSubscribe）；后台打开、用户手动关，常开到他关。
///
/// 开起来就会逐包落盘：日志变大、扩展内存跟着涨，所以后两层默认全关。
///
/// **有租约（2026-10-28 业主问「我下发了开关后，用户没收到关闭的通知，有没有自动关闭的动作」）**：
/// 面板的「开」是随订阅下发的，设备只有下次联系面板（启动 App / 更新订阅）才知道值变了；运行中
/// App 不会再问一次面板（只有 VPN 看门狗那种本地定时器），所以"面板关掉"对一个再也不打开 App 的
/// 用户是传不过去的。现在每一层都带 7 天租约：开的时候记 `collect_until`，每次成功联系面板说"还开"
/// 就续期，到期自动关（删开关文件、结束采集窗口、停止上报），隧道里跑着的内核/扩展也按文件里的
/// 到期时间自己停并且把文件删掉 —— 这样「面板说了开但设备再也联系不上面板」最多 7 天自己熄火，
/// 不会永远写下去。编译期诊断包不受租约影响（那是 CI 自己在跑，跑完包就换了）。
///
/// **新装引导窗口**（业主：故障恰恰可能是「登不上面板 / 拉不动订阅」，那时候开关还没下发到）：
/// 这个包第一次启动记一个时间戳（卸载重装会重置，正是我们要的），此后 30 分钟内当作采集开着，
/// 租约就写到「首启 + 30 分钟」。老用户（首启早就过了 30 分钟）不受影响。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vpn_bridge/vpn_bridge.dart';

/// 编译期诊断版标志（与内核的 `ios_diag` tag 一一对应）。
const bool iosDiag = bool.fromEnvironment('IOS_DIAG', defaultValue: false);

class DiagPolicy {
  DiagPolicy._();

  /// 账号级开关的本地副本存在这个 prefs key 下（值是布尔，不是敏感数据）。
  static const String kUserFlagKey = 'lfexp_diag_report';

  /// 采集窗口起点（毫秒时间戳）存在这个 key 下。
  ///
  /// 为什么要有它（业主 2026-10-28：「采集获取的信息不能有迷惑性，应该是从我开启采集到结束的
  /// 那些信息，没有开启以前的信息没有作用」）：App Group 里的日志文件跨启动、甚至跨安装保留，
  /// 真机实测标准身份组里的 extDiag.txt 时间戳还停在 10-26（上一次标准诊断包留下的）——
  /// 不划起点的话，第一次上报会把那种陈旧内容一起端过去，看起来像当天的问题。
  /// 规则：active 从关变开的那一刻记起点；从开变关就清掉（窗口结束了，旧起点没意义）；
  /// 再开就是新的窗口。
  static const String kCollectFromKey = 'lfexp_diag_collect_from_ms';

  /// 租约到期时间（毫秒）。开采集时写、每次面板说"还开着"就续期、到期自动关。
  static const String kCollectUntilKey = 'lfexp_diag_collect_until_ms';

  /// 这个包第一次启动的时刻（毫秒）。卸载重装会重置（iOS 删容器）⇒ 新装引导窗口的基准。
  static const String kFirstSeenKey = 'lfexp_diag_first_seen_ms';

  /// 「面板回答过」记在这个 key 下（true = 面板就这个开关给过一个真值，开或关都算）。
  /// 引导窗口只在从没得到过答复的时候成立 —— 面板已经说关了还按引导窗口继续采，日志上就变成
  /// 「面板说关、这台却在采」，正是业主 2026-10-28 说的"不能有迷惑性"。
  static const String kPanelAnsweredKey = 'lfexp_diag_panel_answered';

  /// 一次下发能用多久（面板说开 ⇒ 到这一刻为止；再联系面板再说开就再续）。
  static const Duration kCollectLease = Duration(days: 7);

  /// 新装引导窗口：首启之后这段时间当作采集开着，覆盖「装完就登不上面板」这种故障。
  static const Duration kBootstrapWindow = Duration(minutes: 30);

  static bool _remote = false;
  static bool _user = false;
  static int? _collectFromMs;      // 采集窗口起点；null = 没有窗口（正式版从没开过采集）
  static int? _collectUntilMs;     // 租约到期；null = 没有租约（等同没开）
  static int? _firstSeenMs;        // 本包首次启动时刻（引导窗口基准）
  static bool _panelAnswered = false; // 面板就这个开关给过真值（开或关都算）
  static bool _wasActive = false;  // 用来看「关→开」这个沿，只有沿上才动窗口

  /// 落盘诊断是否开启：三个来源任一为真**且租约没到期**（编译期诊断包常驻，不看租约）。
  static bool get active {
    if (iosDiag) return true;
    if (!_remote && !_user && !bootstrapActive) return false;
    final int? until = _collectUntilMs;
    // 说"开着"却没有租约：按没开处理，绝不因为状态残缺而无限写下去。
    if (until == null) return false;
    return DateTime.now().millisecondsSinceEpoch < until;
  }

  /// 新装引导窗口是否还在：首启 30 分钟内、**且面板从没就这个开关回答过**。
  ///
  /// 后半句是 2026-10-28 补的：真机跑测试跑出来的口径错 —— 面板已经明确说"关"了，restore 时
  /// 却因为"首启 30 分钟内"又把租约续到首启+30 分钟，于是 `active` 又变真、采集窗起点也被摆回
  /// 首启那一刻，上报的 `collect_reason` 会写着 bootstrap 而面板那边显示这个账号是关着的。
  /// 引导窗口是给「装完就联系不上面板」那种故障留的抓手，有答复了就不该再猜。
  static bool get bootstrapActive {
    final int? first = _firstSeenMs;
    if (first == null || _panelAnswered) return false;
    return DateTime.now().millisecondsSinceEpoch - first <
        kBootstrapWindow.inMilliseconds;
  }

  /// 当前是谁让它开着的（写进诊断包包头，让我们一眼看出这份日志为什么会有）。
  static String get collectReason {
    if (iosDiag) return 'compile';
    final int? until = _collectUntilMs;
    final bool live = until != null &&
        DateTime.now().millisecondsSinceEpoch < until;
    if (live && _user) return 'user';       // 面板给这个账号开的
    if (live && _remote) return 'remote';   // 全站开关
    if (live && bootstrapActive) return 'bootstrap'; // 新装引导窗口
    return 'none';
  }

  /// 租约到期时刻（null = 没有窗口）。
  static DateTime? get collectUntilNullable => _collectUntilMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_collectUntilMs!);

  /// 开关文件里要写的内容：租约到期时间（本机时区、带偏移，跟日志行同一套写法）。
  /// 老版本的包只看文件在不在，内容对它们无影响；新内核/新扩展按这个时间自己停写。
  static String get flagFileContent {
    final DateTime? until = collectUntilNullable;
    if (until == null) return '1\n';
    return '${_stampLocal(until)}\n';
  }

  static String _stampLocal(DateTime t) {
    final Duration off = t.timeZoneOffset;
    final String sign = off.isNegative ? '-' : '+';
    final Duration a = off.abs();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}'
        ':${two(t.second)}$sign${two(a.inHours)}${two(a.inMinutes % 60)}';
  }

  /// 面板 oss-config 的 `diag-logs` 当前值。
  static bool get remoteEnabled => _remote;

  /// 账号级开关当前值（面板用户字段 `lfexp_diag_report`）。
  static bool get userEnabled => _user;

  /// 面板就这个开关给过真值（开或关都算）——引导窗口要不要成立、这份日志算不算"开启之后的"
  /// 都看它。
  static bool get panelAnswered => _panelAnswered;

  /// 测试缝：换掉 App Group 容器路径的来源（生产不动，跟 `DiagPending.dirProvider` 同一套）。
  static Future<String?> Function()? dirProvider;

  /// 把当前状态落到 `Library/tarn-diag-on.txt`：开着就写（内容是租约到期时间）、关着就删。
  ///
  /// 内核与扩展只看这个文件（正式版那条运行期线，业主选的 B），所以**状态一变就得写**。
  /// 以前只有 App 启动时写一次，于是"面板开了、用户只是更新订阅"要等下次重启 App 才开始采：
  /// 真机实测就是这个坑（2026-10-28 正式版 1.0.7+2026102802+47a5e28a，iPhone 14 —— 面板
  /// 19:56:35 说开、App 也把值存进本地偏好并算好了 7 天租约，但那个文件直到 20:19 重启才出现，
  /// 中间 23 分钟内核和 `[ext]` 全都还在"关"，一条没采，面板上一条报告也没有）。
  /// 启动那趟和订阅回来那趟都调它，写的都是同一个到期时间，重复调无害（内容幂等）。
  static Future<void> syncFlagFile() async {
    try {
      final String? p =
          await (dirProvider ?? VpnBridge.groupContainerPath)().timeout(
        const Duration(seconds: 3),
      );
      if (p == null || p.isEmpty) return;
      final File m = File('$p/Library/tarn-diag-on.txt');
      if (active) {
        m.parent.createSync(recursive: true);
        m.writeAsStringSync(flagFileContent, flush: true);
      } else if (m.existsSync()) {
        m.deleteSync();
      }
    } catch (_) {
      // 写不动就算了：启动那趟还会再写，内核与扩展也各自按文件里的到期时间自己停。
    }
  }

  /// 面板字段的类型随时会变（bool / 数字 / 字符串），一律宽松收口：
  /// true / 1 / "1" / "true" 为开，其余（含缺省 null 和解析不了的值）为关——
  /// 宁可少采不可多占，别把开关做成类型陷阱。
  static bool _truthy(Object? value) =>
      value == true || value == 1 || value == '1' || value == 'true';

  /// 应用 oss-config 的 `diag-logs`（全站远程开关）。
  ///
  /// 面板说开 = 续租约（从现在起 7 天）；说关 = 立刻收回租约（关掉，不等到期）。
  static void applyRemote(Object? value) {
    _remote = _truthy(value);
    // 面板回了真值（开或关都算）⇒ 引导窗口到此为止，之后一律按面板说的算。
    if (value != null) _markPanelAnswered();
    _applyLease(_remote || _user);
    _syncCollectWindow();
    // 开关文件要跟着这一刻变：内核和扩展不看订阅、只看这个文件（业主 2026-10-28：面板开了
    // 就得马上采，不该等用户重启 App）。
    unawaited(syncFlagFile());
  }

  /// 应用面板随 getSubscribe 下发的 `diag_report`（账号级开关）。
  ///
  /// 字段缺失即按关处理：说明这台面板还没这个功能，本地副本也该清掉，
  /// 免得残留的「开」让用户一直逐包落盘。
  static void applyUser(Object? value) {
    _user = _truthy(value);
    // 同 applyRemote：字段缺省（null）不算回答 —— 那种面板还没这个功能，我们其实什么都不知道，
    // 引导窗口该继续；回了 true/false 才算回答。
    if (value != null) _markPanelAnswered();
    _applyLease(_remote || _user);
    _syncCollectWindow();
    // 同上：订阅回来那一刻就把开关文件写/删掉，运行中更新订阅也马上开始（或停止）落盘。
    unawaited(syncFlagFile());
  }

  /// 面板说"开着"就把租约续到 now + 7 天；说"关"就收回（null）。
  /// 只有真拿到了面板的答复才走这里 —— 本地恢复不走，免得每次启动都自动续期、租约形同虚设。
  static void _applyLease(bool on) {
    if (on) {
      _collectUntilMs = DateTime.now().add(kCollectLease).millisecondsSinceEpoch;
    } else {
      _collectUntilMs = null;
    }
  }

  /// 采集窗口起点（面板/全站把采集打开的那一刻）。null 表示当前没有窗口。
  static DateTime? get collectFrom => _collectFromMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_collectFromMs!);

  /// 三个来源里任何一个把诊断从关推到开 ⇒ 记下这一刻作为采集起点；反过来关掉就结束窗口。
  ///
  /// 只认"沿"（从关到开的那一下），不认电平：面板每次下发都会调 applyUser，按电平就会把起点
  /// 一直往后推，等于永远采不到东西。
  static void _syncCollectWindow() {
    final bool now = active;
    if (now == _wasActive) return;
    _collectFromMs = now ? DateTime.now().millisecondsSinceEpoch : null;
    _wasActive = now;
    _persistCollectFrom();
  }

  static Future<void> _persistCollectFrom() => _persistDiagState();

  /// 把账号级开关存到本地（关的时候直接删 key，不留 false）。
  static Future<void> saveUserFlag(bool on) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (on) {
        await prefs.setBool(kUserFlagKey, true);
      } else {
        await prefs.remove(kUserFlagKey);
      }
    } catch (_) {
      // 存不下就算了：下一次 getSubscribe 还会再下发一遍。
    }
  }

  /// 启动时把本地状态读回来（在写 `Library/tarn-diag-on.txt` 之前调用）。
  ///
  /// 读回来的是「上次面板告诉我们的值 + 上次的租约」，**不算续期**（续期只在真拿到面板答复时发生）。
  /// 租约已经过期的话：当作关（并把这些陈旧 key 清掉）—— 用户下次更新订阅时面板会重新决定，
  /// 在那之前不再落盘。新装引导窗口在这里落地（第一次看到没有 kFirstSeenKey 就是首启）。
  static Future<bool> restoreUserFlag() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 首启标记：没有就是这个包第一次跑（卸载重装会重置）
      int? first = prefs.getInt(kFirstSeenKey);
      if (first == null) {
        first = DateTime.now().millisecondsSinceEpoch;
        await prefs.setInt(kFirstSeenKey, first);
      }
      _firstSeenMs = first;
      _panelAnswered = prefs.getBool(kPanelAnsweredKey) == true;
      // 引导窗口的口径只留一处（bootstrapActive）：首启 30 分钟内、且面板没回答过。
      final bool bootstrap = bootstrapActive;
      int? until = prefs.getInt(kCollectUntilKey);
      // 引导窗口自己的到期时间：至少撑到「首启 + 30 分钟」
      final int bootUntil = first + kBootstrapWindow.inMilliseconds;
      if (bootstrap && (until == null || until < bootUntil)) until = bootUntil;
      final bool expired = until == null ||
          DateTime.now().millisecondsSinceEpoch >= until;
      if (expired) {
        // 租约到期（或从来没有）⇒ 上次的「开」作废：清干净，等面板重新说
        _user = false;
        _collectUntilMs = null;
        _collectFromMs = null;
        await prefs.remove(kUserFlagKey);
        await prefs.remove(kCollectUntilKey);
        await prefs.remove(kCollectFromKey);
      } else {
        _collectUntilMs = until;
        _user = prefs.getBool(kUserFlagKey) == true;
        // 只有"账号级/全站开着"这条路径才带窗口；引导窗口自己开的也要有窗口起点，
        // 否则整包会把上一次安装留下的旧日志一起端过去。
        _collectFromMs = prefs.getInt(kCollectFromKey) ??
            (bootstrap ? first : null);
        if (_collectFromMs != null &&
            prefs.getInt(kCollectFromKey) == null) {
          await prefs.setInt(kCollectFromKey, _collectFromMs!);
        }
      }
      _wasActive = active; // 启动时已经是开了 ⇒ 沿用上次记的起点，不在启动这一下重记
    } catch (_) {
      // 读不到 prefs ⇒ 保持当前值，别把状态猜成开。
    }
    return _user;
  }

  static Future<void> _persistDiagState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final e in <String, int?>{
        kCollectFromKey: _collectFromMs,
        kCollectUntilKey: _collectUntilMs,
      }.entries) {
        if (e.value == null) {
          await prefs.remove(e.key);
        } else {
          await prefs.setInt(e.key, e.value!);
        }
      }
    } catch (_) {
      // 存不下就算了：本次运行里照常工作，下次启动按面板重新下发为准。
    }
  }

  /// 面板就这个开关回答过了（开或关都算）⇒ 引导窗口到此为止，并把这件事存本地，
  /// 下次启动不用再猜。存法跟采集窗口那两个 key 一样：存不下就算了，本次运行里照样生效。
  static void _markPanelAnswered() {
    if (_panelAnswered) return;
    _panelAnswered = true;
    _persistPanelAnswered();
  }

  static Future<void> _persistPanelAnswered() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kPanelAnsweredKey, true);
    } catch (_) {
      // 存不下就算了：下一次面板答复会再记一遍。
    }
  }

  /// 测试缝：把内部状态摆成任意组合（生产代码不调）。
  @visibleForTesting
  static void debugSetState({
    int? collectUntilMs,
    int? collectFromMs,
    int? firstSeenMs,
    bool? user,
    bool? remote,
    bool? panelAnswered,
  }) {
    _collectUntilMs = collectUntilMs;
    _collectFromMs = collectFromMs;
    _firstSeenMs = firstSeenMs;
    if (user != null) _user = user;
    if (remote != null) _remote = remote;
    if (panelAnswered != null) _panelAnswered = panelAnswered;
    _wasActive = active;
  }

  @visibleForTesting
  static void debugReset() {
    _remote = false;
    _user = false;
    _collectFromMs = null;
    _collectUntilMs = null;
    _firstSeenMs = null;
    _panelAnswered = false;
    _wasActive = false;
  }
}
