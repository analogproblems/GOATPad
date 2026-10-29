import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../update/updater.dart';
import '../version.dart';

/// GPad's version and its updates: what the last check found, a button to
/// check now, and whether GPad checks on its own.
Future<void> showUpdatesDialog(BuildContext context, Updater updater) =>
    showDialog<void>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: updater,
        builder: (context, _) => _UpdatesDialog(updater),
      ),
    );

/// What the updater is doing, in a sentence.
String updateSummary(Updater updater) {
  final version = updater.newVersion;
  return switch (updater.status) {
    UpdateStatus.off =>
      'This build doesn\'t update itself. Releases are on GitHub.',
    UpdateStatus.idle => 'GPad hasn\'t checked for updates yet.',
    UpdateStatus.checking => 'Checking for updates…',
    UpdateStatus.upToDate => 'GPad is up to date.',
    UpdateStatus.downloading =>
      'Downloading GPad $version… '
          '${((updater.progress ?? 0) * 100).floor()}%',
    UpdateStatus.ready =>
      'GPad $version is ready. It starts when you restart GPad.',
    UpdateStatus.available =>
      'GPad $version is out. This copy of GPad was installed in a way it '
          'can\'t update itself, so download it from its release page.',
    UpdateStatus.failed => 'GPad couldn\'t update: ${updater.problem}.',
  };
}

/// Opens [url] in the browser.
void _open(Uri url) => unawaited(
  launchUrl(
    url,
    mode: LaunchMode.externalApplication,
  ).then((_) {}, onError: (Object _) {}),
);

class _UpdatesDialog extends StatelessWidget {
  const _UpdatesDialog(this.updater);

  final Updater updater;

  @override
  Widget build(BuildContext context) {
    final busy =
        updater.status == UpdateStatus.checking ||
        updater.status == UpdateStatus.downloading;
    final page = updater.releasePage;
    return AlertDialog(
      title: const Text('GPad $gpadVersion'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(updateSummary(updater)),
            if (updater.status == UpdateStatus.downloading) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: updater.progress),
            ],
            if (updater.status != UpdateStatus.off) ...[
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: updater.automatic,
                onChanged: (on) => updater.setAutomatic(on ?? true),
                title: const Text('Check for updates on its own'),
                subtitle: const Text(
                  'Twice a day, GPad looks at its newest release on GitHub. '
                  'It sends nothing about you or your notes, and installs '
                  'only releases signed with GPad\'s key.',
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (page != null)
          TextButton(
            onPressed: () => _open(page),
            child: Text(
              updater.status == UpdateStatus.available
                  ? 'Download'
                  : 'What\'s new',
            ),
          ),
        if (updater.status != UpdateStatus.off &&
            updater.status != UpdateStatus.ready)
          TextButton(
            onPressed: busy ? null : updater.check,
            child: const Text('Check now'),
          ),
        if (updater.status == UpdateStatus.ready)
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              unawaited(updater.restartNow());
            },
            child: const Text('Restart now'),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Above the notes, once an update is ready or out, until the person says
/// later.
class UpdateNotice extends StatelessWidget {
  const UpdateNotice({super.key, required this.updater});

  final Updater updater;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ready = updater.status == UpdateStatus.ready;
    final page = updater.releasePage;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(
              Icons.system_update_alt,
              size: 18,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                ready
                    ? 'GPad ${updater.newVersion} is ready. It starts when '
                          'you restart GPad.'
                    : 'GPad ${updater.newVersion} is out.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
            if (ready)
              TextButton(
                onPressed: updater.restartNow,
                child: const Text('Restart now'),
              )
            else if (page != null)
              TextButton(
                onPressed: () => _open(page),
                child: const Text('Download'),
              ),
            TextButton(onPressed: updater.dismiss, child: const Text('Later')),
          ],
        ),
      ),
    );
  }
}
