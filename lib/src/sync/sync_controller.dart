import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../notepad/notepad.dart';
import '../notes/note.dart';
import 'drive_api.dart';
import 'drive_backend.dart';
import 'folder_backend.dart';
import 'google_auth.dart';
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

  /// Syncing through Google Drive, but Google signed GPad out, or it was
  /// never signed in on this computer. Waiting for
  /// [SyncController.signInAgain].
  signedOut,
}

/// Where synced notes are kept.
sealed class SyncPlace {
  const SyncPlace();

  factory SyncPlace.fromJson(Map<String, Object?> json) =>
      switch (json['backend']) {
        'drive' => DrivePlace(
          account: json['account'] as String,
          client: switch (json['client']) {
            final Map<String, Object?> client => GoogleClient.fromJson(client),
            _ => null,
          },
        ),
        _ => FolderPlace(json['folder'] as String),
      };

  /// Where, in words for people: a folder's path, or the Google account.
  String get description;

  Map<String, Object?> toJson();
}

/// A folder that a tool like Dropbox keeps in step, or a network drive.
final class FolderPlace extends SyncPlace {
  const FolderPlace(this.path);

  final String path;

  @override
  String get description => path;

  @override
  Map<String, Object?> toJson() => {'backend': 'folder', 'folder': path};
}

/// A GPad folder in someone's Google Drive.
final class DrivePlace extends SyncPlace {
  const DrivePlace({required this.account, this.client});

  /// The Google account's email address.
  final String account;

  /// The sign-in client the person set up themselves, or null for GPad's
  /// own. Every computer needs the same one: Google shows each client only
  /// the files it made.
  final GoogleClient? client;

  @override
  String get description => 'Google Drive ($account)';

  @override
  Map<String, Object?> toJson() => {
    'backend': 'drive',
    'account': account,
    if (client case final client?) 'client': client.toJson(),
  };
}

/// How sync is set up on this computer, saved with the settings. Holds
/// nothing secret: the vault file is public, and the key is in the
/// keychain or nowhere.
class SyncConfig {
  const SyncConfig({
    required this.place,
    required this.vault,
    required this.deviceName,
  });

  factory SyncConfig.fromJson(Map<String, Object?> json) => SyncConfig(
    place: SyncPlace.fromJson(json),
    vault: VaultHeader.decode(base64.decode(json['vault'] as String)),
    deviceName: json['deviceName'] as String,
  );

  final SyncPlace place;

  /// The vault file as it was when this computer joined, so GPad can
  /// unlock while the folder is out of reach.
  final VaultHeader vault;

  /// This computer's name, as it appears on conflict copies.
  final String deviceName;

  Map<String, Object?> toJson() => {
    ...place.toJson(),
    'vault': base64.encode(vault.encode()),
    'deviceName': deviceName,
  };
}

/// A place someone picked to sync with.
class PlaceCheck {
  const PlaceCheck(this.place, this.vault);

  /// Where GPad will keep the notes: for a folder, the folder or a GPad
  /// folder in it.
  final SyncPlace place;

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
    GoogleClient? googleClient,
    http.Client? httpClient,
    Future<void> Function(Uri url)? openBrowser,
    @visibleForTesting SyncBackend Function(String folder)? backendFor,
  }) : keychain = keychain ?? Keychain.system(),
       googleClient = googleClient ?? GoogleClient.builtIn,
       _http = httpClient ?? http.Client(),
       _ownsHttp = httpClient == null,
       _openBrowser = openBrowser ?? _launch,
       _loadCrypto = crypto ?? VaultCrypto.load,
       _backendFor = backendFor ?? FolderBackend.new {
    notepad.onSaved = _changedHere;
  }

  final Notepad notepad;
  final Keychain keychain;

  /// GPad's own Google sign-in client, or null in a build without one:
  /// then syncing through Drive needs the person's own.
  final GoogleClient? googleClient;
  final http.Client _http;
  final bool _ownsHttp;
  final Future<void> Function(Uri url) _openBrowser;
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

  /// The Google sign-in for the Drive this computer syncs with, if any.
  GoogleAuth? _google;

  /// A Google sign-in made to set sync up, until it is.
  ({DrivePlace place, GoogleAuth auth})? _signingUp;
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
  static String _googleKeyName(String vaultId) => 'sync-google-$vaultId';

  static Future<void> _launch(Uri url) async {
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Object {
      // The sync dialog shows the link to copy.
    }
  }

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
    if (config.place case final DrivePlace place) {
      await _loadGoogle(place, config.vault.id);
    }
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
  Future<PlaceCheck> checkFolder(String chosen) async {
    if (!await Directory(chosen).exists()) {
      throw const SyncBackendException('There is no folder there');
    }
    final path = FolderBackend.folderFor(chosen);
    final bytes = await _backendFor(path).readVault();
    return PlaceCheck(
      FolderPlace(path),
      bytes == null ? null : VaultHeader.decode(bytes),
    );
  }

  /// Signs in to Google in the browser, to sync through Drive, and looks
  /// for notes another computer keeps there. [showUrl] gets the sign-in
  /// link too, in case the browser doesn't open. Uses [ownClient], the
  /// person's own sign-in client, if given, otherwise GPad's.
  Future<PlaceCheck> signInToDrive({
    GoogleClient? ownClient,
    void Function(Uri url)? showUrl,
    Future<void>? cancel,
  }) async {
    final client = ownClient ?? googleClient;
    if (client == null) throw const GoogleAuthException(_noClient);
    final auth = await _signIn(client, showUrl, cancel);
    final api = DriveApi(() => auth, httpClient: _http);
    final account = await api.account();
    final place = DrivePlace(account: account, client: ownClient);
    final bytes = await DriveBackend(api, account: account).readVault();
    final vault = bytes == null ? null : VaultHeader.decode(bytes);
    _signingUp = (place: place, auth: auth);
    return PlaceCheck(place, vault);
  }

  /// Signs in to Google again, after it signed GPad out.
  Future<void> signInAgain({
    void Function(Uri url)? showUrl,
    Future<void>? cancel,
  }) async {
    final config = _config;
    if (config == null || config.place is! DrivePlace) return;
    final place = config.place as DrivePlace;
    final client = place.client ?? googleClient;
    if (client == null) throw const GoogleAuthException(_noClient);
    final auth = await _signIn(client, showUrl, cancel);
    final account = await DriveApi(() => auth, httpClient: _http).account();
    if (account.toLowerCase() != place.account.toLowerCase()) {
      throw GoogleAuthException(
        'That\'s $account. Sign in as ${place.account}, the account these '
        'notes sync through.',
      );
    }
    if (_config != config) return;
    _google = auth;
    await _rememberGoogle(config.vault.id, auth);
    syncNow();
  }

  static const _noClient =
      'This copy of GPad has no Google sign-in built in. Set up your own '
      'Google client and enter it here.';

  Future<GoogleAuth> _signIn(
    GoogleClient client,
    void Function(Uri url)? showUrl,
    Future<void>? cancel,
  ) => GoogleAuth.signIn(
    client,
    open: (url) async {
      showUrl?.call(url);
      await _openBrowser(url);
    },
    cancel: cancel,
    httpClient: _http,
  );

  /// The backend for setting up or joining [place].
  SyncBackend _setupBackend(SyncPlace place) => switch (place) {
    FolderPlace(:final path) => _backendFor(path),
    DrivePlace() => DriveBackend(
      DriveApi(() => _signingUpTo(place), httpClient: _http),
      account: place.account,
    ),
  };

  GoogleAuth _signingUpTo(DrivePlace place) {
    final signingUp = _signingUp;
    if (signingUp == null || signingUp.place != place) {
      throw const GoogleSignInNeeded('Sign in to Google first.');
    }
    return signingUp.auth;
  }

  /// Starts syncing into [place], which has no vault yet, with notes
  /// locked by [passphrase]. Returns the recovery key, to show once.
  Future<String> create({
    required SyncPlace place,
    required String passphrase,
    required String deviceName,
    required bool remember,
  }) async {
    final backend = _setupBackend(place);
    final made = await (await _vaultCrypto).create(passphrase, kdf: kdf);
    final bool created;
    try {
      created = await backend.createVault(
        Uint8List.fromList(made.header.encode()),
      );
    } catch (_) {
      made.vault.dispose();
      rethrow;
    }
    if (!created) {
      made.vault.dispose();
      throw SyncBackendException(switch (place) {
        FolderPlace() =>
          'Another computer just started syncing there. Choose the folder '
              'again to join it.',
        DrivePlace() =>
          'Another computer just started syncing with this Google Drive. '
              'Sign in again to join it.',
      });
    }
    await _begin(place, made.header, made.vault, deviceName, remember);
    return made.recoveryKey;
  }

  /// Joins the notes another computer keeps in [place]. Returns false if
  /// [passphrase] (or [recoveryKey]) doesn't unlock them.
  Future<bool> join({
    required SyncPlace place,
    required VaultHeader vault,
    String? passphrase,
    String? recoveryKey,
    required String deviceName,
    required bool remember,
  }) async {
    if (place is DrivePlace) _signingUpTo(place);
    final unlocked = await _unlock(vault, passphrase, recoveryKey);
    if (unlocked == null) return false;
    await _begin(place, vault, unlocked, deviceName, remember);
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

  /// Stops syncing on this computer and forgets the key, and the Google
  /// sign-in. Notes stay here and where they synced to; what sync knew is
  /// kept, in case it is turned on again with the same notes.
  Future<void> turnOff() async {
    final config = _config;
    _stop();
    _config = null;
    _google = null;
    _signingUp = null;
    notepad.store.deleteSetting(_configKey);
    if (config != null) {
      for (final name in [
        _keyName(config.vault.id),
        _googleKeyName(config.vault.id),
      ]) {
        try {
          await keychain.delete(name);
        } on Object {
          // Nothing was remembered.
        }
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
    SyncPlace place,
    VaultHeader header,
    Vault vault,
    String deviceName,
    bool remember,
  ) async {
    // A round still under way for the old setup stops before anything
    // here changes.
    _stop();
    final google = place is DrivePlace ? _signingUpTo(place) : null;
    _signingUp = null;
    final store = notepad.store;
    // What sync knows belongs to one vault; with another, start afresh.
    if (store.setting(_stateVaultKey) != header.id) {
      store.transaction(() {
        store.resetSync();
        store.setSetting(_stateVaultKey, header.id);
      });
    }
    final config = SyncConfig(
      place: place,
      vault: header,
      deviceName: deviceName.trim().isEmpty
          ? defaultDeviceName
          : deviceName.trim(),
    );
    store.setSetting(_configKey, jsonEncode(config.toJson()));
    _config = config;
    _google = google;
    if (google != null) await _rememberGoogle(header.id, google);
    if (remember) await _remember(header.id, vault);
    _run(config, vault);
  }

  /// Keeps the Google sign-in in the keychain, if there is one, so GPad
  /// stays signed in. Without one, GPad asks again after each start.
  Future<void> _rememberGoogle(String vaultId, GoogleAuth auth) async {
    try {
      await keychain.write(_googleKeyName(vaultId), auth.toSecret());
    } on Object {
      // No keychain.
    }
  }

  Future<void> _loadGoogle(DrivePlace place, String vaultId) async {
    final client = place.client ?? googleClient;
    Uint8List? secret;
    try {
      secret = await keychain.read(_googleKeyName(vaultId));
    } on Object {
      secret = null;
    }
    _google = client == null || secret == null
        ? null
        : GoogleAuth.fromSecret(client, secret, httpClient: _http);
  }

  /// Drops a sign-in Google no longer takes.
  Future<void> _forgetGoogle(SyncConfig config, GoogleAuth? auth) async {
    if (auth == null || _google != auth) return;
    _google = null;
    try {
      await keychain.delete(_googleKeyName(config.vault.id));
    } on Object {
      // Nothing was remembered.
    }
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
    final backend = switch (config.place) {
      FolderPlace(:final path) => _backendFor(path),
      DrivePlace(:final account) => DriveBackend(
        DriveApi(() => _google, httpClient: _http),
        account: account,
        vaultId: config.vault.id,
      ),
    };
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
      final google = _google;
      if (config.place is DrivePlace && google == null) {
        // Nothing to do until someone signs in.
        _setStatus(SyncStatus.signedOut);
        return;
      }
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
      } on GoogleSignInNeeded catch (e) {
        if (_engine != engine) continue;
        await _forgetGoogle(config, google);
        // Signed in again meanwhile, which asked for another round.
        if (_google != null) continue;
        _problem = e.message;
        _setStatus(SyncStatus.signedOut);
      } on SyncBackendException catch (e) {
        _fail(
          engine,
          'GPad can\'t reach ${config.place.description}: ${e.message}',
        );
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
      throw SyncException(switch (config.place) {
        FolderPlace(:final path) =>
          'The sync folder $path is missing, or its '
              '${FolderBackend.vaultFileName} is gone. If the folder is on a '
              'drive that isn\'t connected, connect it.',
        DrivePlace(:final account) =>
          'GPad\'s ${DriveBackend.vaultFileName} is gone from the Google '
              'Drive of $account. If its GPad folder is in the bin, restore '
              'it.',
      });
    }
    final VaultHeader header;
    try {
      header = VaultHeader.decode(bytes);
    } on FormatException catch (e) {
      throw SyncException(
        'The vault file in ${config.place.description}: ${e.message}',
      );
    }
    if (header.id != config.vault.id) {
      throw SyncException(switch (config.place) {
        FolderPlace() =>
          'The sync folder now holds a different set of GPad notes. Turn '
              'sync off and on again to choose what to do.',
        DrivePlace() =>
          '${config.place.description} holds a different set of GPad '
              'notes, perhaps set up on another computer at the same moment. '
              'Turn sync off and on again to join them.',
      });
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
    if (_ownsHttp) _http.close();
    if (notepad.onSaved == _changedHere) notepad.onSaved = null;
    super.dispose();
  }
}
