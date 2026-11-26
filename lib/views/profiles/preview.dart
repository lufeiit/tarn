import 'package:tarn/models/profile.dart';
import 'package:tarn/pages/editor.dart';
import 'package:tarn/providers/action.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class PreviewProfileView extends ConsumerWidget {
  final Profile profile;

  const PreviewProfileView({super.key, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return EditorPage(
      title: profile.realLabel,
      load: () async => CodeForgeDocument.fromText(
        await ref
            .read(setupActionProvider.notifier)
            .getProfileWithId(profile.id),
      ),
    );
  }
}
