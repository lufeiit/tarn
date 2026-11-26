import 'dart:async';

import 'package:tarn/common/common.dart';
import 'package:tarn/features/form/form.dart';
import 'package:tarn/pages/scan.dart';
import 'package:tarn/plugins/app.dart';
import 'package:tarn/providers/providers.dart';
import 'package:tarn/ui/icons/icons.dart';
import 'package:tarn/views/profiles/custom/custom.dart';
import 'package:tarn/widgets/widgets.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The ways to add a profile, in a menu out of the control [builder] makes.
class AddProfileMenu extends ConsumerWidget {
  const AddProfileMenu({super.key, required this.builder});

  final Widget Function(PopupOpen open) builder;

  Future<void> _handleAddProfileFormFile(WidgetRef ref) async {
    unawaited(ref.read(profilesActionProvider.notifier).addProfileFormFile());
  }

  Future<void> _toScan(BuildContext context, WidgetRef ref) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    if (system.isDesktop) {
      unawaited(profilesAction.addProfileFormQrCode());
      return;
    }
    final url = await BaseNavigator.push(context, const ScanPage());
    if (url == null) {
      return;
    }
    if (context.mounted) {
      await whenRouteUncovered(context);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(profilesAction.addProfileFromLink(url));
    });
  }

  Future<void> _toAdd(BuildContext context, WidgetRef ref) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    final appLocalizations = context.appLocalizations;
    final res = await showNamedUrlsForm(
      context,
      title: appLocalizations.importFromLink,
      urlLabel: appLocalizations.link,
      batchTip: appLocalizations.batchLinkInputTip,
      urlValidator: (value) {
        if (value == null || value.isEmpty) {
          return appLocalizations.emptyTip(appLocalizations.link);
        }
        if (!value.isUrl && !value.isShareLink) {
          return appLocalizations.invalidLinkTip;
        }
        return null;
      },
      existingUrls: {
        for (final profile in ref.read(profilesProvider))
          if (profile.url.isNotEmpty) profile.url,
      },
      withAgeSecretKey: true,
    );
    switch (res) {
      case null:
        return;
      case [final single]:
        unawaited(
          profilesAction.addProfileFromLink(
            single.url,
            label: single.label,
            ageSecretKey: single.ageSecretKey,
          ),
        );
      default:
        unawaited(
          profilesAction.addProfilesFromLinks([
            for (final item in res) item.url,
          ]),
        );
    }
  }

  Future<void> _toPasteCode(BuildContext context, WidgetRef ref) async {
    final appLocalizations = context.appLocalizations;
    final res = await showNamedUrlsForm(
      context,
      title: '从配置码导入',
      urlLabel: '配置码',
      batchTip: '粘贴服务商发来的配置码，或导入链接',
      urlValidator: (value) {
        final text = value?.trim() ?? '';
        if (text.isEmpty) {
          return appLocalizations.emptyTip(appLocalizations.link);
        }
        if (text.startsWith('LF.') ||
            text.startsWith('tarn://') ||
            text.startsWith('lfexp://') ||
            text.isUrl) {
          return null;
        }
        return '无法识别这段配置码';
      },
    );
    if (res == null || res.isEmpty) {
      return;
    }
    final text = res.first.url.trim();
    final profilesAction = ref.read(profilesActionProvider.notifier);

    String? code;
    String? url;
    String? key;
    String? label;
    if (text.startsWith('LF.')) {
      code = text;
    } else {
      final target = installConfigTarget(Uri.parse(text));
      if (target != null) {
        code = target.code;
        url = target.url;
        key = target.key;
        label = target.name;
      } else if (text.isUrl) {
        url = text;
        key = SubscribeSite.keyFromUrl(text);
      }
    }

    if (code != null) {
      final parsed = await AccessCode.parseVerified(code);
      AccessCodeResult? resolved;
      var failure = '配置码无效，请重新获取。';
      try {
        resolved = await parsed?.exchange();
      } on AccessCodeException catch (error) {
        failure = error.message;
      }
      if (!context.mounted) return;
      if (resolved == null || !resolved.url.isUrl) {
        unawaited(
          dialogs.showMessage(
            title: appLocalizations.addProfile,
            message: TextSpan(text: failure),
          ),
        );
        return;
      }
      if (resolved.key case final key?) {
        await SubscribeSite.saveSiteKey(resolved.url, key);
      }
      if (!context.mounted) return;
      unawaited(
        profilesAction.addProfileFromLink(
          resolved.url,
          label: resolved.name,
        ),
      );
      return;
    }

    if (url != null) {
      if (key != null) {
        await SubscribeSite.saveSiteKey(url, key);
      }
      if (!context.mounted) return;
      unawaited(
        profilesAction.addProfileFromLink(url, label: label),
      );
    }
  }

  Future<void> _toSendFromPhone(WidgetRef ref) async {
    final profilesAction = ref.read(profilesActionProvider.notifier);
    if (!(await app?.requestLocalNetworkPermission() ?? true)) {
      final appLocalizations = currentAppLocalizations;
      final res = await dialogs.showMessage(
        message: TextSpan(text: appLocalizations.sendFromPhonePermissionDenied),
        confirmText: appLocalizations.settings,
      );
      if (res == true) {
        await app?.openAppSettings();
      }
      return;
    }
    final link = await dialogs.showCommonDialog<String>(
      child: const _SendFromPhoneDialog(),
    );
    if (link == null) {
      return;
    }
    final appLocalizations = currentAppLocalizations;
    final confirmed = await dialogs.showMessage(
      title: appLocalizations.sendFromPhoneConfirmTitle,
      message: TextSpan(text: link),
      confirmText: appLocalizations.import,
    );
    if (confirmed == true) {
      unawaited(profilesAction.addProfileFromLink(link));
    }
  }

  void _toAddCustom(BuildContext context, WidgetRef ref) {
    final profileId = ref
        .read(profilesActionProvider.notifier)
        .addCustomProfile(context.appLocalizations.unnamed);
    unawaited(
      BaseNavigator.push(
        context,
        CustomProfileView(profileId: profileId, isNew: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appLocalizations = context.appLocalizations;
    return PopupAnchor(
      targetBuilder: builder,
      popupBuilder: (_) => PopupMenu(
        items: [
          PopupMenuItem(
            glyph: AppGlyphs.qrCode,
            label: appLocalizations.qrcode,
            onPressed: () => _toScan(context, ref),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.importFile,
            label: appLocalizations.file,
            onPressed: () => _handleAddProfileFormFile(ref),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.importFile,
            label: '配置码',
            onPressed: () => _toPasteCode(context, ref),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.cloudDownload,
            label: appLocalizations.link,
            onPressed: () => _toAdd(context, ref),
          ),
          if (system.isTV)
            PopupMenuItem(
              glyph: AppGlyphs.devices,
              label: appLocalizations.sendFromPhone,
              onPressed: () => _toSendFromPhone(ref),
            ),
          PopupMenuItem(
            section: const PopupMenuSection(),
            glyph: AppGlyphs.customize,
            label: appLocalizations.customProfile,
            onPressed: () => _toAddCustom(context, ref),
          ),
        ],
      ),
    );
  }
}

class _SendFromPhoneDialog extends StatefulWidget {
  const _SendFromPhoneDialog();

  @override
  State<_SendFromPhoneDialog> createState() => _SendFromPhoneDialogState();
}

class _SendFromPhoneDialogState extends State<_SendFromPhoneDialog> {
  LinkReceiver? _receiver;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final appLocalizations = currentAppLocalizations;
    final receiver = await LinkReceiver.start((
      title: appLocalizations.sendFromPhonePageTitle,
      hint: appLocalizations.sendFromPhonePageHint,
      send: appLocalizations.send,
      sent: appLocalizations.sendFromPhonePageSent,
      invalid: appLocalizations.invalidLinkTip,
    )).catchError((Object _) => null);
    if (!mounted) {
      unawaited(receiver?.close());
      return;
    }
    setState(() {
      _receiver = receiver;
      _failed = receiver == null;
    });
    final link = await receiver?.link;
    if (link != null && mounted) {
      Navigator.of(context).pop(link);
    }
  }

  @override
  void dispose() {
    unawaited(_receiver?.close());
    super.dispose();
  }

  Widget _buildContent(BuildContext context) {
    final appLocalizations = context.appLocalizations;
    if (_failed) {
      return Text(
        appLocalizations.sendFromPhoneNoNetwork,
        textAlign: TextAlign.center,
      );
    }
    final address = _receiver?.address.toString();
    if (address == null) {
      return const SizedBox.square(
        dimension: 96,
        child: Center(child: ActivityIndicator()),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      spacing: 16,
      children: [
        QrCodeView(data: address, size: 200),
        SelectableText(address, textAlign: TextAlign.center),
        Text(appLocalizations.sendFromPhoneTip, textAlign: TextAlign.center),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: context.appLocalizations.sendFromPhone,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.appLocalizations.cancel),
        ),
      ],
      child: _buildContent(context),
    );
  }
}
