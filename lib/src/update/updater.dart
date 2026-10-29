import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sodium/sodium_sumo.dart';

import '../store/note_store.dart';
import '../version.dart';
import 'installation.dart';
import 'release_manifest.dart';

/// Where updates come from: the GitHub repository whose releases GPad
/// takes, and the public key CI signs them with. Both are built in by CI.
class UpdateSource {
  const UpdateSource({
    required this.repository,
    required this.publicKey,
    this.site,
  });

  /// The source CI built in, or null in a build without one, as from
  /// `flutter run`: that build doesn't update itself.
  static UpdateSource? get builtIn {
    const repository = String.fromEnvironment('GPAD_UPDATE_REPO');
    const key = String.fromEnvironment('GPAD_UPDATE_KEY');
    const site = String.fromEnvironment('GPAD_UPDATE_SITE');
    final publicKey = ReleaseManifest.publicKeyFrom(key);
    if (!_repository.hasMatch(repository) || publicKey == null) return null;
    return UpdateSource(
      repository: repository,
      publicKey: publicKey,
      site: site.isEmpty ? null : Uri.parse(site),
    );
  }

  static final _repository = RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$');

  /// Like `analogproblems/GOATPad`.
  final String repository;

  /// The raw Ed25519 key that signs each release's manifest.
  final Uint8List publicKey;

  /// GitHub, unless a server stands in for it, as in tests.
  final Uri? site;

  Uri get _base =>
      (site ?? Uri.https('github.com')).replace(path: '/$repository/releases');

  /// The newest published release's [name]. Drafts and prereleases
  /// don't count.
  Uri latest(String name) => _file('latest/download/$name');

  /// Release [version]'s [name].
  Uri download(Version version, String name) =>
      _file('download/v$version/$name');

  /// The page that shows release [version] and its notes.
  Uri page(Version version) => _file('tag/v$version');

  Uri _file(String path) => _base.replace(path: '${_base.path}/$path');
}

enum UpdateStatus {
  /// This build doesn't update itself.
  off,

  /// Not checked yet.
  idle,
  checking,
  upToDate,
  downloading,

  /// Installed, and runs from the next start.
  ready,

  /// Out, but this installation, like the .deb, updates by hand.
  available,
  failed,
}

/// Keeps GPad up to date from its GitHub releases.
///
/// It asks for the newest release's manifest now and then, which tells it
/// the version and each download's size and SHA-256, and takes it only if
/// CI's signature over it checks out with the built-in key. A newer
/// version's download is checked against the manifest before it replaces
/// anything (see [Installation]). Nothing about the person or their notes
/// is sent: only plain requests for public files.
class Updater extends ChangeNotifier {
  Updater({
    required this.store,
    UpdateSource? source,
    Installation? installation,
    http.Client? client,
    Version? current,
    Future<Sodium> Function()? sodium,
    this.firstCheckAfter = const Duration(seconds: 30),
    this.checkEvery = const Duration(hours: 12),
  }) : source = source ?? UpdateSource.builtIn,
       installation = installation ?? Installation.detect(),
       current = current ?? Version.tryParse(gpadVersion)!,
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _sodium = sodium ?? _loadSodium {
    if (this.source == null) _status = UpdateStatus.off;
  }

  static const _settingKey = 'updates';

  static Future<Sodium> _loadSodium() async => SodiumSumoInit.init();

  /// How long after starting, and then how often, GPad looks for an update
  /// on its own.
  final Duration firstCheckAfter;
  final Duration checkEvery;

  final NoteStore store;
  final UpdateSource? source;
  final Installation installation;
  final Version current;
  final http.Client _client;
  final bool _ownsClient;
  final Future<Sodium> Function() _sodium;

  UpdateStatus _status = UpdateStatus.idle;
  Version? _newVersion;
  String? _problem;
  double? _progress;
  bool _dismissed = false;
  Future<void>? _checking;
  Timer? _timer;
  bool _disposed = false;

  UpdateStatus get status => _status;

  /// The version found, once there is a newer one.
  Version? get newVersion => _newVersion;

  /// Why the last check or update failed, or, with one ready, why
  /// restarting into it didn't work.
  String? get problem => _problem;

  /// How much of the download has come, from 0 to 1, while downloading.
  double? get progress => _progress;

  /// The page of the newer version found, with its notes and downloads.
  Uri? get releasePage => switch ((source, _newVersion)) {
    (final source?, final version?) => source.page(version),
    _ => null,
  };

  /// Whether GPad looks for updates on its own. It always can be asked.
  bool get automatic => store.setting(_settingKey) != 'manual';

  /// Whether to tell the person, above the notes, that an update is ready
  /// or out: until they say later.
  bool get showNotice =>
      !_dismissed &&
      (_status == UpdateStatus.ready || _status == UpdateStatus.available);

  void setAutomatic(bool on) {
    if (on) {
      store.deleteSetting(_settingKey);
    } else {
      store.setSetting(_settingKey, 'manual');
    }
    _changed();
  }

  /// Hides the notice until the next start.
  void dismiss() {
    _dismissed = true;
    _changed();
  }

  /// Tidies up after the last update, and starts looking for updates on
  /// their own, if that is on.
  Future<void> start() async {
    if (source == null) return;
    if (installation case WindowsFolderInstallation(:final dir)) {
      if (await WindowsFolderInstallation.cleanUp(dir) case final failure?) {
        _fail('The last update couldn\'t be installed ($failure)');
      }
    }
    _timer = Timer(firstCheckAfter, _checkOnItsOwn);
  }

  void _checkOnItsOwn() {
    if (_disposed) return;
    if (automatic) unawaited(check());
    _timer = Timer(checkEvery, _checkOnItsOwn);
  }

  /// Looks for a newer release, and downloads and installs it if this
  /// installation can. Once one is ready, waits for the restart.
  Future<void> check() {
    if (source == null || _status == UpdateStatus.ready) return Future.value();
    return _checking ??= _check().whenComplete(() => _checking = null);
  }

  Future<void> _check() async {
    final source = this.source!;
    _set(UpdateStatus.checking);
    try {
      final bytes = await _fetch(
        source.latest(ReleaseManifest.fileName),
        missing: true,
      );
      if (bytes == null) {
        // No release yet.
        _set(UpdateStatus.upToDate);
        return;
      }
      // Its signature from the same release, even if a newer one comes
      // out meanwhile; the version is checked by the signature below.
      final claimed = _claimedVersion(bytes);
      final signature = (await _fetch(
        source.download(claimed, ReleaseManifest.signatureName),
      ))!;
      final manifest = ReleaseManifest.verify(
        await _sodium(),
        bytes,
        signature,
        source.publicKey,
      );
      if (!(manifest.version > current)) {
        _set(UpdateStatus.upToDate);
        return;
      }
      _newVersion = manifest.version;
      final file = switch (installation.kind) {
        final kind? => manifest.files[kind],
        null => null,
      };
      if (file == null) {
        _set(UpdateStatus.available);
        return;
      }
      await _download(source, manifest.version, file);
      _set(UpdateStatus.ready);
    } on UpdateException catch (e) {
      _fail(e.message);
    } on TimeoutException {
      _fail('GitHub didn\'t answer in time');
    } on SocketException {
      _fail('GPad can\'t reach GitHub');
    } on http.ClientException {
      _fail('GPad can\'t reach GitHub');
    } on FileSystemException catch (e) {
      _fail('GPad couldn\'t save the update (${e.message})');
    } on Exception catch (e) {
      // Like a release zip that won't unzip.
      _fail('GPad couldn\'t update ($e)');
    }
  }

  /// The version [bytes] say they are, before checking they're signed.
  static Version _claimedVersion(Uint8List bytes) {
    try {
      if (jsonDecode(utf8.decode(bytes)) case {'version': final String text}
          when Version.tryParse(text) != null) {
        return Version.tryParse(text)!;
      }
    } on FormatException {
      // Below.
    }
    throw const UpdateException('The release\'s manifest is damaged');
  }

  /// A small file: the manifest or its signature. Null if [missing] and
  /// there is no such file.
  Future<Uint8List?> _fetch(Uri url, {bool missing = false}) async {
    final response = await _client
        .send(http.Request('GET', url))
        .timeout(const Duration(seconds: 30));
    if (response.statusCode == 404 && missing) {
      _discard(response);
      return null;
    }
    if (response.statusCode != 200) {
      _discard(response);
      throw UpdateException('GitHub answered ${response.statusCode}');
    }
    final body = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      body.add(chunk);
      if (body.length > ReleaseManifest.maxBytes) {
        throw const UpdateException('The release\'s manifest is too large');
      }
    }
    return body.takeBytes();
  }

  /// Lets go of a response without reading its body, which a server that
  /// stops sending would otherwise hold the check up with.
  static void _discard(http.StreamedResponse response) {
    final body = response.stream.listen(null, onError: (Object _) {});
    unawaited(body.cancel().then((_) {}, onError: (Object _) {}));
  }

  /// Downloads [file], checks it is the one the manifest describes, and
  /// installs it.
  Future<void> _download(
    UpdateSource source,
    Version version,
    ReleaseFile file,
  ) async {
    _progress = 0;
    _set(UpdateStatus.downloading);
    final target = installation.downloadTarget(file.name);
    final digest = _DigestSink();
    final hashing = sha256.startChunkedConversion(digest);
    var received = 0;
    var installed = false;
    try {
      // Opened first, and each write awaited, so a full disk stops the
      // download there and then.
      final output = await target.open(mode: FileMode.writeOnly);
      try {
        final response = await _client
            .send(http.Request('GET', source.download(version, file.name)))
            .timeout(const Duration(seconds: 30));
        if (response.statusCode != 200) {
          _discard(response);
          throw UpdateException(
            'GitHub answered ${response.statusCode} for ${file.name}',
          );
        }
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 60),
        )) {
          received += chunk.length;
          if (received > file.size) {
            throw const UpdateException(
              'The download is bigger than the release says',
            );
          }
          hashing.add(chunk);
          await output.writeFrom(chunk);
          _progress = received / file.size;
          _changed();
        }
      } finally {
        await output.close();
      }
      hashing.close();
      if (received != file.size || '${digest.value}' != file.sha256) {
        throw const UpdateException(
          'The download doesn\'t match the release, so GPad won\'t install '
          'it',
        );
      }
      await installation.install(target);
      installed = true;
    } finally {
      _progress = null;
      if (!installed) {
        try {
          await target.delete();
        } on FileSystemException {
          // Never written, or taken by the installation.
        }
      }
    }
  }

  /// Restarts GPad into the update that is ready, as the app does it: saving
  /// and uploading first, as quitting does. Set by the app.
  Future<void> Function()? onRestart;

  /// Restarts GPad into the update, when the person asks to.
  Future<void> restartNow() async => onRestart?.call();

  /// Has the new version start once GPad has quit, which the app does
  /// next. False if it couldn't, saying why in [problem]: GPad stays open,
  /// and the update stays ready to try again.
  Future<bool> launchAfterExit() async {
    try {
      await installation.restartAfterExit();
      return true;
    } on Exception catch (e) {
      _problem = switch (e) {
        ProcessException(:final message) => message,
        _ => '$e',
      };
      _changed();
      return false;
    }
  }

  /// Finishes an update that is ready as GPad quits, where it can't be
  /// finished while GPad runs.
  Future<void> finishAfterExit() async {
    if (_status == UpdateStatus.ready) await installation.finishAfterExit();
  }

  void _fail(String problem) {
    _problem = problem;
    _set(UpdateStatus.failed);
  }

  void _set(UpdateStatus status) {
    if (status != UpdateStatus.failed) _problem = null;
    _status = status;
    _changed();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    if (_ownsClient) _client.close();
    super.dispose();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
