import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/store/instance_door.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('gpad_door'));
  tearDown(() => dir.deleteSync(recursive: true));

  File doorFile() => File(p.join(dir.path, InstanceDoor.fileName));

  test('a second GPad knocks, and the first shows its window', () async {
    var knocks = 0;
    final door = await InstanceDoor.open(dir.path, onKnock: () => knocks++);
    expect(door, isNotNull);
    expect(await InstanceDoor.knock(dir.path), isTrue);
    expect(knocks, 1);
    expect(await InstanceDoor.knock(dir.path), isTrue);
    expect(knocks, 2);

    await door!.close();
    expect(doorFile().existsSync(), isFalse);
    expect(await InstanceDoor.knock(dir.path), isFalse);
    expect(knocks, 2);
  });

  test('only a knock with the token opens the door', () async {
    var knocks = 0;
    final door = await InstanceDoor.open(dir.path, onKnock: () => knocks++);
    final json = jsonDecode(doorFile().readAsStringSync()) as Map;
    final port = json['port'] as int;

    Future<String> send(List<int> bytes) async {
      final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
      socket.add(bytes);
      await socket.flush();
      final reply = await utf8.decoder.bind(socket).join();
      socket.destroy();
      return reply;
    }

    expect(await send(utf8.encode('show wrong-token\n')), isEmpty);
    expect(await send(utf8.encode('hello\n')), isEmpty);
    // A long line without an end is cut off.
    expect(await send(List.filled(1000, 0x41)), isEmpty);
    expect(knocks, 0);
    expect(await send(utf8.encode('show ${json['token']}\n')), 'ok\n');
    expect(knocks, 1);
    await door!.close();
  });

  test(
    'without a door, or with a broken note of one, knocking fails',
    () async {
      expect(await InstanceDoor.knock(dir.path), isFalse);
      doorFile().writeAsStringSync('not json');
      expect(await InstanceDoor.knock(dir.path), isFalse);
      doorFile().writeAsStringSync(jsonEncode({'port': 0, 'token': 'x'}));
      expect(await InstanceDoor.knock(dir.path), isFalse);
      // A port nothing listens on any more.
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      doorFile().writeAsStringSync(jsonEncode({'port': port, 'token': 'x'}));
      expect(await InstanceDoor.knock(dir.path), isFalse);
    },
  );

  test('closing leaves a newer GPad\'s door alone', () async {
    final first = await InstanceDoor.open(dir.path, onKnock: () {});
    var knocks = 0;
    final second = await InstanceDoor.open(dir.path, onKnock: () => knocks++);
    await first!.close();
    expect(doorFile().existsSync(), isTrue);
    expect(await InstanceDoor.knock(dir.path), isTrue);
    expect(knocks, 1);
    await second!.close();
  });
}
