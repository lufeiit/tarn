import 'dart:async';

import 'package:tarn/common/common.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/providers/action.dart';
import 'package:tarn/providers/app.dart';
import 'package:tarn/providers/state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/banner.dart';

class VpnManager extends ConsumerStatefulWidget {
  final Widget child;

  const VpnManager({super.key, required this.child});

  @override
  ConsumerState<VpnManager> createState() => _VpnContainerState();
}

class _VpnContainerState extends ConsumerState<VpnManager> {
  @override
  void initState() {
    super.initState();
    ref.listenManual(
      vpnOptionsProvider.select((state) => state.value),
      (prev, next) {
        final running = ref.read(runningVpnOptionsProvider);
        if (next == null || running == null) {
          return;
        }
        // iOS 的 VPN 开关直接拉起/断开隧道，enable 的变化本身就是生效动作，
        // 不该再弹「配置已改动，点击重启」；其余 VPN 选项变化仍照旧提示。
        if (system.isIOS &&
            next.copyWith(enable: true) == running.copyWith(enable: true)) {
          return;
        }
        if (prev?.effective != next.effective &&
            running.effective != next.effective) {
          _showRestartTip();
        }
      },
    );
  }

  void _showRestartTip() {
    dialogs.showBanner(
      currentAppLocalizations.vpnConfigChangeDetected,
      level: BannerLevel.warning,
      onTap: () {
        unawaited(ref.read(setupActionProvider.notifier).restartVpn());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
