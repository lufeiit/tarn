/// 真机自测「用户视角」汇总行的格式，唯一权威定义。
///
/// App 侧（`ios_service.dart` 写这一行）与 CI 判定器（`scripts/ios_selftest_verify.py`
/// 读这一行）都对它的形状有依赖，而 Python 那边改解析规则**不会通知 Dart 这边**。所以把
/// 格式钉在单测里（`test/core/ios_selftest_report_test.dart`）：任何一边改了，CI 当场红，
/// 而不是等真机跑完十几分钟才发现「判定器读不到汇总行」。
///
/// 形状：`selftest RESULT k1=v1 k2=v2 ...`，字段之间单空格，值里一律不含空格。
const String kSelfTestResultPrefix = 'selftest RESULT';

/// 汇总行的退出方式。判定器按它区分「跑完了」「没连上就撤了」「保留隧道撤的」。
const String kSelfTestExitConnectAbort = 'connect_abort';
const String kSelfTestExitDone = 'done';
const String kSelfTestExitDoneKeepVpn = 'done_keep_vpn';

/// 组装一行汇总。[fields] 的插入顺序即输出顺序（Dart 的 Map 保序），
/// 判定器和人读日志都更稳；值里的空白统一换成 `_`，否则会被按空白切成两个字段。
String selfTestSummaryLine({
  required String exit,
  required Map<String, String> fields,
}) {
  final parts = <String>['exit=$exit'];
  fields.forEach((key, value) {
    parts.add('$key=${sanitizeSelfTestField(value)}');
  });
  return '$kSelfTestResultPrefix ${parts.join(' ')}';
}

/// 把值里所有空白压成 `_`（判定器按空白切字段）。
String sanitizeSelfTestField(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), '_');

/// 解析汇总行 → 字段表；不是汇总行返回 null。
/// 目前只有单测用（生产侧的解析在 Python 判定器里），留着它是为了能在单测里做往返校验。
Map<String, String>? parseSelfTestSummaryLine(String line) {
  final trimmed = line.trim();
  if (!trimmed.startsWith('$kSelfTestResultPrefix ')) return null;
  final out = <String, String>{};
  for (final part in trimmed.substring(kSelfTestResultPrefix.length + 1).split(' ')) {
    if (part.isEmpty) continue;
    final i = part.indexOf('=');
    if (i <= 0) continue;
    out[part.substring(0, i)] = part.substring(i + 1);
  }
  return out;
}
