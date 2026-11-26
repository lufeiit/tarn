import 'dart:async';

import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/models/core.dart';
import 'package:flutter/foundation.dart';

import 'desktop/helper_client.dart';
import 'desktop/launcher.dart';
import 'desktop/lifecycle.dart';
import 'desktop/model.dart';
import 'desktop/rpc_client.dart';
import 'desktop/transport.dart';
import 'event.dart';
import 'interface.dart';
import 'ios_service.dart';
import 'method.dart';
import 'spill.dart';

class CoreService extends CoreHandlerInterface {
  static CoreService? _instance;

  final DesktopCoreLifecycleController _lifecycle;
  final CoreRpcChannel _rpcClient;
  late final StreamSubscription<DesktopCoreFailure> _crashSubscription;
  Future<CoreLifecycleResult>? _closeOperation;

  factory CoreService() {
    return _instance ??= CoreService._create();
  }

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  factory CoreService._create() {
    final address = system.isWindows ? windowsPipeName : unixSocketPath;
    final directLauncher = DirectCoreLauncher();

    final lifecycle = DesktopCoreLifecycle(
      transport: IpcCoreTransport(address: address),
      launcherResolver: HelperLauncherResolver(
        hasHelper: system.hasHelperService && !safeModeBuild,
        directLauncher: directLauncher,
        helperLauncher: HelperLauncher(helperClient),
        helperReady: () => helperClient.readiness(),
      ),
      verifyPeerPid: system.isWindows,
    );
    return CoreService._(
      lifecycle: lifecycle,
      rpcClient: CoreRpcClient(lifecycle.transport),
    );
  }

  @visibleForTesting
  CoreService.forTesting({
    required DesktopCoreLifecycleController lifecycle,
    required CoreRpcChannel rpcClient,
  }) : this._(lifecycle: lifecycle, rpcClient: rpcClient);

  CoreService._({
    required DesktopCoreLifecycleController lifecycle,
    required CoreRpcChannel rpcClient,
  }) : _lifecycle = lifecycle,
       _rpcClient = rpcClient {
    _crashSubscription = _lifecycle.crashEvents.listen((failure) {
      commonPrint.log(
        'Core session lost: $failure',
        logLevel: LogLevel.warning,
      );
      coreEventManager.sendEvent(
        CoreEvent(
          type: CoreEventType.crash,
          data: coreSessionLostMessage(failure.cause, currentAppLocalizations),
        ),
      );
    });
  }

  @override
  Future<CoreLifecycleResult> start() => _lifecycle.start();

  @override
  Future<CoreLifecycleResult> restart() => _lifecycle.restart();

  @override
  Future<CoreLifecycleResult> stop() => _lifecycle.stop();

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() async {
    try {
      return await _lifecycle.close();
    } finally {
      await _rpcClient.close();
      await _crashSubscription.cancel();
    }
  }

  @override
  Future<Object?> invokeMethod({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
    CoreResultModel? model,
  }) {
    return _rpcClient.invoke(
      method: method,
      arguments: arguments,
      timeout: timeout,
      model: model,
    );
  }
}

/// 桌面端走本地 Core 进程；iOS 走 PacketTunnel 扩展里的 Go 桥（CoreIos）。
/// 迁移自官方 v0.9.3 时漏了 iOS 分支，会让 CoreController 的 `coreService!`
/// 在 iOS 上直接抛 null check（表现为仪表盘骨架屏 + ProviderException）。
final coreService = system.isDesktop
    ? CoreService()
    : (system.isIOS ? CoreIos() : null);
