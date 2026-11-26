import 'dart:io';

import 'package:vpn_bridge/vpn_bridge.dart';

/// 没传出去的整包诊断日志：本地攒**最新一份**，下次能连上面板时补传一次。
///
/// 为什么要有（业主 2026-10-28：「1+2 可以做，但不能把扩展和内核储存撑爆」）：现在上报失败是
/// `catch (_) {}` 直接吞掉 —— 而「面板连不上」和「需要日志」往往是同一时刻，等用户能连上了，
/// 现场已经被后续日志挤掉了。攒一份就够（不是队列）：面板按 sha 去重，重复传同一份不会堆；
/// 攒最新一份比攒最旧一份有用（最新那份离故障最近）。
///
/// 储存上限（都是硬上限，宁可少攒不许撑爆）：
///   - 只有一份（新的盖掉旧的）；
///   - 正文超过 2MB 就砍到尾部 2MB 并在开头标注砍了多少（面板单包原始上限是 16MB，这里远不到）；
///   - 攒了超过 7 天还没传出去就丢掉：那份日志已经没有时效意义，不值得占地方。
class DiagPending {
  DiagPending._();

  static const String _fileName = 'diag-pending.txt';
  static const int maxBytes = 2 * 1024 * 1024;
  static const Duration maxAge = Duration(days: 7);

  /// 测试缝：换掉容器路径的来源（生产不动）。
  static Future<String?> Function()? dirProvider;

  static Future<File?> _file() async {
    try {
      final group = await (dirProvider ?? VpnBridge.groupContainerPath)();
      if (group == null || group.isEmpty) return null;
      final dir = Directory('$group/Library');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return File('$group/Library/$_fileName');
    } catch (_) {
      return null;
    }
  }

  /// 攒下这一份（盖掉上一份）。写失败就算了，不抛。
  static Future<void> save(String text, {required String source}) async {
    final f = await _file();
    if (f == null) return;
    try {
      String body = text;
      final int bytes = body.codeUnits.length;
      if (bytes > maxBytes) {
        // 按字符粗略砍尾（诊断包是文本，砍掉头部最旧的那几段可以接受）
        body = body.substring(body.length - maxBytes);
        body = '（本地攒包时超长，砍掉开头 ${bytes - maxBytes} 字节）\n$body';
      }
      await f.writeAsString(
        // 注意 \${body.length} 的写法：Dart 里 "$body.length" 会被解析成
        // "$body + 字面量 .length"（实测过：整段正文被塞进 meta 行、正文又原样再来一遍，
        // 文件直接翻倍）。插值取属性必须用花括号。
        '#saved=${DateTime.now().millisecondsSinceEpoch}\t$source\t${body.length}\n$body',
        flush: true,
      );
    } catch (_) {
      // 攒不下就算了：比让日志把容器撑爆重要。
    }
  }

  /// 读回攒着的那份（不存在 / 超过 7 天 / 读不动 ⇒ null）。
  static Future<DiagPendingReport?> load() async {
    final f = await _file();
    if (f == null) return null;
    try {
      if (!f.existsSync()) return null;
      final String all = await f.readAsString();
      final int nl = all.indexOf('\n');
      if (nl <= 0) return null;
      final List<String> meta = all.substring(0, nl).split('\t');
      if (meta.length < 3 || !meta[0].startsWith('#saved=')) {
        // 读不懂（版本不兼容、文件被截断）：丢掉，不许长期占地方。
        await f.delete();
        return null;
      }
      final int savedMs = int.tryParse(meta[0].substring(7)) ?? 0;
      if (savedMs == 0 ||
          DateTime.now().millisecondsSinceEpoch - savedMs >
              maxAge.inMilliseconds) {
        await f.delete();   // 过期：顺手删掉，别占地方
        return null;
      }
      return DiagPendingReport(
        savedAt: DateTime.fromMillisecondsSinceEpoch(savedMs),
        source: meta[1],
        text: all.substring(nl + 1),
      );
    } catch (_) {
      return null;
    }
  }

  /// 把攒着的那份补传一次：成功就删掉，还是传不出去就原样留着下次再试。
  ///
  /// **引导窗口那份直接扔掉、不补传**（业主 2026-10-28：「我只要我开启那一刻以后的日志」）：
  /// 那种包是面板还没就这个开关表过态时打的，内容又全在采集起点之前，传上去只会让人以为
  /// "开了采集就产出这份日志"——生产上收到的第一份（16:10 打、20:19 补传上来的那份 552 B）
  /// 就是这么一份，整页除了表头什么都没有。
  ///
  /// 补传的时机：App 启动时一趟，之后由 `IosService._reportDiagBundleAtStart` 照面板频控排
  /// 定时器补。以前只有冷启动才重试，于是被 429 挡下的那份能在设备上躺一夜。
  static Future<bool> retryOnce() async {
    final DiagPendingReport? r = await load();
    if (r == null) return false;
    if (isBootstrapBundle(r.text)) {
      await clear(); // 引导窗口那份不值得占地方
      return false;
    }
    // 工具型客户端不向任何服务端上传诊断：队列只作本地留痕，不发送。
    return false;
  }

  /// 这份是不是引导窗口打的：只看包头那行 `collect_reason=bootstrap`（不整包扫，表头就在最前面）。
  static bool isBootstrapBundle(String text) {
    const int head = 2048;
    final String h = text.length <= head ? text : text.substring(0, head);
    return h.contains('collect_reason=bootstrap');
  }

  static Future<void> clear() async {
    final f = await _file();
    if (f == null) return;
    try {
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }
}

class DiagPendingReport {
  const DiagPendingReport({
    required this.savedAt,
    required this.source,
    required this.text,
  });
  final DateTime savedAt;
  final String source;
  final String text;
}
