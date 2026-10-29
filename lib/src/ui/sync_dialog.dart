import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../sync/google_auth.dart';
import '../sync/sync_backend.dart';
import '../sync/sync_controller.dart';
import '../sync/sync_engine.dart' show SyncException;

/// Sets sync up, unlocks it, or shows how it's going.
Future<void> showSyncDialog(BuildContext context, SyncController sync) =>
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _SyncDialog(sync),
    );

/// A line for the sidebar saying how sync is going.
({IconData icon, String label}) syncSummary(
  SyncController sync,
) => switch (sync.status) {
  SyncStatus.off => (icon: Icons.cloud_off_outlined, label: 'Sync is off'),
  SyncStatus.locked => (icon: Icons.lock_outline, label: 'Sync paused: unlock'),
  SyncStatus.syncing => (icon: Icons.sync, label: 'Syncing…'),
  SyncStatus.synced => (
    icon: Icons.cloud_done_outlined,
    label: sync.unreadable.isEmpty ? 'Synced' : 'Synced, with problems',
  ),
  SyncStatus.problem => (icon: Icons.sync_problem, label: 'Sync problem'),
  SyncStatus.signedOut => (icon: Icons.login, label: 'Sync paused: sign in'),
};

enum _Page {
  choose,
  create,
  join,
  recovery,
  unlock,
  signIn,
  status,
  changePassphrase,
  newRecoveryKey,
}

/// Where someone chose to sync through.
enum _Where { drive, folder }

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
    SyncStatus.signedOut => _Page.signIn,
    _ => _Page.status,
  };

  late _Where _where = sync.googleClient == null ? _Where.folder : _Where.drive;

  final _folder = TextEditingController();
  final _passphrase = TextEditingController();
  final _newPassphrase = TextEditingController();
  final _again = TextEditingController();
  final _recoveryKey = TextEditingController();
  final _clientId = TextEditingController();
  final _clientSecret = TextEditingController();
  final _passphraseFocus = FocusNode();
  final _recoveryKeyFocus = FocusNode();
  final _newPassphraseFocus = FocusNode();
  late final _deviceName = TextEditingController(
    text: sync.config?.deviceName ?? sync.defaultDeviceName,
  );

  PlaceCheck? _checked;
  String? _newRecoveryKey;

  /// Whether [_newRecoveryKey] replaced one, which stopped working.
  bool _replacedRecoveryKey = false;

  /// What the last change on the status page did.
  String? _changed;

  /// Whether the person uses their own Google sign-in client.
  late bool _ownClient = sync.googleClient == null;

  /// The sign-in link while GPad waits for the browser, and how to stop
  /// waiting.
  Uri? _signInUrl;
  Completer<void>? _cancelSignIn;

  /// Whether GPad is saving a sign-in, which can't be cancelled.
  bool _savingSignIn = false;
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
    _stopSigningIn();
    for (final c in [
      _folder,
      _passphrase,
      _newPassphrase,
      _again,
      _recoveryKey,
      _clientId,
      _clientSecret,
      _deviceName,
    ]) {
      c.dispose();
    }
    _passphraseFocus.dispose();
    _recoveryKeyFocus.dispose();
    _newPassphraseFocus.dispose();
    super.dispose();
  }

  void _go(_Page page) {
    if (!mounted) return;
    setState(() {
      _page = page;
      _error = null;
      _changed = null;
      _passphrase.clear();
      _newPassphrase.clear();
      _again.clear();
      _recoveryKey.clear();
      _useRecoveryKey = false;
    });
  }

  /// Runs [action], showing that GPad is busy, and shows what went wrong.
  /// Does nothing while GPad is busy already, as when someone presses
  /// Enter twice.
  Future<void> _work(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on SyncBackendException catch (e) {
      _error = e.message;
    } on SyncException catch (e) {
      _error = e.message;
    } on FormatException catch (e) {
      _error = 'The vault file there can\'t be read: ${e.message}';
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

  /// Signs in to Google in the browser, showing the link meanwhile, and
  /// returns what [signIn] did, or null if it was cancelled. Once [signIn]
  /// says it is saving the sign-in, it can't be cancelled any more, and
  /// Cancel goes.
  Future<T?> _signingIn<T>(
    Future<T> Function(
      void Function(Uri url) showUrl,
      Future<void> cancel,
      void Function() saving,
    )
    signIn,
  ) async {
    final cancel = _cancelSignIn = Completer<void>();
    try {
      return await signIn(
        (url) {
          if (mounted) setState(() => _signInUrl = url);
        },
        cancel.future,
        () {
          _cancelSignIn = null;
          _signInUrl = null;
          _savingSignIn = true;
          if (mounted) setState(() {});
        },
      );
    } on GoogleAuthException {
      if (cancel.isCompleted) return null;
      rethrow;
    } finally {
      _cancelSignIn = null;
      _savingSignIn = false;
      if (mounted) setState(() => _signInUrl = null);
    }
  }

  void _stopSigningIn() {
    final cancel = _cancelSignIn;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  Future<void> _next() => _where == _Where.drive ? _signInToDrive() : _check();

  Future<void> _signInToDrive() => _work(() async {
    GoogleClient? own;
    if (_ownClient) {
      final id = _clientId.text.trim();
      final secret = _clientSecret.text.trim();
      if (id.isEmpty || secret.isEmpty) {
        _error = 'Enter your Google client\'s ID and secret.';
        return;
      }
      own = GoogleClient(id: id, secret: secret);
    }
    final checked = await _signingIn(
      (showUrl, cancel, _) =>
          sync.signInToDrive(ownClient: own, showUrl: showUrl, cancel: cancel),
    );
    if (checked == null || !mounted) return;
    _checked = checked;
    _go(checked.vault == null ? _Page.create : _Page.join);
  });

  Future<void> _signInAgain() => _work(() async {
    final done = await _signingIn((showUrl, cancel, saving) async {
      await sync.signInAgain(showUrl: showUrl, cancel: cancel, saving: saving);
      return true;
    });
    if (done == true && mounted) Navigator.of(context).pop();
  });

  Future<void> _check() => _work(() async {
    final chosen = _folder.text.trim();
    if (chosen.isEmpty) {
      _error = 'Choose a folder first.';
      return;
    }
    final checked = await sync.checkFolder(chosen);
    _checked = checked;
    _go(checked.vault == null ? _Page.create : _Page.join);
  });

  /// What is wrong with a new [passphrase], typed again as [again].
  static String? _newPassphraseProblem(String passphrase, String again) {
    if (passphrase.length < SyncController.minPassphraseLength) {
      return 'Use at least ${SyncController.minPassphraseLength} characters.';
    }
    if (passphrase != again) return 'The two passphrases don\'t match.';
    return null;
  }

  Future<void> _create() => _work(() async {
    final passphrase = _passphrase.text;
    if (_newPassphraseProblem(passphrase, _again.text) case final problem?) {
      _error = problem;
      return;
    }
    final key = await sync.create(
      place: _checked!.place,
      passphrase: passphrase,
      deviceName: _deviceName.text,
      remember: _remember,
    );
    _newRecoveryKey = key;
    _replacedRecoveryKey = false;
    _go(_Page.recovery);
  });

  Future<void> _join() => _work(() async {
    final ok = await sync.join(
      place: _checked!.place,
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
      _error =
          '$_wrongKeyMessage If it was changed on another computer and GPad '
          'can\'t reach ${sync.config?.place.description} now, the old one '
          'still works here.';
      return;
    }
    if (mounted) Navigator.of(context).pop();
  });

  Future<void> _changePassphrase() => _work(() async {
    final passphrase = _newPassphrase.text;
    if (_newPassphraseProblem(passphrase, _again.text) case final problem?) {
      _error = problem;
      return;
    }
    final ok = await sync.changePassphrase(
      passphrase: _useRecoveryKey ? null : _passphrase.text,
      recoveryKey: _useRecoveryKey ? _recoveryKey.text : null,
      newPassphrase: passphrase,
    );
    if (!ok) {
      _error = _wrongKeyMessage;
      return;
    }
    _go(_Page.status);
    if (mounted) {
      setState(
        () => _changed =
            'Passphrase changed. Your other computers take the new one as '
            'they sync.',
      );
    }
  });

  Future<void> _makeRecoveryKey() => _work(() async {
    final key = await sync.newRecoveryKey(
      passphrase: _useRecoveryKey ? null : _passphrase.text,
      recoveryKey: _useRecoveryKey ? _recoveryKey.text : null,
    );
    if (key == null) {
      _error = _wrongKeyMessage;
      return;
    }
    _newRecoveryKey = key;
    _replacedRecoveryKey = true;
    _savedKey = false;
    _go(_Page.recovery);
  });

  String get _wrongKeyMessage => _useRecoveryKey
      ? 'That recovery key doesn\'t unlock these notes. Check for typos.'
      : 'That passphrase doesn\'t unlock these notes.';

  Future<void> _turnOff() async {
    final drive = sync.config?.place is DrivePlace;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Turn off sync on this computer?'),
        content: Text(
          'Your notes stay here, and in '
          '${drive ? 'Google Drive' : 'the sync folder'} for your other '
          'computers. Changes here stop going to them, and theirs stop '
          'coming here. GPad forgets the passphrase'
          '${drive ? ' and signs out of Google here' : ''}.',
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
          _Page.signIn => 'Sign in to Google',
          _Page.status => 'Sync',
          _Page.changePassphrase => 'Change your passphrase',
          _Page.newRecoveryKey => 'Make a new recovery key',
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
    _Page.signIn => _signInBody(context),
    _Page.status => _statusBody(context),
    _Page.changePassphrase => _changePassphraseBody(context),
    _Page.newRecoveryKey => _newRecoveryKeyBody(context),
  };

  List<Widget> _actions(BuildContext context) {
    void close() => Navigator.of(context).pop();
    final busy = _busy;
    final signingIn = _cancelSignIn != null;
    return switch (_page) {
      _Page.choose => [
        TextButton(
          onPressed: signingIn ? _stopSigningIn : (busy ? null : close),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _next,
          child: Text(_where == _Where.drive ? 'Sign in with Google' : 'Next'),
        ),
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
      _Page.signIn => [
        TextButton(
          onPressed: signingIn ? _stopSigningIn : (busy ? null : close),
          child: Text(signingIn ? 'Cancel' : 'Later'),
        ),
        FilledButton(
          onPressed: busy ? null : _signInAgain,
          child: const Text('Sign in with Google'),
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
      _Page.changePassphrase => [
        TextButton(
          onPressed: busy ? null : () => _go(_Page.status),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: busy ? null : _changePassphrase,
          child: const Text('Change passphrase'),
        ),
      ],
      _Page.newRecoveryKey => [
        TextButton(
          onPressed: busy ? null : () => _go(_Page.status),
          child: const Text('Back'),
        ),
        FilledButton(
          onPressed: busy ? null : _makeRecoveryKey,
          child: const Text('Make new key'),
        ),
      ],
    };
  }

  List<Widget> _chooseBody(BuildContext context) => [
    const Text(
      'Keep your notes in step on all your computers. GPad encrypts them '
      'here, with a passphrase only you know, before they go anywhere.',
    ),
    const SizedBox(height: 16),
    SegmentedButton<_Where>(
      segments: const [
        ButtonSegment(
          value: _Where.drive,
          icon: Icon(Icons.add_to_drive),
          label: Text('Google Drive'),
        ),
        ButtonSegment(
          value: _Where.folder,
          icon: Icon(Icons.folder_outlined),
          label: Text('A sync folder'),
        ),
      ],
      selected: {_where},
      onSelectionChanged: _busy
          ? null
          : (selected) => setState(() {
              _where = selected.single;
              _error = null;
            }),
    ),
    const SizedBox(height: 16),
    if (_where == _Where.drive)
      ..._driveChoice(context)
    else
      ..._folderChoice(context),
  ];

  List<Widget> _driveChoice(BuildContext context) => [
    _hint(
      context,
      'GPad keeps its encrypted files in a GPad folder in your Google Drive, '
      'and can see only the files it makes there. Signing in opens your '
      'browser. On your other computers, sign in with the same Google '
      'account.',
    ),
    if (_ownClient) ...[
      const SizedBox(height: 12),
      if (sync.googleClient == null)
        const Text(
          'This copy of GPad has no Google sign-in built in, so it needs '
          'your own Google client.',
        ),
      TextField(
        controller: _clientId,
        enabled: !_busy,
        decoration: const InputDecoration(labelText: 'Client ID'),
      ),
      TextField(
        controller: _clientSecret,
        enabled: !_busy,
        decoration: const InputDecoration(labelText: 'Client secret'),
        onSubmitted: (_) => _next(),
      ),
      const SizedBox(height: 8),
      _hint(
        context,
        'Make a "Desktop app" OAuth client in Google Cloud, allowed into the '
        'Drive API with the drive.file scope; GPad\'s README says how. Use '
        'the same client on every computer: Google shows each client only '
        'the files it made.',
      ),
    ],
    if (sync.googleClient != null)
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _busy
              ? null
              : () => setState(() => _ownClient = !_ownClient),
          child: Text(
            _ownClient
                ? 'Use GPad\'s Google sign-in'
                : 'Use your own Google client…',
          ),
        ),
      ),
    ..._waitingForBrowser(context),
  ];

  /// While GPad waits for the browser: what to do there, and the link, in
  /// case the browser didn't open. Then, while GPad saves the sign-in, that
  /// it does.
  List<Widget> _waitingForBrowser(BuildContext context) {
    if (_savingSignIn) {
      return const [
        SizedBox(height: 12),
        Text(
          'Saving the sign-in in this computer\'s keychain, which may ask you '
          'to unlock it.',
        ),
      ];
    }
    final url = _signInUrl;
    if (url == null) return const [];
    return [
      const SizedBox(height: 12),
      const Text(
        'Finish signing in in your browser. If it didn\'t open, copy the '
        'link into it.',
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('Copy sign-in link'),
          onPressed: () => Clipboard.setData(ClipboardData(text: '$url')),
        ),
      ),
    ];
  }

  List<Widget> _folderChoice(BuildContext context) => [
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
      'same folder.',
    ),
  ];

  /// Where the notes go, in a sentence's words.
  static String _whereWords(SyncPlace place) => switch (place) {
    FolderPlace(:final path) => path,
    DrivePlace(:final account) => 'the Google Drive of $account',
  };

  List<Widget> _createBody(BuildContext context) => [
    Text(switch (_checked!.place) {
      FolderPlace(:final path) => 'GPad keeps your notes in $path.',
      DrivePlace(:final account) =>
        'GPad keeps your notes in a GPad folder in the Google Drive of '
            '$account.',
    }),
    const SizedBox(height: 8),
    const Text(
      'Your passphrase encrypts them. You type it once on each computer you '
      'sync. Nobody can reset it, so pick one you\'ll remember: four or five '
      'random words work well.',
    ),
    const SizedBox(height: 12),
    _passphraseField(
      _passphrase,
      focusNode: _passphraseFocus,
      autofocus: true,
      onSubmitted: null,
    ),
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
      '${_capitalized(_whereWords(_checked!.place))} already has notes from '
      'another computer. Type the passphrase you chose there.',
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
      'Sync with ${sync.config?.place.description} is paused until you '
      'type your passphrase.',
    ),
    const SizedBox(height: 12),
    ..._keyFields(onSubmitted: _unlock),
    _rememberBox(context),
  ];

  List<Widget> _changePassphraseBody(BuildContext context) => [
    const Text(
      'Type your passphrase as it is now, then the new one. Your other '
      'computers take the new one as they sync, and the old one stops '
      'working.',
    ),
    const SizedBox(height: 12),
    ..._keyFields(
      label: 'Current passphrase',
      onSubmitted: _newPassphraseFocus.requestFocus,
    ),
    _passphraseField(
      _newPassphrase,
      label: 'New passphrase',
      focusNode: _newPassphraseFocus,
      autofocus: false,
      onSubmitted: null,
    ),
    const SizedBox(height: 8),
    TextField(
      controller: _again,
      obscureText: !_showPassphrase,
      decoration: const InputDecoration(labelText: 'Type it again'),
      onSubmitted: (_) => _changePassphrase(),
    ),
    const SizedBox(height: 12),
    _hint(context, _sameKeyHint('passphrase')),
  ];

  List<Widget> _newRecoveryKeyBody(BuildContext context) => [
    const Text(
      'GPad makes a new recovery key for you to save, and the old one stops '
      'working on all your computers as they sync. Type your passphrase '
      'first.',
    ),
    const SizedBox(height: 12),
    ..._keyFields(onSubmitted: _makeRecoveryKey),
    const SizedBox(height: 12),
    _hint(context, _sameKeyHint('recovery key')),
  ];

  /// That the notes' own key stays the same, so an old [what] and an old
  /// copy of the synced files still open them.
  static String _sameKeyHint(String what) =>
      'GPad doesn\'t encrypt your notes again: their own key stays the same. '
      'Someone who has the old $what and a copy of your synced files from '
      'before could still open them. If that worries you, turn sync off on '
      'every computer and set it up afresh in a new place.';

  List<Widget> _signInBody(BuildContext context) => [
    Text(
      'Sync with ${sync.config?.place.description} is paused until GPad '
      'signs in to Google again on this computer. Changes made meanwhile '
      'wait here, and go up once it does.',
    ),
    if (sync.problem case final problem?) ...[
      const SizedBox(height: 8),
      _hint(context, problem),
    ],
    ..._waitingForBrowser(context),
  ];

  static String _capitalized(String text) =>
      text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

  List<Widget> _recoveryBody(BuildContext context) {
    final theme = Theme.of(context);
    return [
      const Text(
        'If you forget your passphrase, this key is the only other way to '
        'open your synced notes. Keep it somewhere safe and away from this '
        'computer: printed out, or in a password manager. GPad shows it '
        'only now.',
      ),
      if (_replacedRecoveryKey) ...[
        const SizedBox(height: 8),
        const Text('Your old recovery key no longer opens them.'),
      ],
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
        switch (config.place) {
          FolderPlace(:final path) => _fact(context, 'Sync folder', path),
          DrivePlace(:final account) => _fact(context, 'Google Drive', account),
        },
        _fact(context, 'This computer', config.deviceName),
        _fact(
          context,
          'Passphrase',
          _remembered
              ? 'Remembered in this computer\'s keychain'
              : 'Asked for each time GPad starts',
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: () => _go(_Page.changePassphrase),
              child: const Text('Change passphrase…'),
            ),
            OutlinedButton(
              onPressed: () => _go(_Page.newRecoveryKey),
              child: const Text('New recovery key…'),
            ),
          ],
        ),
      ],
      if (_changed case final changed?) ...[
        const SizedBox(height: 12),
        Text(changed),
      ],
      if (sync.unreadable.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(
          '${sync.unreadable.length == 1 ? 'One file' : '${sync.unreadable.length} files'} '
          'GPad syncs with couldn\'t be opened, so GPad left '
          '${sync.unreadable.length == 1 ? 'it' : 'them'} alone. A file '
          'changed by something other than GPad, damaged, or saved by a '
          'newer GPad reads this way. Changes here to the '
          '${sync.unreadable.length == 1 ? 'note in it wait until it' : 'notes in them wait until they'} '
          'can be read: update GPad, or delete a damaged file.',
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

  List<Widget> _keyFields({
    required VoidCallback onSubmitted,
    String label = 'Passphrase',
  }) => [
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
      _passphraseField(
        _passphrase,
        label: label,
        focusNode: _passphraseFocus,
        autofocus: true,
        onSubmitted: onSubmitted,
      ),
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

  Widget _passphraseField(
    TextEditingController controller, {
    String label = 'Passphrase',
    required FocusNode focusNode,
    required bool autofocus,
    required VoidCallback? onSubmitted,
  }) => TextField(
    controller: controller,
    focusNode: focusNode,
    autofocus: autofocus,
    obscureText: !_showPassphrase,
    decoration: InputDecoration(
      labelText: label,
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
