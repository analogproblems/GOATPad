import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

/// Lets a second GPad, started on the same notes, bring this one's window
/// to the front instead of saying GPad is already open: what the person
/// expects when this one is in the tray.
///
/// This GPad listens on the loopback interface only, on a port it writes
/// next to the notes with a random token. A knock with that token shows
/// the window, and that is all a knock can do.
class InstanceDoor {
  InstanceDoor._(this._server, this._file, this._token, this._onKnock);

  static const fileName = 'gpad.instance';
  static const _timeout = Duration(seconds: 3);

  final ServerSocket _server;
  final File _file;
  final String _token;
  final void Function() _onKnock;

  /// Starts listening for knocks on the notes in [dir], and calls [onKnock]
  /// for each. Returns null if it can't, and then a second GPad says GPad
  /// is already open, as before.
  static Future<InstanceDoor?> open(
    String dir, {
    required void Function() onKnock,
  }) async {
    final file = File(p.join(dir, fileName));
    ServerSocket? server;
    try {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final random = Random.secure();
      final token = [
        for (var i = 0; i < 16; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join();
      await file.writeAsString(
        jsonEncode({'port': server.port, 'token': token}),
        flush: true,
      );
      final door = InstanceDoor._(server, file, token, onKnock);
      server.listen(door._answer);
      return door;
    } on IOException {
      await server?.close();
      // So a second GPad doesn't knock on a port another program has now.
      try {
        await file.delete();
      } on IOException {
        // There was none.
      }
      return null;
    }
  }

  /// Asks the GPad that has the notes in [dir] open to show its window.
  /// Returns whether it did.
  static Future<bool> knock(String dir) async {
    try {
      final json = jsonDecode(await File(p.join(dir, fileName)).readAsString());
      if (json is! Map) return false;
      final port = json['port'];
      final token = json['token'];
      if (port is! int || port < 1 || port > 65535 || token is! String) {
        return false;
      }
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _timeout,
      );
      try {
        socket.write('show $token\n');
        await socket.flush();
        final reply = await utf8.decoder.bind(socket).join().timeout(_timeout);
        return reply == 'ok\n';
      } finally {
        socket.destroy();
      }
    } on IOException {
      return false;
    } on FormatException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// Reads one short line, and shows the window if it holds the token.
  void _answer(Socket socket) {
    final line = <int>[];
    final giveUp = Timer(_timeout, socket.destroy);
    late final StreamSubscription<List<int>> reading;
    reading = socket.listen(
      (bytes) {
        line.addAll(bytes);
        final end = line.indexOf(0x0a);
        if (end < 0) {
          if (line.length > 256) {
            giveUp.cancel();
            socket.destroy();
          }
          return;
        }
        giveUp.cancel();
        reading.cancel();
        final knocked = utf8.decode(line.sublist(0, end), allowMalformed: true);
        if (knocked == 'show $_token') {
          _onKnock();
          socket.write('ok\n');
        }
        socket.close().ignore();
      },
      onError: (Object _) {
        giveUp.cancel();
        socket.destroy();
      },
      cancelOnError: true,
    );
  }

  /// Stops listening, and takes the port away if it is still this door's.
  Future<void> close() async {
    await _server.close();
    try {
      final json = jsonDecode(await _file.readAsString());
      if (json is Map && json['token'] == _token) await _file.delete();
    } on IOException {
      // Gone already.
    } on FormatException {
      // Another GPad's, half written.
    }
  }
}
