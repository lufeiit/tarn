import 'dart:async';
import 'dart:io';

import 'package:tarn/bootstrap.dart';
import 'package:tarn/core/ios_service.dart';
import 'package:tarn/common/common.dart';
import 'package:tarn/common/window.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/l10n/l10n.dart';
import 'package:tarn/manager/hotkey_manager.dart';
import 'package:tarn/manager/manager.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/plugins/app.dart';
import 'package:tarn/providers/providers.dart';
import 'package:tarn/state.dart';
import 'package:tarn/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart' show NetworkState;
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(NetworkState state) onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(child: ThemeManager(child: platformState)),
  );
}


class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application>
    with WidgetsBindingObserver {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    super.initState();
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      unawaited(_resetUnfoldDefault());
      unawaited(_applySettingsDefaults());
      unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
      unawaited(_enforceEncryptedProfiles());
      _initLink();
      unawaited(_refreshProviderProfile());
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  /// 一次性把「展开的分组」清空：代理页默认不展开第一个分组。
  /// 只执行一次，之后用户自己展开的状态照常保留。
  Future<void> _resetUnfoldDefault() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('lfexp_unfold_reset_v1') ?? false) return;
      final profiles = ref.read(profilesProvider);
      final notifier = ref.read(profilesProvider.notifier);
      for (final profile in profiles) {
        if (profile.unfoldSet.isEmpty) continue;
        notifier.put(profile.copyWith(unfoldSet: const {}));
      }
      await prefs.setBool('lfexp_unfold_reset_v1', true);
    } catch (_) {}
  }

  /// 一次性把这一版约定的默认设置落到已有安装上：
  /// IPv6、统一延迟、TCP 并发打开并在「核心」覆盖里默认展示；拥塞控制 bbr；
  /// 始终查找进程；仅统计代理流量。只执行一次，之后用户自己的选择保留。
  Future<void> _applySettingsDefaults() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('lfexp_settings_defaults_v1') ?? false) return;
      ref
          .read(patchClashConfigProvider.notifier)
          .update(
            (state) => state.copyWith(
              ipv6: true,
              unifiedDelay: true,
              tcpConcurrent: true,
              findProcessMode: FindProcessMode.always,
              tun: state.tun.copyWith(
                congestionController: defaultCongestionController,
              ),
              generalOverrideKeys: {
                ...state.generalOverrideKeys,
                GeneralOverrideKey.unifiedDelay,
                GeneralOverrideKey.tcpConcurrent,
                GeneralOverrideKey.ipv6,
                GeneralOverrideKey.geodataLoader,
              },
            ),
          );
      ref
          .read(appSettingProvider.notifier)
          .update(
            (state) => state.copyWith(onlyStatisticsProxy: true),
          );
      await prefs.setBool('lfexp_settings_defaults_v1', true);
    } catch (_) {}
  }

  /// 启动自愈：带 lfexp 节点的订阅在磁盘上必须是密文。
  ///
  /// 覆盖三种来源：旧版本升级上来的明文、备份恢复、以及只写了文件还没来得及
  /// 加密的情况。文件还没下载过就顺手拉一次，否则内核拿不到内容。
  Future<void> _enforceEncryptedProfiles() async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    for (final profile in ref.read(profilesProvider)) {
      final mFile = await profile.file;
      if (!await mFile.exists()) {
        unawaited(profilesAction.updateProfile(profile));
        continue;
      }
      if (await ProfileContentCipher.isEncrypted(mFile)) continue;
      final plain = await profile.readPlaintext();
      if (plain == null) continue;
      if (!plain.contains('type: lfexp') &&
          !plain.contains('type: "lfexp"') &&
          !plain.contains("type: 'lfexp'")) {
        continue;
      }
      await ProfileContentCipher.encryptInPlace(mFile, profile.id);
    }
  }

  /// 服务商档案的远程刷新（码里带 base 时生效），失败静默。
  Future<void> _refreshProviderProfile() async {
    await RemoteConfig.loadCached();
    final provider = await ProviderStore.current();
    if (provider == null) return;
    await ProviderStore.refreshIfNeeded(provider);
    final configUrl = provider.configUrl;
    if (configUrl != null && configUrl.isNotEmpty) {
      await RemoteConfig.refresh(configUrl);
    }
  }

  void _initLink() {
    linkManager.initAppLinksListen((uri) async {
      // 配置码：clash://install-config?url=...&name=...&key=...
      // key 是可选的用户派生密钥，有它才能解面板的加密订阅。
      final target = installConfigTarget(uri);
      if (target == null) return;

      if (target.code != null) {
        final parsed = await AccessCode.parseVerified(target.code!);
        AccessCodeResult? resolved;
        var failure = '配置码无效，请重新获取。';
        try {
          resolved = await parsed?.exchange();
        } on AccessCodeException catch (error) {
          failure = error.message;
        }
        if (!mounted) return;
        if (resolved == null || !resolved.url.isUrl) {
          unawaited(
            dialogs.showMessage(
              title: currentAppLocalizations.addProfile,
              message: TextSpan(text: failure),
            ),
          );
          return;
        }
        if (resolved.key case final key? when key.isNotEmpty) {
          await SubscribeSite.saveSiteKey(resolved.url, key);
        }
        if (!mounted) return;
        unawaited(window?.show());
        unawaited(
          ref
              .read(profilesActionProvider.notifier)
              .addProfileFromLink(resolved.url, label: resolved.name),
        );
        return;
      }

      final url = target.url;
      final providerName = target.name;
      unawaited(window?.show());
      final message = currentAppLocalizations.createProfileFromUrlTip(url);
      final parts = message.split(url);
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: parts.first),
            TextSpan(
              text: url,
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ],
        ),
      );
      if (res != true || !mounted) return;
      if (target.key case final key?) {
        await SubscribeSite.saveSiteKey(url, key);
      }
      if (providerName != null) {
        final host = Uri.tryParse(url)?.host ?? 'provider';
        await ProviderStore.upsert(
          ProviderProfile(
            id: target.provider ?? host,
            name: providerName,
            logo: target.logo,
            home: target.home,
            faq: target.faq,
            customerService: target.cs,
            notice: target.notice,
            themeColor: target.theme,
            baseUrl: target.base,
            configUrl: target.config,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      if (!mounted) return;
      unawaited(
        ref
            .read(profilesActionProvider.notifier)
            .addProfileFromLink(
              url,
              label: target.name,
            ),
      );
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      await ref.read(mitmModulesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(NetworkState state) async {
    commonPrint.log(
      'connectivityChanged wifi: ${state.wifi} vpn: ${state.vpn}',
    );
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    final hasVpn = state.vpn;
    if (_preHasVpn == hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      // Android's NetworkObserver tells the Core about a new network itself.
      if (system.isDesktop) {
        debouncer.call(
          FunctionTag.networkChange,
          ref.read(coreActionProvider.notifier).reportNetworkChange,
          duration: const Duration(milliseconds: 200),
        );
      }
    }
    _preHasVpn = hasVpn;
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        final textScale = themeProps.textScale;
        return PrismApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            appLocalizationsDelegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            return buildManagerStack(
              isDesktop: system.isDesktop,
              onConnectivityChanged: _handleConnectivityChanged,
              terminateSignals: _terminateSignals,
              child: child!,
            );
          },
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          textScale: textScale.enable ? textScale.scale : null,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          liquidGlass: switch (themeProps.liquidGlass) {
            LiquidGlassMode.none => null,
            LiquidGlassMode.ultra => LiquidGlassQuality.ultra,
            LiquidGlassMode.standard => LiquidGlassQuality.standard,
          },
          emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
          stackedBanners: !ref.watch(isMobileViewProvider),
          bannerTopInset: ref.watch(overlayTopOffsetProvider),
          remoteFocus: system.isTV,
          floatingKeyboard: app?.floatingKeyboard,
          onGenerateRoute: (settings) => HomeRoute(
            settings: settings,
            builder: (_) => KeyboardInsetHold(child: child!),
          ),
        );
      },
      child: const HomePage(),
    );
  }

  // ── 回前台自救（2026-11-18）───────────────────────────────────────────────
  // iOS 息屏/切网回前台后常见「只发不收」：隧道显示已连接但页面打不开。
  // 延迟 5s 再触发，避开系统网络切换的短暂抖动；内核侧按连接做判定，
  // 没有命中就不会动任何连接。
  Timer? _unlockGuardTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (!Platform.isIOS) return;
    if (state == AppLifecycleState.resumed) {
      _unlockGuardTimer?.cancel();
      _unlockGuardTimer = Timer(const Duration(seconds: 5), () {
        unawaited(runIosUnlockGuard());
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _unlockGuardTimer?.cancel();
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}
