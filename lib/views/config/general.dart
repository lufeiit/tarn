import 'package:tarn/common/common.dart';
import 'package:tarn/enum/enum.dart';
import 'package:tarn/features/form/form.dart';
import 'package:tarn/l10n/l10n.dart';
import 'package:tarn/models/models.dart';
import 'package:tarn/providers/mitm.dart';
import 'package:tarn/providers/providers.dart';
import 'package:tarn/views/config/on_demand.dart';
import 'package:tarn/views/config/override.dart';
import 'package:tarn/views/config/user_agents.dart';
import 'package:tarn/widgets/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'general/overrides.dart';
part 'general/port_form.dart';

class LogLevelItem extends ConsumerWidget {
  const LogLevelItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigOptionsItem<LogLevel>(
      title: (l) => l.logLevel,
      options: LogLevel.values,
      textBuilder: (logLevel) => logLevel.name,
      selector: patchClashConfigProvider.select((state) => state.logLevel),
      onChanged: (ref, value) => ref
          .read(patchClashConfigProvider.notifier)
          .update((state) => state.copyWith(logLevel: value)),
    );
  }
}

class UaItem extends ConsumerWidget {
  const UaItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final globalUa = ref.watch(
      patchClashConfigProvider.select((state) => state.globalUa),
    );
    return ListItem.open(
      title: Text(appLocalizations.userAgent),
      subtitle: Text(globalUa ?? appLocalizations.defaultText),
      widget: const UserAgentsView(),
    );
  }
}

class DelayTestTimeoutItem extends ConsumerWidget {
  const DelayTestTimeoutItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    return ConfigOptionsItem<int>(
      title: (l) => l.delayTestTimeout,
      options: delayTestTimeoutOptions,
      textBuilder: (value) => '$value ms',
      selector: appSettingProvider.select((state) => state.delayTestTimeout),
      onChanged: (ref, value) => ref
          .read(appSettingProvider.notifier)
          .update((state) => state.copyWith(delayTestTimeout: value)),
    );
  }
}

class PortItem extends ConsumerWidget {
  const PortItem({super.key});

  Future<void> handleShowPortForm(BuildContext context) async {
    await showFormSheet<void>(
      context: context,
      builder: (_) => const _PortForm(),
    );
  }

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final mixedPort = ref.watch(
      patchClashConfigProvider.select((state) => state.mixedPort),
    );
    return ListItem(
      title: Text(appLocalizations.port),
      subtitle: Text('$mixedPort'),
      onTap: () {
        handleShowPortForm(context);
      },
    );
  }
}

class HostsItem extends ConsumerWidget {
  const HostsItem({super.key});

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final hosts = ref.watch(
      patchClashConfigProvider.select((state) => state.hosts),
    );
    final taken =
        ref.watch(mitmTakeoverProvider).value?.hosts ??
        const <String, String>{};
    return ListItem.open(
      title: const Text('Hosts'),
      subtitle: Text(
        hosts.isEmpty
            ? appLocalizations.none
            : appLocalizations.itemsCount(hosts.length),
      ),
      widget: MapEditView(
        title: 'Hosts',
        entries: hosts,
        keyMaxLength: TextInputLimits.domain,
        valueMaxLength: TextInputLimits.hostValue,
        titleBuilder: (item) => Text(item.key),
        subtitleBuilder: (item) => Text(
          [
            item.value,
            if (taken[item.key] case final module?)
              appLocalizations.mitmChangeReplacedBy(module),
          ].join('\n'),
        ),
      ),
      onChanged: (value) {
        if (value is! Map<String, String>) {
          return;
        }
        ref
            .read(patchClashConfigProvider.notifier)
            .update((state) => state.copyWith(hosts: value));
      },
    );
  }
}

ConfigToggleItem _clashToggle({
  required ConfigLabel title,
  required bool Function(PatchClashConfig state) select,
  required PatchClashConfig Function(PatchClashConfig state, bool value) update,
}) {
  return ConfigToggleItem(
    title: title,
    selector: patchClashConfigProvider.select(select),
    onChanged: (ref, value) => ref
        .read(patchClashConfigProvider.notifier)
        .update((state) => update(state, value)),
  );
}

ConfigToggleItem _appSettingToggle({
  required ConfigLabel title,
  required bool Function(AppSettingProps state) select,
  required AppSettingProps Function(AppSettingProps state, bool value) update,
}) {
  return ConfigToggleItem(
    title: title,
    selector: appSettingProvider.select(select),
    onChanged: (ref, value) => ref
        .read(appSettingProvider.notifier)
        .update((state) => update(state, value)),
  );
}

class GeneralView extends ConsumerWidget {
  const GeneralView({super.key});

  List<Widget> _startupItems(AppLocalizations appLocalizations) {
    return [
      if (system.isDesktop) ...[
        _appSettingToggle(
          title: (l) => l.autoLaunch,
          select: (state) => state.autoLaunch,
          update: (state, value) => state.copyWith(autoLaunch: value),
        ),
        _appSettingToggle(
          title: (l) => l.silentLaunch,
          select: (state) => state.silentLaunch,
          update: (state, value) => state.copyWith(silentLaunch: value),
        ),
      ],
      if (!system.isIOS)
        _appSettingToggle(
          title: (l) => l.autoRun,
          select: (state) => state.autoRun,
          update: (state, value) => state.copyWith(autoRun: value),
        ),
      if (!system.isIOS)
        ListItem.open(
          title: Text(appLocalizations.onDemand),
          widget: const OnDemandView(),
        ),
      _appSettingToggle(
        title: (l) => l.minimizeOnExit,
        select: (state) => state.minimizeOnExit,
        update: (state, value) => state.copyWith(minimizeOnExit: value),
      ),
      if (system.isAndroid) ...[
        _appSettingToggle(
          title: (l) => l.exclude,
          select: (state) => state.hidden,
          update: (state, value) => state.copyWith(hidden: value),
        ),
        _appSettingToggle(
          title: (l) => l.showNotificationStopAction,
          select: (state) => state.showNotificationStopAction,
          update: (state, value) =>
              state.copyWith(showNotificationStopAction: value),
        ),
      ],
    ];
  }

  /// 外部控制器与认证已移除：iOS 客户端不对外提供 REST 接口，
  /// 也不给混合端口加账号密码（内核侧同样强制关闭）。
  List<Widget> _inboundItems() {
    return [
      const PortItem(),
      _clashToggle(
        title: (l) => l.allowLan,
        select: (state) => state.allowLan,
        update: (state, value) => state.copyWith(allowLan: value),
      ),
    ];
  }

  List<Widget> _connectionItems() {
    return [
      const DelayTestTimeoutItem(),
      _clashToggle(
        title: (l) => l.alwaysFindProcess,
        select: (state) => state.findProcessMode == FindProcessMode.always,
        update: (state, value) => state.copyWith(
          findProcessMode: value
              ? FindProcessMode.always
              : FindProcessMode.strict,
        ),
      ),
      _appSettingToggle(
        title: (l) => l.autoCloseConnections,
        select: (state) => state.closeConnections,
        update: (state, value) => state.copyWith(closeConnections: value),
      ),
      _appSettingToggle(
        title: (l) => l.onlyStatisticsProxy,
        select: (state) => state.onlyStatisticsProxy,
        update: (state, value) => state.copyWith(onlyStatisticsProxy: value),
      ),
    ];
  }

  List<Widget> _requestItems() {
    return [
      const UaItem(),
      _appSettingToggle(
        title: (l) => l.checkCertificate,
        select: (state) => state.checkCertificate,
        update: (state, value) => state.copyWith(checkCertificate: value),
      ),
    ];
  }

  List<Widget> _coreItems() {
    return [
      const HostsItem(key: ValueKey(#hosts)),
      ConfigToggleItem(
        key: const ValueKey(#appendSystemDns),
        title: (l) => l.appendSystemDns,
        selector: networkSettingProvider.select(
          (state) => state.appendSystemDns,
        ),
        onChanged: (ref, value) => ref
            .read(networkSettingProvider.notifier)
            .update((state) => state.copyWith(appendSystemDns: value)),
      ),
    ];
  }

  List<Widget> _logItems() {
    return [
      const LogLevelItem(),
      _appSettingToggle(
        title: (l) => l.logcat,
        select: (state) => state.openLogs,
        update: (state, value) => state.copyWith(openLogs: value),
      ),
    ];
  }

  @override
  Widget build(BuildContext context, ref) {
    final appLocalizations = context.appLocalizations;
    final developerMode = ref.watch(
      appSettingProvider.select((state) => state.developerMode),
    );
    return BaseScaffold(
      title: appLocalizations.general,
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16).copyWith(
          top: context.sectionsTopPadding,
          bottom: 16 + context.bottomInset,
        ),
        children: [
          generateSection(
            title: appLocalizations.startupAndBackground,
            items: _startupItems(appLocalizations),
            footer: system.isIOS ? null : appLocalizations.autoRunDesc,
          ),
          generateSection(
            title: appLocalizations.requestsAndUpdates,
            items: _requestItems(),
            footer: appLocalizations.checkCertificateDesc,
          ),
          generateSection(
            title: appLocalizations.inbound,
            items: _inboundItems(),
          ),
          generateSection(
            title: appLocalizations.connection,
            items: _connectionItems(),
          ),
          OverrideSection(
            title: appLocalizations.core,
            spec: _generalOverrideSpec,
            items: _coreItems(),
          ),
          // 日志等级与日志捕获只在开发者模式下出现。
          if (developerMode)
            generateSection(
              title: appLocalizations.logsAndDiagnostics,
              items: _logItems(),
              footer: appLocalizations.logcatDesc,
            ),
        ],
      ),
    );
  }
}
