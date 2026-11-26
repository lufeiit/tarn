import 'package:yaml/yaml.dart';

class SubscriptionDelayDisplay {
  const SubscriptionDelayDisplay({
    this.minLatencyThresholdMs = 0,
    this.latencyReductionPct = 0,
    this.maxLatencyDisplayMs = 0,
  });

  final int minLatencyThresholdMs;
  final int latencyReductionPct;
  final int maxLatencyDisplayMs;

  static SubscriptionDelayDisplay fromYaml(String text) {
    if (!text.contains('lfexp-delay-display')) {
      return const SubscriptionDelayDisplay();
    }
    try {
      final document = loadYaml(text);
      final policy = document is Map ? document['lfexp-delay-display'] : null;
      if (policy is! Map) return const SubscriptionDelayDisplay();
      int read(String key, int max) {
        final value = policy[key];
        final parsed = switch (value) {
          int v => v,
          String v => int.tryParse(v.trim()) ?? 0,
          _ => 0,
        };
        return parsed >= 0 && parsed <= max ? parsed : 0;
      }

      return SubscriptionDelayDisplay(
        minLatencyThresholdMs: read('minLatencyThresholdMs', 65535),
        latencyReductionPct: read('latencyReductionPct', 100),
        maxLatencyDisplayMs: read('maxLatencyDisplayMs', 65535),
      );
    } on YamlException {
      return const SubscriptionDelayDisplay();
    }
  }

  /// 只改显示值，不动真实测速与选路（与桌面 displayDelay 同一套口径）。
  ///
  /// [seed] 用于封顶后的稳定抖动：触顶的节点不能都显示同一个数字，
  /// 同一节点每次一致、不同节点不同。
  int apply(int ms, {String? seed}) {
    if (ms <= 0) return ms;
    if (minLatencyThresholdMs > 0 && ms < minLatencyThresholdMs) return 0;
    var shown = ms;
    if (latencyReductionPct > 0) {
      shown = (ms * (100 - latencyReductionPct) / 100).round();
    }
    if (shown < 0) shown = 0;
    if (maxLatencyDisplayMs > 0 && shown > maxLatencyDisplayMs) {
      final spread = maxLatencyDisplayMs * 15 ~/ 100;
      if (spread <= 0) {
        shown = maxLatencyDisplayMs;
      } else {
        var hash = 0;
        for (final code in (seed ?? ms.toString()).codeUnits) {
          hash = (hash * 31 + code) & 0x7fffffff;
        }
        shown = maxLatencyDisplayMs - hash % (spread + 1);
      }
    }
    return shown;
  }
}
