/// iOS 一键诊断包（2026-10-26）。
///
/// 背景：用户反馈「登不上 / 订阅拉不到 / 节点连不上」时，我们只能靠真机日志排查，
/// 而日志分散在四处、各有各的门槛：
///  - 日志页（内存环形 1000 条）：用户能导出，但没有内核 / 扩展侧的信息；
///  - App Group Library/logs/app.log：只有我们用 devicectl 拉得到，用户拿不到；
///  - App Group extDiag.txt（内核 logf + 扩展诊断）：同上，且可能涨到 4.5 MB；
///  - Documents/vpnlog.txt（扩展看门狗 / 自愈）：同上，且只有诊断版在写。
/// 这里把它们收成一个 txt（外加一份适合发微信的短摘要），用户点一下就能给我们。
///
/// 脱敏：整包逐行走 SensitiveDomains.maskAll（像主机名的串、IP 后两段、端口、token、
/// 设备 UUID、邮箱一律打掩）——诊断包会离开设备，这一步不能省。**开关跟着开发者模式的
/// 「调试明文」走**（默认开=掩码；关掉时整包也是明文，包头 `log_mask=off` 那行写清了当时
/// 是哪种，见 common/log_mask_mode.dart）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:tarn/common/device_id.dart';
import 'package:tarn/common/sensitive_domain.dart';
import 'package:tarn/core/ios_diag_flag.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vpn_bridge/vpn_bridge.dart';

/// 内核 / 扩展诊断行的关键字（日志页摘要与诊断包共用一份，避免两处漂移）。
///
/// 后一半是**失败类**标记（2026-10-26 补）：排查时最想看到的不是「起来了」而是
/// 「为什么没连上」，内核的失败行就是这个措辞。
const List<String> kKernelDigestKeys = [
  'kernel-limits',
  'app-params',
  '[LFEXP]',
  'mem-guard',
  'wire v2',
  '[ext] startTunnel',
  'timeout',
  'refused',
  'TLS handshake',
  'no such host',
  'lookup ',
  'connection reset',
  'unexpected status',
  'rejected',
  // 扩展侧测速窗口行（core/ios_speedsampler.go，2026-10-28）。必须靠关键字捞：诊断包里
  // extDiag 只带尾部 120 行，而测速那几分钟内核正在哗哗写日志，等测速跑完，测速行早被
  // 挤出 120 行之外了。日志页（views/logs.dart）也是用这张表把内核行投到 App 日志里的，
  // 加在这里等于"手机上能看到 + 发给我们的包里有"两处一起到位。
  '[SPEEDTEST]',
];

/// 读 App Group extDiag.txt，从**尾部**往前挑关键行（按时间正序返回）。
///
/// 必须从尾部扫：这文件能涨到 4.5 MB，而要看的行（本轮启动的参数指纹、最近一次失败）
/// 在尾部；从头部取 4 KB 只会拿到上一次启动时的行。
Future<List<String>> collectKernelDigestLines({
  int maxLines = 40,
  DateTime? since,
}) async {
  try {
    final raw = await VpnBridge.readExtLog().timeout(
      const Duration(seconds: 3),
    );
    if (raw.isEmpty) return const [];
    final lines = raw.split('\n');
    final picked = <String>[];
    for (var i = lines.length - 1; i >= 0 && picked.length < maxLines; i--) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (!kKernelDigestKeys.any((key) => line.contains(key))) continue;
      // 起点之前的一律不算：extDiag 能跨启动留着上一次诊断包的行，混进来就像今天的问题。
      if (since != null) {
        final DateTime? st = parseLogStamp(line);
        if (st != null && st.isBefore(since)) continue;
      }
      picked.add(line.length > 300 ? line.substring(0, 300) : line);
    }
    return picked.reversed.map(SensitiveDomains.maskAll).toList();
  } catch (_) {
    return const [];
  }
}

/// 认两种日志时间前缀，返回**本机时间轴**上的时刻（认不出返回 null）。
///
///  - App 日志：`2026-10-27T01:30:28.427143 [APP] …` —— 不带偏移，按本机时间理解；
///  - 扩展 / 内核：`[2026-10-28 05:18:14 +0800] [ext] …` 或 `2026-10-28 05:18:14 +0800 …`
///    —— 2026-10-28 起两侧时间基统一成设备本机带偏移（以前 iOS 侧写 UTC，同一个包里两种时间
///    混排），带偏移的先化成 UTC 瞬间再转回本机时区，才能跟 App 的行放在同一条起点线上比。
/// 偏移只在行首 32 个字符里找：整行里 `+08:00` 这种串也可能出现在正文（端口、路径），
/// 全文找会认错。
DateTime? parseLogStamp(String line) {
  // 行首允许最多 3 个 `[tag]` 再遇到时间戳：内核自己写的行是
  // `[LFEXP] [2026-10-28 17:38:20.777 +0800] reality handshake …` —— 时间戳在第二个括号里。
  // 真机实测（2026-10-28 21:19 那份包）：collect_from=19:56:35，摘要里却带着一整批 17:38 的
  // [LFEXP] 行 ⇒ 这些行以前被当成"没有时间戳的行"跟着上一行走，**所有窗口过滤都没拦住它们**。
  // 括号里的内容必须是纯 tag 字符（不含空格/冒号），所以 `[2026-10-28 05:18:14 +0800]` 这种
  // 时间戳自带括号的行不会被误当 tag 吃掉，老格式的解析路径一字不变。
  final m = RegExp(
    r'^\s*(?:\[[A-Za-z0-9_.\-]+\]\s*){0,3}\[?(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(line);
  if (m == null) return null;
  try {
    final int y = int.parse(m.group(1)!);
    final int mo = int.parse(m.group(2)!);
    final int d = int.parse(m.group(3)!);
    final int h = int.parse(m.group(4)!);
    final int mi = int.parse(m.group(5)!);
    final int sec = int.parse(m.group(6)!);
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    final String head = line.length > 32 ? line.substring(0, 32) : line;
    final off = RegExp(r'([+-])(\d{2}):?(\d{2})').firstMatch(head);
    if (off != null) {
      final int sign = off.group(1) == '-' ? -1 : 1;
      final Duration o = Duration(
        hours: int.parse(off.group(2)!) * sign,
        minutes: int.parse(off.group(3)!) * sign,
      );
      return DateTime.utc(y, mo, d, h, mi, sec).subtract(o).toLocal();
    }
    return DateTime(y, mo, d, h, mi, sec);
  } catch (_) {
    return null;
  }
}

/// 按采集起点过滤日志行（起点为 null 时原样返回）。
///
/// 没有时间的行（上一条被截断的续行、内核多行崩溃栈等）**跟着上一行的去留**，不单独判定：
/// 否则一份日志会被从中间啃掉几块，反而更难读。
class DiagSinceFilter {
  const DiagSinceFilter(this.kept, this.stale, this.followDeleted);
  final List<String> kept;
  final int stale;         // 时间戳早于采集起点，被排除的行数（写进段标题的那个数）
  final int followDeleted; // 没有时间戳、跟着上一行被删的续行数（不算"起点之前"）
}

DiagSinceFilter filterSince(List<String> lines, DateTime? since) {
  if (since == null) return DiagSinceFilter(lines, 0, 0);
  final List<String> kept = <String>[];
  int stale = 0, follow = 0;
  bool prevKept = false, seenStamp = false;
  for (final String l in lines) {
    final DateTime? st = parseLogStamp(l);
    if (st == null) {
      if (!seenStamp || prevKept) {
        kept.add(l);
      } else {
        follow++;
      }
      continue;
    }
    seenStamp = true;
    if (st.isBefore(since)) {
      stale++;
      prevKept = false;
    } else {
      kept.add(l);
      prevKept = true;
    }
  }
  return DiagSinceFilter(kept, stale, follow);
}

/// 起点那行（给包头用）：带本机偏移，跟日志行的时间轴一致，好直接比对。
String diagSinceStamp(DateTime? since) {
  if (since == null) return 'none（当前没有采集窗口：本包只是这台设备最近日志的尾部）';
  final DateTime local = since.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final Duration off = local.timeZoneOffset;
  final int sign = off.isNegative ? -1 : 1;
  final Duration a = off.abs();
  final String hhmm =
      '${sign >= 0 ? '+' : '-'}${two(a.inHours)}${two(a.inMinutes % 60)}';
  return '${local.year}-${two(local.month)}-${two(local.day)}'
      'T${two(local.hour)}:${two(local.minute)}:${two(local.second)}$hhmm';
}

/// 取文件尾部 N 行（诊断文件都可能很大，只要最新的；超量只读尾部 512 KB）。
///
/// 有采集起点时先多取 4 倍再过滤，免得尾部整段都在起点之前、过滤完什么都不剩。
List<String> _tailLines(String path, int maxLines, {DateTime? since}) {
  const maxBytes = 512 * 1024;
  try {
    final f = File(path);
    if (!f.existsSync()) return const [];
    final len = f.lengthSync();
    if (len == 0) return const [];
    final readFrom = len > maxBytes ? len - maxBytes : 0;
    final raf = f.openSync(mode: FileMode.read);
    String text;
    try {
      raf.setPositionSync(readFrom);
      text = utf8.decode(raf.readSync(len - readFrom), allowMalformed: true);
    } finally {
      raf.closeSync();
    }
    final lines = text.split('\n');
    if (lines.isNotEmpty && lines.last.trim().isEmpty) lines.removeLast();
    // 从中间截断时首行是半行，丢掉（读到的字节远多于需要的行数，不心疼）
    if (readFrom > 0 && lines.length > 1) lines.removeAt(0);
    final List<String> pool = since == null
        ? lines
        : (lines.length > maxLines * 4
            ? lines.sublist(lines.length - maxLines * 4)
            : lines);
    // 名字别叫 f：这个函数里 f 已经是那个 File 句柄了。
    final DiagSinceFilter flt = filterSince(pool, since);
    final List<String> out = flt.kept.length > maxLines
        ? flt.kept.sublist(flt.kept.length - maxLines)
        : flt.kept;
    _lastSkipped += flt.stale;
    return out.map(SensitiveDomains.maskAll).toList();
  } catch (_) {
    return const [];
  }
}

/// 上一段因「在采集起点之前」被排除的行数：拼在该段标题上，让看的人知道少在哪、不是没发生。
/// 每读一段之前先 resetSkip()，别把两段的数累到一起。
int _lastSkipped = 0;

void resetSkip() => _lastSkipped = 0;

String skipNote() =>
    _lastSkipped > 0 ? '（采集起点之前排除 $_lastSkipped 行）' : '';

/// 内核（core/Clash.Meta）的版本：CI 以 `--dart-define=CORE_VERSION=<commit>` 传进来，写进诊断包
/// 包头并填进面板的 `core_version` 列。本地手构建没传就是空串、包里写 `-` —— 不猜，免得把上一
/// 次的 commit 当成本次的（真机出问题时"哪一版内核"是第一要问的东西）。
const String kCoreVersion = String.fromEnvironment('CORE_VERSION');

/// 诊断头部：版本 / 构建号 / 诊断开关状态 / 系统版本 / 设备指纹前缀。
///
/// 这三行决定我们拿到日志后的第一判断——正式版还是诊断版、远程开关有没有生效、
/// 是不是这台设备（指纹前缀与面板侧对得上才对得上账号）。
Future<String> _diagHeader({required String appName}) async {
  String version = '?', build = '?';
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
    build = info.buildNumber;
  } catch (_) {}
  String id = '', legacy = '';
  try {
    id = await getLocalDeviceId();
    legacy = await getLegacyDeviceId();
  } catch (_) {}
  final head = <String>[
    'app=$appName version=$version(${build.isEmpty ? '-' : build})',
    // 打包时刻（本机时区、与日志行同一套写法）。面板那边只有"到达时间"，于是几小时前装的包
    // 补传上来之后长得像刚采的 —— 业主 2026-10-28 问「我开关是 20 点以后开的，为什么会是
    // 16:10 的」，差的就是这个：这份是 16:10 打包、20:19 才补传上来的。
    'build_at=${diagSinceStamp(DateTime.now())}',
    // 哪一版内核（CI 传入，见 kCoreVersion）：面板库里有 core_version 这一列，以前客户端没送。
    'core_version=${kCoreVersion.isEmpty ? '-' : kCoreVersion}',
    'release_mode=${kReleaseMode ? 'release' : 'debug'} diag_build=$iosDiag diag_active=${DiagPolicy.active} diag_remote=${DiagPolicy.remoteEnabled}',
    'os=${Platform.operatingSystem}-${Platform.operatingSystemVersion}',
    'device_id=${id.isEmpty ? '-' : id.substring(0, id.length > 12 ? 12 : id.length)}… src=${deviceIdDerivationSource()} legacy=${legacy.isEmpty ? '-' : legacy.substring(0, legacy.length > 12 ? 12 : legacy.length)}…',
    // 收这份报告的人要先知道它是脱敏的还是明文的（开发者模式的「调试明文」开着时整包明文）。
    'log_mask=${SensitiveDomains.maskEnabled ? 'on（已脱敏）' : 'off（本机被下了调试明文指令，本包为明文）'}',
    // 起点决定「这一包里哪些行算数」：面板把这台账号的采集打开的那一刻起算，关掉就结束。
    // 没起点 = 从没开过采集（手动导出的诊断包走这条），那本包只代表"最近日志的尾部"。
    'collect_from=${diagSinceStamp(DiagPolicy.collectFrom)}',
    'collect_reason=${DiagPolicy.collectReason}',
    'collect_until=${diagSinceStamp(DiagPolicy.collectUntilNullable)}',
  ];
  return SensitiveDomains.maskAll(head.join('\n'));
}

String _tailFromList(List<String> lines, int maxLines, {DateTime? since}) {
  _lastSkipped = 0;
  final List<String> pool = since == null
      ? lines
      : (lines.length > maxLines * 4
          ? lines.sublist(lines.length - maxLines * 4)
          : lines);
  final DiagSinceFilter flt = filterSince(pool, since);
  final List<String> out = flt.kept.length > maxLines
      ? flt.kept.sublist(flt.kept.length - maxLines)
      : flt.kept;
  _lastSkipped = flt.stale;
  return out.map(SensitiveDomains.maskAll).join('\n');
}

Future<String> _groupFile(String relative) async {
  try {
    final group = await VpnBridge.groupContainerPath();
    if (group == null || group.isEmpty) return '';
    return '$group/Library/$relative';
  } catch (_) {
    return '';
  }
}

Future<String> _documentsFile(String relative) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$relative';
  } catch (_) {
    return '';
  }
}

/// 一键诊断包正文（逐行已脱敏，可直接发给运维 / 我们）。
Future<String> buildDiagBundle({
  required String appName,
  required List<String> memoryLines,
  int appLogLines = 1500,
  int memoryTailLines = 400,
  int vpnlogLines = 300,
  int extDiagTailLines = 120,
}) async {
  final DateTime? since = DiagPolicy.collectFrom;
  final b = StringBuffer()..writeln(await _diagHeader(appName: appName));

  // 每段都是「先读正文、再写标题」：StringBuffer 的级联从左往右跑，正文里那个"排除多少行"
  // 的计数要读 complete 才知道，标题跟正文写在同一个级联里就会拿到上一段的数。
  resetSkip();
  final String digestBody =
      (await collectKernelDigestLines(since: since)).join('\n');
  b
    ..writeln('==== 内核 / 扩展诊断摘要（App Group extDiag 关键行）====')
    ..writeln(digestBody);

  final String extDiag = await _groupFile('extDiag.txt');
  resetSkip();
  final String extBody = extDiag.isEmpty
      ? '（读不到 App Group 容器）'
      : _tailLines(extDiag, extDiagTailLines, since: since).join('\n');
  final String extNote = skipNote();
  b
    ..writeln()
    ..writeln('==== extDiag 尾部 $extDiagTailLines 行$extNote ====')
    ..writeln(extBody);

  final String appLog = await _groupFile('logs/app.log');
  resetSkip();
  final String appBody = appLog.isEmpty
      ? '（读不到）'
      : _tailLines(appLog, appLogLines, since: since).join('\n');
  final String appNote = skipNote();
  b
    ..writeln()
    ..writeln('==== App 日志（App Group Library/logs/app.log 尾部）$appNote ====')
    ..writeln(appBody);

  resetSkip();
  final String memBody = _tailFromList(memoryLines, memoryTailLines, since: since);
  final String memNote = skipNote();
  b
    ..writeln()
    ..writeln('==== 日志页当前内容（尾部 $memoryTailLines 条）$memNote ====')
    ..writeln(memBody);

  final String vpnlog = await _documentsFile('vpnlog.txt');
  resetSkip();
  final String vpnBody = vpnlog.isEmpty
      ? '（读不到）'
      : _tailLines(vpnlog, vpnlogLines, since: since).join('\n');
  final String vpnNote = skipNote();
  b
    ..writeln()
    ..writeln('==== Documents/vpnlog.txt 尾部$vpnNote ====')
    ..writeln(vpnBody);

  return b.toString();
}

/// 适合发微信 / 直接贴给我们的短摘要（手机上看得不长的那一版）。
Future<String> buildDiagSummary({
  required String appName,
  required List<String> memoryLines,
  int memoryTailLines = 25,
}) async {
  final b = StringBuffer()..writeln(await _diagHeader(appName: appName));
  final digest = await collectKernelDigestLines(maxLines: 12);
  b
    ..writeln()
    ..writeln('---- 内核 / 扩展关键行 ----')
    ..writeln(digest.isEmpty ? '（无）' : digest.join('\n'))
    ..writeln()
    ..writeln('---- 最近 $memoryTailLines 条日志 ----')
    ..writeln(_tailFromList(memoryLines, memoryTailLines));
  return b.toString();
}

/// 诊断包的默认文件名（品牌 + 版本 + 时间，多设备/多次导出好区分）。
Future<String> diagBundleFileName({required String appName}) async {
  String version = 'unknown';
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {}
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final ts =
      '${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}';
  return 'diag-$appName-$version-$ts.txt';
}
