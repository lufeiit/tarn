import 'dart:async';

import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/providers/providers.dart';
import 'package:tarn/state.dart';
import 'package:tarn/ui/icons/icons.dart';
import 'package:tarn/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class AboutView extends ConsumerWidget {
  const AboutView({super.key});

  Future<void> _checkUpdate(BuildContext context, WidgetRef ref) async {
    if (ref.read(loadingProvider(LoadingTag.checkUpdate))) return;
    final commonAction = ref.read(commonActionProvider.notifier);
    final result = await globalState.loadingRun(
      () async => (release: await request.checkForUpdate()),
      title: context.appLocalizations.checkUpdate,
      tag: LoadingTag.checkUpdate,
    );
    if (result == null) return;
    unawaited(
      commonAction.checkUpdateResultHandle(data: result.release, isUser: true),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    final isLoading =
        !system.isIOS && ref.watch(loadingProvider(LoadingTag.checkUpdate));
    return Scaffold(
      isLoading: isLoading,
      title: appLocalizations.about,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.contentTopPadding,
          bottom: 32 + context.bottomInset,
        ),
        children: [
          _AboutHero(
            isCheckingUpdate: isLoading,
            onCheckUpdate: () {
              _checkUpdate(context, ref);
            },
            onEnterDeveloperMode: () {
              ref
                  .read(appSettingProvider.notifier)
                  .update((state) => state.copyWith(developerMode: true));
              dialogs.showBanner(
                appLocalizations.developerModeEnableTip,
                level: BannerLevel.success,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AboutHero extends StatelessWidget {
  final bool isCheckingUpdate;
  final VoidCallback onCheckUpdate;
  final VoidCallback onEnterDeveloperMode;

  const _AboutHero({
    required this.isCheckingUpdate,
    required this.onCheckUpdate,
    required this.onEnterDeveloperMode,
  });

  static const _logoSize = 96.0;
  static const _logoInset = 14.0;

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    final iosBrand = switch (globalState.packageInfo.packageName) {
      'com.tarn.app' => 'Tarn',
      'tarn.localdev' => 'Tarn Dev',
      _ => null,
    };
    final logoShape = AppShape.all(AppCorner.fit(_logoSize));
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        children: [
          _DeveloperModeDetector(
            onEnterDeveloperMode: onEnterDeveloperMode,
            child: iosBrand != null
                ? ClipPath(
                    clipper: ShapeBorderClipper(shape: logoShape),
                    child: Image.asset(
                      'ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png',
                      width: _logoSize,
                      height: _logoSize,
                      fit: BoxFit.cover,
                    ),
                  )
                : DecoratedBox(
                    decoration: ShapeDecoration(
                      color: context.raisedSurfaceLevel.colorOf(colorScheme),
                      shape: logoShape,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(_logoInset),
                      child: Image.asset(
                        'assets/images/icon.png',
                        width: _logoSize - _logoInset * 2,
                        height: _logoSize - _logoInset * 2,
                      ),
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          if (iosBrand != null)
            Text(
              iosBrand,
              style: AppTextStyle.title2.of(context, emphasized: true),
            )
          else
            FutureBuilder<ProviderProfile?>(
              future: ProviderStore.current(),
              builder: (context, snapshot) => Text(
                snapshot.data?.name ?? appName,
                style: AppTextStyle.title2.of(context, emphasized: true),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _Pill(
                label: 'v${globalState.packageInfo.version}',
                color: colorScheme.primary,
                foregroundColor: colorScheme.onPrimary,
              ),
            ],
          ),
          if (!system.isIOS) ...[
            const SizedBox(height: 20),
            TonalButton(
              size: TonalButtonSize.bar,
              glyph: AppGlyphs.sync,
              label: context.appLocalizations.checkUpdate,
              onPressed: isCheckingUpdate ? null : onCheckUpdate,
            ),
          ],
          if (iosBrand != null) ...[
            const SizedBox(height: 18),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                _AboutLink(
                  label: 'Source code',
                  url: 'https://github.com/lufeiit/tarn',
                ),
                _AboutLink(
                  label: 'Licenses',
                  url: 'https://github.com/lufeiit/tarn/blob/main/README.md',
                ),
                _AboutLink(
                  label: 'Privacy',
                  url: 'https://github.com/lufeiit/tarn/blob/main/PRIVACY.md',
                ),
                _AboutLink(
                  label: 'Support',
                  url: 'mailto:sales@jna-pharma.bond',
                  isMail: true,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// 关于页的外链：GPL 要求分发时能拿到对应源码，这里给出公开仓库地址。
class _AboutLink extends StatelessWidget {
  const _AboutLink({
    required this.label,
    required this.url,
    this.isMail = false,
  });

  final String label;
  final String url;
  final bool isMail;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => dialogs.openUrl(url),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Text(
          label,
          style: AppTextStyle.footnote
              .of(context)
              .copyWith(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
              ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final Color foregroundColor;

  const _Pill({
    required this.label,
    required this.color,
    required this.foregroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: ShapeDecoration(color: color, shape: AppShape.full),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Text(
          label,
          style: AppTextStyle.caption1
              .of(context, emphasized: true)
              .copyWith(color: foregroundColor),
        ),
      ),
    );
  }
}

class _DeveloperModeDetector extends StatefulWidget {
  final Widget child;
  final VoidCallback onEnterDeveloperMode;

  const _DeveloperModeDetector({
    required this.child,
    required this.onEnterDeveloperMode,
  });

  @override
  State<_DeveloperModeDetector> createState() => _DeveloperModeDetectorState();
}

class _DeveloperModeDetectorState extends State<_DeveloperModeDetector> {
  int _counter = 0;
  Timer? _timer;

  void _handleTap() {
    _counter++;
    if (_counter >= 5) {
      widget.onEnterDeveloperMode();
      _resetCounter();
    } else {
      _timer?.cancel();
      _timer = Timer(const Duration(seconds: 1), _resetCounter);
    }
  }

  void _resetCounter() {
    _counter = 0;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(onTap: _handleTap, child: widget.child);
  }
}
