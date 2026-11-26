/// 整包上报的节奏：App 与面板的频控必须对齐。
///
/// 业主 2026-10-28：「app 和网站的上传频繁要同步，不能老是 429」。真机实测（正式版
/// 1.0.7+2026102802+47a5e28a，iPhone 14）：20:19:01 补传刚被面板收下，20:19:02 客户端紧接着
/// 又打一份新的上去，必然吃 `429 diag_report_too_often` —— 那份新日志只能留在本地，
/// 而当时它**不会自己重试**，要等下一次冷启动才有机会。
///
/// 面板对每个账号的最小上报间隔写在 `app/Http/Controllers/V1/User/DiagReportController.php`
/// 的 `THROTTLE_SECONDS`，现值随 `/user/getSubscribe` 以 `diag_report_gap`（秒）下发；客户端照这个
/// 值排上报：刚收下一份就别再打，吃了 429 就等空档过去自己补。面板没下发时才用兜底值。
library;

/// App 侧的上报节奏（进程内存态：面板每次下发都会重新告诉一遍，不必持久化）。
class DiagPace {
  DiagPace._();

  /// 面板没下发频控时的兜底间隔：面板现值 60 秒，这里加 5 秒余量——卡在边界上最容易吃 429。
  static const Duration kFallbackGap = Duration(seconds: 65);

  /// 下发的值超过这个上限一律不收：面板哪天改坏了也不至于把我们上报卡死。
  static const int kMaxGapSeconds = 3600;

  static Duration _gap = kFallbackGap;
  static DateTime? _lastAccepted;
  static bool _rateLimited = false;

  /// 收下面板下发的 `diag_report_gap`（秒）。非数字 / 越界都不动本地值（宁可保守）。
  static void setGapSeconds(Object? value) {
    final int? s = value is int ? value : int.tryParse('${value ?? ''}');
    if (s == null || s <= 0 || s > kMaxGapSeconds) return;
    _gap = Duration(seconds: s);
  }

  /// 当前生效的最小间隔（排重试时用它算要等多久）。
  static Duration get gap => _gap;

  /// 面板收下了一份：从这里开始重新计时，并且认为"上一次不是被频控挡的"。
  static void markAccepted() {
    _lastAccepted = DateTime.now();
    _rateLimited = false;
  }

  /// 最近一次上传被频控挡住了（HTTP 429）：这份日志没丢，只是现在不能传 ⇒ 该排一次自动补传。
  static void markRateLimited() => _rateLimited = true;

  /// 最近一次上传是不是被频控挡的。
  static bool get rateLimited => _rateLimited;

  /// 距离下一次能传还差多久；null = 现在就能传（从没传过也算能传）。
  static Duration? nextDelay() {
    final DateTime? at = _lastAccepted;
    if (at == null) return null;
    final Duration left = _gap - DateTime.now().difference(at);
    return left.isNegative ? null : left;
  }

  /// 现在能不能传（[nextDelay] 为 null 的便捷写法）。
  static bool canUploadNow() => nextDelay() == null;

  /// 回到「从没传过、面板没下发过」的初始态（测试用）。
  static void resetForTest() {
    _gap = kFallbackGap;
    _lastAccepted = null;
    _rateLimited = false;
  }
}
