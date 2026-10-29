import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync/folder_backend.dart';
import '../sync/sync_backend.dart';
import '../sync/sync_controller.dart';

/// Sets sync up, unlocks it, or shows how it's going.
Future<void> showSyncDialog(BuildContext context, SyncController sync) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SyncDialog(sync),
    );

/// A line for the sidebar saying how sync is going.
({IconData icon, String label}) syncSummary(SyncController sync) =>
    switch (sync.status) {
      SyncStatus.off => (icon: Icons.cloud_off_outlined, label: 'Sync is off'),
      SyncStatus.locked => (
        icon: Icons.lock_outline,
        label: 'Sync paused: unlock',
      ),
      SyncStatus.syncing => (icon: Icons.sync, label: 'Syncing…'),
      SyncStatus.synced => (
        icon: Icons.cloud_done_outlined,
        label: sync.unreadable.isEmpty ? 'Synced' : 'Synced, with problems',
      ),
      SyncStatus.problem => (icon: Icons.sync_problem, label: 'Sync problem'),
    };

enum _Page { choose, create, join, recovery, unlock, status }

class _SyncDialog extends StatefulWidget {
  const _SyncDialog(this.sync);

  final SyncController sync;

  @override
  State<_SyncDialog> createState() => _SyncDialogState();
}

class _SyncDialogState extends State<_SyncDialog> {
  SyncController get sync => widget.sync;

  late _Page _page = switch (sync.status) {
    SyncStatus.off => _Page.choose,
    SyncStatus.locked => _Page.unlock,
    _ => _Page.status,
  };

  final _folder = TextEditingController();
  final _passphrase = TextEditingController();
  final _again = TextEditingController();
  final _recoveryKey = TextEditingController();
  final _passphraseFocus = FocusNode();
  final _recoveryKeyFocus = FocusNode();
  late final _deviceName = TextEditingController(
    text: sync.config?.deviceName ?? sync.defaultDeviceName,
  );

  FolderCheck? _checked;
  String? _newRecoveryKey;
  bool _useRecoveryKey = false;
  bool _remember = true;
  bool? _keychain;
  bool _remembered = false;
  bool _savedKey = false;
  bool _showPassphrase = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    sync.keychain.available().then((available) {
      if (!mounted) return;
      setState(() {
        _keychain = available;
        _remember = available;
      });
    });
    sync.remembered.then((value) {
      if (mounted) setState(() => _remembered = value);
    });
  }

  @override
  void dispose() {
    for (final c in [_folder, _passphrase, _again, _recoveryKey, _deviceName]) {
      c.dispose();
    }
    _passphraseFocus.dispose();
    _recoveryKeyFocus.dispose();
    super.dispose();
  }

  void _go(_Page page) => setState(() {
    _page = page;
    _error = null;
    _passphrase.clear();
    _again.clear();
    _recoveryKey.clear();
    _useRecoveryKey = false;
  });

  /// Runs [action], showing that GPad is busy, and shows what went wrong.
  Future<void> _work(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SyncBackendException catch (e) {
      _error = e.message;
    } on FormatException catch (e) {
      _error =
          'That folder\'s ${FolderBackend.vaultFileName} can\'t be read: '
          '${e.message}';
    } on FileSystemException catch (e) {
      _error = e.osError?.message ?? e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browse() async {
    final path = await getDirectoryPath(
      confirmButtonText: 'Sync here',
      initialDirectory: _folder.text.isEmpty ? null : _folder.text,
    );
    if (path != null) setState(() => _folder.text = path);
  }

  Future<void> _next() => _work(() async {
    final chosen = _folder.text.trim();
    if (chosen.isEmpty) {
      _error = 'Choose a folder first.';
      return;
    }
    final checked = await sync.checkFolder(chosen);
    _checked = checked;
    _go(checked.vault == null ? _Page.create : _Page.join);
  });

  Future<void> _create() => _work(() async {
    final passphrase = _passphrase.text;
    if (passphrase.length < SyncController.minPassphraseLength) {
      _error = 'Use at least ${SyncController.minPassphraseLength} characters.';
      return;
    }
    if (passphrase != _again.text) {
      _error = 'The two passphrases don\'t match.';
      return;
    }
    final key = await sync.create(
      folder: _checked!.path,
      passphrase: passphrase,
      deviceName: _deviceName.text,
      remember: _remember,
    );
    _newRecoveryKey = key;
    _go(_Page.recovery);
  });

  Future<void> _join() => _work(() async {
    final ok = await sync.join(
      folder: _checked!.path,
      vault: _checked!.vault!,
      passphrase: _useRecoveryKey ? null : _passphrase.text,
      recoveryKey: _useRecoveryKey ? _recoveryKey.text : null,
      deviceName: _deviceName.text,
      remember: _remember,
    );
    if (!ok) {
      _error = _wrongKeyMessage;
      return;
    }
    if (mounted) Navigator.of(context).pop();
  });

  Future<void> _unlock() => _work(() async {
    final ok = await sync.unlock(
      passphrase: _useRecoveryKey ? null : _passphrase.text,
      recoveryKey: _useRecoveryKey ? _recoveryKey.text : null,
      remember: _remember,
    );
    if (!ok) {
      _error = _wrongKeyMessage;
      return;
    }
    if (mounted) Navigator.of(context).pop();
  });

  String get _wrongKeyMessage => _useRecoveryKey
      ? 'That recovery key doesn\'t unlock these notes. Check for typos.'
      : 'That passphrase doesn\'t unlock these notes.';

  Future<void> _turnOff() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off sync on this computer?'),
        content: const Text(
          'Your notes stay here, and in the sync folder for your other '
          'computers. Changes here stop going to them, and theirs stop '
          'coming here. GPad forgets the passphrase.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep syncing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Turn off'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await sync.turnOff();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveRecoveryKey() async {
    final location = await getSaveLocation(
      suggestedName: 'GPad recovery key.txt',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Text', extensions: ['txt']),
      ],
    );
    if (location == null) return;
    await File(location.path).writeAsString(
      'GPad recovery key\n\n'
      '$_newRecoveryKey\n\n'
      'This key opens your synced GPad notes if you forget your '
      'passphrase. Keep it somewhere safe, away from your computer.\n',
    );
    if (mounted) setState(() => _savedKey = true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) => AlertDialog(
        title: Text(switch (_page) {
          _Page.choose => 'Sync your notes',
          _Page.create => 'Choose a passphrase',
          _Page.join => 'Unlock your notes',
          _Page.recovery => 'Save your recovery key',
          _Page.unlock => 'Unlock sync',
          _Page.status => 'Sync',
        }),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ..._body(context),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        actions: _actions(context),
      ),
    );
  }

  List<Widget> _body(BuildContext context) => switch (_page) {
    _Page.choose => _chooseBody(context),
    _Page.create => _createBody(context),
    _Page.join => _joinBody(context),
    _Page.recovery => _recoveryBody(context),
    _Page.unlock => _unlockBody(context),
    _Page.status => _statusBody(context),
  };

  List<Widget> _actions(BuildContext context) {
    void close() => Navigator.of(context).pop();
    final busy = _busy;
    return switch (_page) {
      _Page.choose => [
        TextButton(onPressed: busy ? null : close, child: const Text('Cancel')),
        FilledButton(onPressed: busy ? null : _next, child: const Text('Next')),
      ],
      _Page.create => [
        TextButton(
          onPressed: busy ? null : () => _go(_Page.choose),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: busy ? null : _create,
          child: const Text('Start syncing'),
        ),
      ],
      _Page.join => [
        TextButton(
          onPressed: busy ? null : () => _go(_Page.choose),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: busy ? null : _join,
          child: const Text('Unlock and sync'),
        ),
      ],
      _Page.recovery => [
        FilledButton(
          onPressed: _savedKey ? close : null,
          child: const Text('Done'),
        ),
      ],
      _Page.unlock => [
        TextButton(onPressed: busy ? null : close, child: const Text('Later')),
        FilledButton(
          onPressed: busy ? null : _unlock,
          child: const Text('Unlock'),
        ),
      ],
      _Page.status => [
        TextButton(onPressed: _turnOff, child: const Text('Turn off sync…')),
        TextButton(
          onPressed: sync.status == SyncStatus.syncing ? null : sync.syncNow,
          child: const Text('Sync now'),
        ),
        FilledButton(onPressed: close, child: const Text('Close')),
      ],
    };
  }

  List<Widget> _chooseBody(BuildContext context) => [
    const Text(
      'Keep your notes in step on all your computers. GPad encrypts them '
      'here, with a passphrase only you know, before they go anywhere.',
    ),
    const SizedBox(height: 16),
    Row(
      children: [
        Expanded(
          child: TextField(
            controller: _folder,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Sync folder',
              hintText: 'A folder in Dropbox, OneDrive, Nextcloud…',
            ),
            onSubmitted: (_) => _next(),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: _browse, child: const Text('Browse…')),
      ],
    ),
    const SizedBox(height: 8),
    _hint(
      context,
      'Any folder that a tool like Dropbox, OneDrive, Nextcloud or Syncthing '
      'keeps in step between computers, or a network drive. GPad keeps its '
      'files in a GPad folder inside it. On your other computers, choose the '
      'same folder. Google Drive is coming in a later update.',
    ),
  ];

  List<Widget> _createBody(BuildContext context) => [
    Text('GPad keeps your notes in ${_checked!.path}.'),
    const SizedBox(height: 8),
    const Text(
      'Your passphrase encrypts them. You type it once on each computer you '
      'sync. Nobody can reset it, so pick one you\'ll remember: four or five '
      'random words work well.',
    ),
    const SizedBox(height: 12),
    _passphraseField(autofocus: true, onSubmitted: null),
    const SizedBox(height: 8),
    TextField(
      controller: _again,
      obscureText: !_showPassphrase,
      decoration: const InputDecoration(labelText: 'Type it again'),
      onSubmitted: (_) => _create(),
    ),
    const SizedBox(height: 12),
    _deviceNameField(context),
    _rememberBox(context),
  ];

  List<Widget> _joinBody(BuildContext context) => [
    Text(
      '${_checked!.path} already has notes from another computer. Type the '
      'passphrase you chose there.',
    ),
    const SizedBox(height: 12),
    ..._keyFields(onSubmitted: _join),
    const SizedBox(height: 12),
    _deviceNameField(context),
    _rememberBox(context),
    const SizedBox(height: 8),
    _hint(
      context,
      'The notes on this computer join them; nothing here is replaced.',
    ),
  ];

  List<Widget> _unlockBody(BuildContext context) => [
    Text(
      'Sync with ${sync.config?.folder} is paused until you type your '
      'passphrase.',
    ),
    const SizedBox(height: 12),
    ..._keyFields(onSubmitted: _unlock),
    _rememberBox(context),
  ];

  List<Widget> _recoveryBody(BuildContext context) {
    final theme = Theme.of(context);
    return [
      const Text(
        'If you forget your passphrase, this key is the only other way to '
        'open your synced notes. Keep it somewhere safe and away from this '
        'computer: printed out, or in a password manager. GPad shows it '
        'only now.',
      ),
      const SizedBox(height: 16),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          _newRecoveryKey ?? '',
          style: theme.textTheme.titleMedium?.copyWith(
            fontFamily: 'monospace',
            letterSpacing: 1,
          ),
        ),
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy'),
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: _newRecoveryKey ?? '')),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.save_alt, size: 16),
            label: const Text('Save to a file…'),
            onPressed: _saveRecoveryKey,
          ),
        ],
      ),
      const SizedBox(height: 8),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _savedKey,
        onChanged: (value) => setState(() => _savedKey = value ?? false),
        title: const Text('I\'ve saved my recovery key'),
      ),
    ];
  }

  List<Widget> _statusBody(BuildContext context) {
    final theme = Theme.of(context);
    final config = sync.config;
    final summary = syncSummary(sync);
    final problem = sync.status == SyncStatus.problem;
    final color = problem ? theme.colorScheme.error : null;
    return [
      Row(
        children: [
          Icon(summary.icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(switch (sync.status) {
              SyncStatus.synced => 'Synced ${_ago(sync.lastSynced)}',
              SyncStatus.syncing => 'Syncing…',
              SyncStatus.problem => sync.problem ?? 'Sync problem',
              _ => summary.label,
            }, style: TextStyle(color: color)),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (config != null) ...[
        _fact(context, 'Sync folder', config.folder),
        _fact(context, 'This computer', config.deviceName),
        _fact(
          context,
          'Passphrase',
          _remembered
              ? 'Remembered in this computer\'s keychain'
              : 'Asked for each time GPad starts',
        ),
      ],
      if (sync.unreadable.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          '${sync.unreadable.length == 1 ? 'One file' : '${sync.unreadable.length} files'} '
          'in the sync folder couldn\'t be opened, so GPad left '
          '${sync.unreadable.length == 1 ? 'it' : 'them'} alone. A file '
          'changed by something other than GPad, damaged, or saved by a '
          'newer GPad reads this way.',
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ],
    ];
  }

  Widget _fact(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          SelectableText(value),
        ],
      ),
    );
  }

  List<Widget> _keyFields({required VoidCallback onSubmitted}) => [
    if (_useRecoveryKey)
      TextField(
        controller: _recoveryKey,
        focusNode: _recoveryKeyFocus,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Recovery key',
          hintText: 'XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX',
        ),
        onSubmitted: (_) => onSubmitted(),
      )
    else
      _passphraseField(autofocus: true, onSubmitted: onSubmitted),
    Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: () {
          setState(() {
            _useRecoveryKey = !_useRecoveryKey;
            _error = null;
          });
          // The button has focus; hand it to the field just shown.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            (_useRecoveryKey ? _recoveryKeyFocus : _passphraseFocus)
                .requestFocus();
          });
        },
        child: Text(
          _useRecoveryKey
              ? 'Use the passphrase instead'
              : 'Forgot it? Use the recovery key',
        ),
      ),
    ),
  ];

  Widget _passphraseField({
    required bool autofocus,
    required VoidCallback? onSubmitted,
  }) => TextField(
    controller: _passphrase,
    focusNode: _passphraseFocus,
    autofocus: autofocus,
    obscureText: !_showPassphrase,
    decoration: InputDecoration(
      labelText: 'Passphrase',
      suffixIcon: IconButton(
        tooltip: _showPassphrase ? 'Hide' : 'Show',
        icon: Icon(
          _showPassphrase ? Icons.visibility_off : Icons.visibility,
          size: 18,
        ),
        onPressed: () => setState(() => _showPassphrase = !_showPassphrase),
      ),
    ),
    onSubmitted: onSubmitted == null ? null : (_) => onSubmitted(),
  );

  Widget _deviceNameField(BuildContext context) => TextField(
    controller: _deviceName,
    decoration: const InputDecoration(
      labelText: 'This computer\'s name',
      helperText:
          'Shown on the copy GPad keeps when two computers change '
          'a note at once.',
      helperMaxLines: 2,
    ),
  );

  Widget _rememberBox(BuildContext context) {
    final available = _keychain;
    if (available == false) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: _hint(
          context,
          'This computer has no keychain GPad can use, so GPad will ask for '
          'the passphrase each time it starts.',
        ),
      );
    }
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _remember,
      onChanged: available == null
          ? null
          : (value) => setState(() => _remember = value ?? false),
      title: const Text('Remember it on this computer'),
      subtitle: Text(
        Platform.isWindows
            ? 'Kept in the Windows Credential Manager.'
            : 'Kept in your keychain (GNOME Keyring or KWallet).',
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.outline,
      ),
    );
  }

  static String _ago(DateTime? time) {
    if (time == null) return '';
    final elapsed = DateTime.now().difference(time);
    if (elapsed.inSeconds < 60) return 'just now';
    if (elapsed.inMinutes < 60) {
      final m = elapsed.inMinutes;
      return '$m minute${m == 1 ? '' : 's'} ago';
    }
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return 'at $h:$m';
  }
}
