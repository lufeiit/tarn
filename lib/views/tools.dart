import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/l10n/l10n.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/providers/providers.dart';
import 'package:tarn/ui/icons/icons.dart';
import 'package:tarn/views/about.dart';
import 'package:tarn/views/access.dart';
import 'package:tarn/views/config/general.dart';
import 'package:tarn/views/disclaimer.dart';
import 'package:tarn/views/hotkey.dart';
import 'package:tarn/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/advanced.dart';
import 'developer.dart';
import 'theme.dart';

class ToolsView extends ConsumerStatefulWidget {
  const ToolsView({super.key});

  @override
  ConsumerState<ToolsView> createState() => _ToolViewState();
}

class _ToolViewState extends ConsumerState<ToolsView> {
  late final ScrollController _controller;

  @override
  void initState() {
    super.initState();
    _controller = sheetScrollController(context);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Widget _buildNavigationMenuItem(NavigationItem navigationItem) {
    return ListItem.open(
      leading: GlyphIcon(navigationItem.glyph),
      title: Text(navigationItem.label.label),
      widget: navigationItem.builder(context),
      forceFull: navigationItem.modes.contains(NavigationItemMode.moreFull),
    );
  }

  Widget _getOtherList(bool enableDeveloperMode) {
    return generateSection(
      title: context.appLocalizations.other,
      items: [
        if (enableDeveloperMode) const _DeveloperItem(),
        if (system.isIOS)
          ListItem(
            leading: const GlyphIcon(AppGlyphs.info),
            title: Text(context.appLocalizations.vpnPrivacyNoticeTitle),
            onTap: () => showVpnPrivacyNotice(context: context),
          ),
        const _InfoItem(),
      ],
    );
  }

  Widget _getSettingList() {
    return generateSection(
      title: context.appLocalizations.settings,
      items: [
        const _LocaleItem(),
        const _ThemeItem(),
        if (system.isDesktop) const _HotkeyItem(),
        if (system.isAndroid) const _AccessItem(),
        const _AdvancedConfigItem(),
        const _GeneralItem(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final developerMode = ref.watch(
      appSettingProvider.select((state) => state.developerMode),
    );
    final items = [
      const _ProviderSection(),
      Consumer(
        builder: (_, ref, _) {
          final state = ref.watch(moreToolsSelectorStateProvider);
          if (state.navigationItems.isEmpty) {
            return Container();
          }
          return generateSection(
            items: state.navigationItems.map(_buildNavigationMenuItem),
          );
        },
      ),
      _getSettingList(),
      _getOtherList(developerMode),
    ];
    return Scaffold(
      title: context.appLocalizations.tools,
      body: Builder(
        builder: (context) => PrismListView(
          key: toolsStoreKey,
          controller: _controller,
          itemCount: items.length,
          itemBuilder: (_, index) => items[index],
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: context.sectionsTopPadding,
            bottom: 20 + context.bottomInset,
          ),
        ),
      ),
    );
  }
}

class _ProviderSection extends StatelessWidget {
  const _ProviderSection();

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    if (!RemoteConfig.flag('providerCard')) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<ProviderProfile?>(
      future: ProviderStore.current(),
      builder: (context, snapshot) {
        final provider = snapshot.data;
        if (provider == null) {
          return const SizedBox.shrink();
        }
        Widget link(String label, String url) {
          return GestureDetector(
            onTap: () => dialogs.openUrl(url),
            child: Padding(
              padding: const EdgeInsets.only(right: 18),
              child: Text(
                label,
                style: TextStyle(
                  color: colorScheme.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: colorScheme.primary,
                ),
              ),
            ),
          );
        }

        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: context.raisedSurfaceLevel.colorOf(colorScheme),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (provider.logo != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        provider.logo!,
                        width: 28,
                        height: 28,
                        errorBuilder: (_, _, _) =>
                            const SizedBox(width: 28, height: 28),
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Text(
                      provider.name,
                      style: AppTextStyle.title3.of(context, emphasized: true),
                    ),
                  ),
                ],
              ),
              if (provider.notice != null) ...[
                const SizedBox(height: 8),
                Text(
                  provider.notice!,
                  style: AppTextStyle.footnote
                      .of(context)
                      .copyWith(color: colorScheme.onSurfaceVariant, height: 1.4),
                ),
              ],
              if (provider.home != null || provider.customerService != null) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    if (provider.home != null) link('官网', provider.home!),
                    if (provider.customerService != null)
                      link('客服', provider.customerService!),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => dialogs.showCommonDialog(
                        child: const _ProviderManagerDialog(),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(
                          '管理',
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _ProviderManagerDialog extends StatefulWidget {
  const _ProviderManagerDialog();

  @override
  State<_ProviderManagerDialog> createState() => _ProviderManagerDialogState();
}

class _ProviderManagerDialogState extends State<_ProviderManagerDialog> {
  List<ProviderProfile> _items = const [];
  String? _currentId;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final items = await ProviderStore.all();
    final current = await ProviderStore.current();
    if (!mounted) return;
    setState(() {
      _items = items;
      _currentId = current?.id;
      _loading = false;
    });
  }

  Future<void> _select(ProviderProfile provider) async {
    await ProviderStore.setCurrent(provider.id);
    await _load();
  }

  Future<void> _remove(ProviderProfile provider) async {
    final confirmed = await dialogs.showMessage(
      title: '删除服务商',
      message: TextSpan(text: '确定删除「${provider.name}」？'),
      destructive: true,
      confirmText: '删除',
    );
    if (confirmed != true) return;
    await ProviderStore.remove(provider.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = context.colorScheme;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460, maxHeight: 460),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '服务商',
              style: AppTextStyle.title3.of(context, emphasized: true),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('加载中…'),
              )
            else if (_items.isEmpty)
              Text(
                '还没有服务商，导入一个配置码后会出现在这里。',
                style: TextStyle(color: colorScheme.onSurfaceVariant),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  separatorBuilder: (_, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Container(
                      height: 1,
                      color: colorScheme.outlineVariant.withValues(alpha: .4),
                    ),
                  ),
                  itemBuilder: (context, index) {
                    final provider = _items[index];
                    final isCurrent = provider.id == _currentId;
                    return Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(provider.name),
                              if (provider.home != null)
                                Text(
                                  provider.home!,
                                  style: AppTextStyle.footnote.of(context).copyWith(
                                        color: colorScheme.onSurfaceVariant,
                                      ),
                                ),
                            ],
                          ),
                        ),
                        if (isCurrent)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              '当前',
                              style: TextStyle(color: colorScheme.primary),
                            ),
                          )
                        else
                          GestureDetector(
                            onTap: () => _select(provider),
                            child: Padding(
                              padding: const EdgeInsets.only(right: 12),
                              child: Text(
                                '设为当前',
                                style: TextStyle(color: colorScheme.primary),
                              ),
                            ),
                          ),
                        GestureDetector(
                          onTap: () => _remove(provider),
                          child: Text(
                            '删除',
                            style: TextStyle(color: colorScheme.error),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LocaleItem extends ConsumerWidget {
  const _LocaleItem();

  String _getLocaleString(BuildContext context, Locale? locale) {
    if (locale == null) return context.appLocalizations.defaultText;
    return locale.label;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locale = ref.watch(
      appSettingProvider.select((state) => state.locale),
    );
    final currentLocale = getLocaleForString(locale);
    return ListItem<Locale?>.options(
      leading: const GlyphIcon(AppGlyphs.language),
      title: Text(context.appLocalizations.language),
      options: [null, ...AppLocalizations.supportedLocales],
      onChanged: (Locale? locale) {
        ref
            .read(appSettingProvider.notifier)
            .update((state) => state.copyWith(locale: locale?.toString()));
      },
      textBuilder: (locale) => _getLocaleString(context, locale),
      value: currentLocale == null
          ? null
          : basicLocaleListResolution([
              currentLocale,
            ], AppLocalizations.supportedLocales),
    );
  }
}

class _ThemeItem extends StatelessWidget {
  const _ThemeItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.paintbrush),
      title: Text(context.appLocalizations.theme),
      widget: const ThemeView(),
    );
  }
}

class _HotkeyItem extends StatelessWidget {
  const _HotkeyItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.keyboard),
      title: Text(context.appLocalizations.hotkeyManagement),
      widget: const HotKeyView(),
    );
  }
}

class _AccessItem extends StatelessWidget {
  const _AccessItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.appsList),
      title: Text(context.appLocalizations.accessControl),
      widget: const AccessView(),
    );
  }
}

class _GeneralItem extends StatelessWidget {
  const _GeneralItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.settings),
      title: Text(context.appLocalizations.general),
      widget: const GeneralView(),
    );
  }
}

class _AdvancedConfigItem extends StatelessWidget {
  const _AdvancedConfigItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.wrench),
      title: Text(context.appLocalizations.advancedConfig),
      widget: const AdvancedConfigView(),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.info),
      title: Text(context.appLocalizations.about),
      widget: const AboutView(),
    );
  }
}

class _DeveloperItem extends StatelessWidget {
  const _DeveloperItem();

  @override
  Widget build(BuildContext context) {
    return ListItem.open(
      leading: const GlyphIcon(AppGlyphs.cpu),
      title: Text(context.appLocalizations.developerMode),
      widget: const DeveloperView(),
    );
  }
}
