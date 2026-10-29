import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../notepad/notepad.dart';
import '../notes/note.dart';
import 'folder_backend.dart';
import 'keychain.dart';
import 'sync_backend.dart';
import 'sync_engine.dart';
import 'vault.dart';

enum SyncStatus {
  /// Sync isn't set up on this computer.
  off,

  /// Set up, but waiting for the passphrase.
  locked,

  syncing,

  /// In step as of [SyncController.lastSynced].
  synced,

  /// The last round failed; see [SyncController.problem]. Sync keeps
  /// trying.
  problem,
}

/// How sync is set up on this computer, saved with the settings. Holds
/// nothing secret: the vault file is public, and the key is in the
/// keychain or nowhere.
class SyncConfig {
  const SyncConfig({
    required this.folder,
    required this.vault,
    required this.deviceName,
  });

  factory SyncConfig.fromJson(Map<String, Object?> json) => SyncConfig(
    folder: json['folder'] as String,
    vault: VaultHeader.decode(base64.decode(json['vault'] as String)),
    deviceName: json['deviceName'] as String,
  );

  /// The sync folder.
  final String folder;

  /// The vault file as it was when this computer joined, so GPad can
  /// unlock while the folder is out of reach.
  final VaultHeader vault;

  /// This computer's name, as it appears on conflict copies.
  final String deviceName;

  Map<String, Object?> toJson() => {
    'backend': 'folder',
    'folder': folder,
    'vault': base64.encode(vault.encode()),
    'deviceName': deviceName,
  };
}

/// A folder someone picked to sync with.
class FolderCheck {
  const FolderCheck(this.path, this.vault);

  /// Where GPad will keep the notes: the folder, or a GPad folder in it.
  final String path;

  /// The vault already there, from another computer, if any.
  final VaultHeader? vault;
}

/// Sets sync up, keeps it running, and says how it's going.
///
/// Uploads a few seconds after a change is saved (at most [maxWait] after
/// the first, even while typing goes on), looks for changes from other
/// machines every [pollEvery] and whenever the sync folder changes, and
/// syncs once more before GPad quits.
class SyncController extends ChangeNotifier {
  SyncController(
    this.notepad, {
    Keychain? keychain,
    Future<VaultCrypto> Function()? crypto,
    this.kdf = KdfParams.moderate,
    this.uploadDelay = const Duration(seconds: 3),
    this.maxWait = const Duration(seconds: 20),
    this.pollEvery = const Duration(minutes: 1),
    this.hostName,
    @visibleForTesting SyncBackend Function(String folder)? backendFor,
  }) : keychain = keychain ?? Keychain.system(),
       _loadCrypto = crypto ?? VaultCrypto.load,
       _backendFor = backendFor ?? FolderBackend.new {
    notepad.onSaved = _changedHere;
  }

  final Notepad notepad;
  final Keychain keychain;
  final Future<VaultCrypto> Function() _loadCrypto;
  final SyncBackend Function(String folder) _backendFor;
  final KdfParams kdf;
  final Duration uploadDelay;
  final Duration maxWait;
  final Duration pollEvery;

  /// This computer's network name; the default comes from the system.
  final String? hostName;

  static const _configKey = 'sync';
  static const _deviceKey = 'device_id';
  static const _stateVaultKey = 'sync_state_vault';

  /// Passphrases shorter than this are refused.
  static const minPassphraseLength = 10;

  Future<VaultCrypto>? _crypto;
  Future<VaultCrypto> get _vaultCrypto => _crypto ??= _loadCrypto();

  SyncConfig? _config;
  SyncEngine? _engine;
  SyncStatus _status = SyncStatus.off;
  String? _problem;
  DateTime? _lastSynced;
  List<String> _unreadable = const [];
  Timer? _soon;
  DateTime? _firstPending;
  Timer? _poll;
  StreamSubscription<void>? _watch;
  Timer? _watchDelay;
  Future<void>? _running;
  bool _again = false;
  bool _disposed = false;

  SyncConfig? get config => _config;
  SyncStatus get status => _status;

  /// Why the last round failed, in words for people.
  String? get problem => _problem;
  DateTime? get lastSynced => _lastSynced;

  /// Files in the sync folder that couldn't be opened.
  List<String> get unreadable => _unreadable;

  /// What this computer is called, unless someone names it.
  String get defaultDeviceName {
    final name = hostName ?? Platform.localHostname;
    return name.isEmpty ? 'This computer' : name;
  }

  String get _deviceId {
    final store = notepad.store;
    final saved = store.setting(_deviceKey);
    if (saved != null) return saved;
    final id = newId();
    store.setSetting(_deviceKey, id);
    return id;
  }

  static String _keyName(String vaultId) => 'sync-key-$vaultId';

  /// Picks up sync as it was left: unlocks with the key in the keychain and
  /// starts, or waits for the passphrase.
  Future<void> start() async {
    final saved = notepad.store.setting(_configKey);
    if (saved == null) return;
    try {
      _config = SyncConfig.fromJson(jsonDecode(saved) as Map<String, Object?>);
    } on Object {
      // Not something this GPad wrote; sync stays off rather than guess.
      return;
    }
    _setStatus(SyncStatus.locked);
    final config = _config!;
    Uint8List? key;
    try {
      key = await keychain.read(_keyName(config.vault.id));
    } on Object {
      key = null;
    }
    if (key == null) return;
    final vault = (await _vaultCrypto).fromKey(config.vault, key);
    if (vault != null) _run(config, vault);
  }

  /// Looks at the folder someone picked: where the notes would go, and
  /// whether another computer already keeps notes there.
  Future<FolderCheck> checkFolder(String chosen) async {
    if (!await Directory(chosen).exists()) {
      throw const SyncBackendException('There is no folder there');
    }
    final path = FolderBackend.folderFor(chosen);
    final bytes = await _backendFor(path).readVault();
    return FolderCheck(path, bytes == null ? null : VaultHeader.decode(bytes));
  }

  /// Starts syncing into [folder], which has no vault yet, with notes
  /// locked by [passphrase]. Returns the recovery key, to show once.
  Future<String> create({
    required String folder,
    required String passphrase,
    required String deviceName,
    required bool remember,
  }) async {
    final made = await (await _vaultCrypto).create(passphrase, kdf: kdf);
    final bool created;
    try {
      created = await _backendFor(folder)
          .createVault(Uint8List.fromList(made.header.encode()));
    } catch (_) {
      made.vault.dispose();
      rethrow;
    }
    if (!created) {
      made.vault.dispose();
      throw const SyncBackendException(
        'Another computer just started syncing there. Choose the folder '
        'again to join it.',
      );
    }
    await _begin(folder, made.header, made.vault, deviceName, remember);
    return made.recoveryKey;
  }

  /// Joins the notes another computer keeps in [folder]. Returns false if
  /// [passphrase] (or [recoveryKey]) doesn't unlock them.
  Future<bool> join({
    required String folder,
    required VaultHeader vault,
    String? passphrase,
    String? recoveryKey,
    required String deviceName,
    required bool remember,
  }) async {
    final unlocked = await _unlock(vault, passphrase, recoveryKey);
    if (unlocked == null) return false;
    await _begin(folder, vault, unlocked, deviceName, remember);
    return true;
  }

  /// Unlocks sync after a restart on a computer without a keychain, or
  /// whose keychain lost the key. Returns false for a wrong passphrase.
  Future<bool> unlock({
    String? passphrase,
    String? recoveryKey,
    required bool remember,
  }) async {
    final config = _config;
    if (config == null) return false;
    final vault = await _unlock(config.vault, passphrase, recoveryKey);
    if (vault == null) return false;
    if (remember) await _remember(config.vault.id, vault);
    _run(config, vault);
    return true;
  }

  /// Whether the key is in the keychain, so GPad starts syncing without
  /// asking.
  Future<bool> get remembered async {
    final config = _config;
    if (config == null) return false;
    try {
      return await keychain.read(_keyName(config.vault.id)) != null;
    } on Object {
      return false;
    }
  }

  /// Stops syncing on this computer and forgets the key. Notes stay here
  /// and in the sync folder; what sync knew is kept, in case it is turned
  /// on again with the same notes.
  Future<void> turnOff() async {
    final config = _config;
    _stop();
    _config = null;
    notepad.store.deleteSetting(_configKey);
    if (config != null) {
      try {
        await keychain.delete(_keyName(config.vault.id));
      } on Object {
        // Nothing was remembered.
      }
    }
    _problem = null;
    _unreadable = const [];
    _setStatus(SyncStatus.off);
  }

  /// Syncs now, or once more after the round under way.
  Future<void> syncNow() {
    if (_engine == null) return Future.value();
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _round().whenComplete(() => _running = null);
  }

  /// Uploads what is waiting before GPad quits, giving up after [timeout]
  /// (it goes up next time GPad starts).
  Future<void> finish({Duration timeout = const Duration(seconds: 5)}) async {
    final engine = _engine;
    if (engine == null) return;
    notepad.flush();
    if (!engine.hasPending && _running == null) return;
    try {
      await syncNow().timeout(timeout);
    } on TimeoutException {
      // Picked up next time.
    }
  }

  Future<Vault?> _unlock(
    VaultHeader header,
    String? passphrase,
    String? recoveryKey,
  ) async {
    final crypto = await _vaultCrypto;
    if (recoveryKey != null) {
      return crypto.unlockWithRecoveryKey(header, recoveryKey);
    }
    return crypto.unlock(header, passphrase ?? '');
  }

  Future<void> _begin(
    String folder,
    VaultHeader header,
    Vault vault,
    String deviceName,
    bool remember,
  ) async {
    // A round still under way for the old setup stops before anything
    // here changes.
    _stop();
    final store = notepad.store;
    // What sync knows belongs to one vault; with another, start afresh.
    if (store.setting(_stateVaultKey) != header.id) {
      store.transaction(() {
        store.resetSync();
        store.setSetting(_stateVaultKey, header.id);
      });
    }
    final config = SyncConfig(
      folder: folder,
      vault: header,
      deviceName: deviceName.trim().isEmpty
          ? defaultDeviceName
          : deviceName.trim(),
    );
    store.setSetting(_configKey, jsonEncode(config.toJson()));
    _config = config;
    if (remember) await _remember(header.id, vault);
    _run(config, vault);
  }

  Future<void> _remember(String vaultId, Vault vault) async {
    try {
      await keychain.write(_keyName(vaultId), vault.exportKey());
    } on Object {
      // No keychain: GPad asks for the passphrase next time.
    }
  }

  void _run(SyncConfig config, Vault vault) {
    _stop();
    final backend = _backendFor(config.folder);
    _engine = SyncEngine(
      backend: backend,
      vault: vault,
      notepad: notepad,
      deviceId: _deviceId,
      deviceName: config.deviceName,
    );
    _poll = Timer.periodic(pollEvery, (_) => syncNow());
    _watchFolder(backend);
    syncNow();
  }

  /// Watches the sync folder, if it can be watched. Watching stops if the
  /// folder goes away; a round that works watches it again.
  void _watchFolder(SyncBackend backend) {
    _watch?.cancel();
    _watch = backend.changes?.listen(
      (_) {
        // Give other tools a moment to finish writing.
        _watchDelay?.cancel();
        _watchDelay = Timer(const Duration(seconds: 2), syncNow);
      },
      onError: (_) => _watch = null,
      onDone: () => _watch = null,
      cancelOnError: true,
    );
  }

  void _stop() {
    _soon?.cancel();
    _soon = null;
    _firstPending = null;
    _poll?.cancel();
    _poll = null;
    _watch?.cancel();
    _watch = null;
    _watchDelay?.cancel();
    final engine = _engine;
    _engine = null;
    if (engine == null) return;
    engine.cancel();
    // The key goes once the round using it has stopped.
    final running = _running;
    if (running == null) {
      engine.vault.dispose();
    } else {
      running.whenComplete(engine.vault.dispose).ignore();
    }
  }

  void _changedHere() {
    if (_engine == null) return;
    final now = DateTime.now();
    final first = _firstPending ??= now;
    _soon?.cancel();
    final wait = now.difference(first) >= maxWait ? Duration.zero : uploadDelay;
    _soon = Timer(wait, () {
      _firstPending = null;
      syncNow();
    });
  }

  Future<void> _round() async {
    do {
      _again = false;
      final engine = _engine;
      final config = _config;
      if (engine == null || config == null) return;
      _setStatus(SyncStatus.syncing);
      try {
        await _checkVault(engine.backend, config);
        final report = await engine.sync();
        if (_engine != engine) continue;
        if (_watch == null) _watchFolder(engine.backend);
        _unreadable = List.unmodifiable(report.unreadable);
        _problem = null;
        _lastSynced = DateTime.now();
        _setStatus(SyncStatus.synced);
      } on SyncCancelled {
        // Turned off, or set up again, meanwhile; a round asked for since
        // runs next.
      } on SyncBackendException catch (e) {
        _fail(engine, 'GPad can\'t reach ${config.folder}: ${e.message}');
      } on SyncException catch (e) {
        _fail(engine, e.message);
      }
      // Missing or replaced vault files are reported by _checkVault.
    } while (_again && !_disposed);
  }

  /// Makes sure the vault in the folder is still this computer's, so a
  /// missing drive or a folder someone emptied isn't mistaken for every
  /// note having been deleted.
  Future<void> _checkVault(SyncBackend backend, SyncConfig config) async {
    final bytes = await backend.readVault();
    if (bytes == null) {
      throw SyncException(
        'The sync folder ${config.folder} is missing, or its '
        '${FolderBackend.vaultFileName} is gone. If the folder is on a '
        'drive that isn\'t connected, connect it.',
      );
    }
    final VaultHeader header;
    try {
      header = VaultHeader.decode(bytes);
    } on FormatException catch (e) {
      throw SyncException('The vault file in the sync folder: ${e.message}');
    }
    if (header.id != config.vault.id) {
      throw const SyncException(
        'The sync folder now holds a different set of GPad notes. Turn '
        'sync off and on again to choose what to do.',
      );
    }
  }

  void _fail(SyncEngine engine, String message) {
    if (_engine != engine) return;
    _problem = message;
    _setStatus(SyncStatus.problem);
  }

  void _setStatus(SyncStatus status) {
    _status = status;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _stop();
    if (notepad.onSaved == _changedHere) notepad.onSaved = null;
    super.dispose();
  }
}
