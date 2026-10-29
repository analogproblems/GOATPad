import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/notepad/notepad.dart';
import 'package:goatpad/src/notes/note.dart';
import 'package:goatpad/src/store/note_store.dart';
import 'package:goatpad/src/sync/drive_api.dart';
import 'package:goatpad/src/sync/drive_backend.dart';
import 'package:goatpad/src/sync/google_auth.dart';
import 'package:goatpad/src/sync/sync_backend.dart';
import 'package:goatpad/src/sync/sync_engine.dart';
import 'package:goatpad/src/sync/vault.dart';

import 'fake_drive.dart';

void main() {
  late VaultCrypto crypto;
  late NewVault made;
  late FakeDrive drive;

  setUpAll(() async {
    crypto = await VaultCrypto.load();
    made = await crypto.create('passphrase', kdf: KdfParams.insecureForTests);
  });

  setUp(() => drive = FakeDrive());

  Uint8List header([NewVault? vault]) =>
      Uint8List.fromList((vault ?? made).header.encode());

  /// A computer signed in to [drive].
  DriveApi api({int tries = 5}) {
    final token = 'refresh-${drive.refreshTokens.length}';
    drive.refreshTokens.add(token);
    final auth = GoogleAuth(
      FakeDrive.ownClient,
      token,
      httpClient: drive.client,
    );
    return DriveApi(
      () => auth,
      httpClient: drive.client,
      retryDelay: Duration.zero,
      tries: tries,
    );
  }

  DriveBackend backend({String? vaultId}) => DriveBackend(
    api(),
    account: drive.account,
    vaultId: vaultId ?? made.header.id,
  );

  Uint8List bytes(String text) => Uint8List.fromList(text.codeUnits);

  const record = '0123456789abcdef0123456789abcdef';

  group('Drive calls', () {
    test('Google asking GPad to slow down is waited out', () async {
      drive
        ..failNext('GET', '/drive/v3/about', 429)
        ..failNext('GET', '/drive/v3/about', 503)
        ..failNext(
          'GET',
          '/drive/v3/about',
          403,
          reason: 'userRateLimitExceeded',
        );
      expect(await api().account(), 'jason@example.com');

      drive.failNext('GET', '/drive/v3/about', 500, times: 3);
      await expectLater(
        api(tries: 3).account(),
        throwsA(
          isA<SyncBackendException>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    });

    test('a refused access token is renewed once', () async {
      final calls = api();
      expect(await calls.account(), isNotEmpty);
      drive.expireAccessTokens();
      expect(await calls.account(), isNotEmpty);

      // Refused even when new: signed out.
      drive.failNext('GET', '/drive/v3/about', 401, times: 2);
      await expectLater(calls.account(), throwsA(isA<GoogleSignInNeeded>()));
    });

    test('no sign-in, or a full Drive, says so', () async {
      await expectLater(
        DriveApi(() => null, httpClient: drive.client).account(),
        throwsA(isA<GoogleSignInNeeded>()),
      );
      drive.failNext(
        'POST',
        '/upload/drive/v3/files',
        403,
        reason: 'storageQuotaExceeded',
      );
      await expectLater(
        api().create(name: 'x', content: bytes('x')),
        throwsA(
          isA<SyncBackendException>().having(
            (e) => e.message,
            'message',
            'Your Google Drive is full',
          ),
        ),
      );
    });

    test('long lists come page by page, and quotes are escaped', () async {
      final calls = api();
      for (var i = 0; i < 5; i++) {
        await calls.create(
          name: "it's $i",
          appProperties: {'gpad': 'test'},
          content: bytes('$i'),
        );
      }
      drive.pageSize = 2;
      final listed = await calls.list(
        "appProperties has { key='gpad' and value='test' } and trashed = false",
      );
      expect(listed, hasLength(5));
      expect(
        await calls.list('name = ${DriveApi.quote("it's 3")}'),
        hasLength(1),
      );
      expect(
        drive.requests.where((r) => r == 'GET /drive/v3/files'),
        hasLength(4),
      );
    });

    test('files go up whole, with their contents', () async {
      final calls = api();
      final content = Uint8List.fromList(List.generate(300, (i) => i % 256));
      final file = await calls.create(
        name: 'r.gpad',
        appProperties: {'gpad': 'record'},
        content: content,
      );
      expect(await calls.download(file.id), content);
      final updated = await calls.update(file.id, bytes('new'));
      expect(updated!.headRevisionId, isNot(file.headRevisionId));
      expect(await calls.download(file.id), bytes('new'));
      await calls.delete(file.id);
      expect(await calls.download(file.id), isNull);
      expect(await calls.update(file.id, bytes('x')), isNull);
      expect(await calls.get(file.id), isNull);
    });
  });

  group('vault', () {
    test('setting up makes a GPad folder, once', () async {
      final first = backend();
      expect(await first.readVault(), isNull);
      expect(await first.createVault(header()), isTrue);
      expect(await first.readVault(), header());

      final folder = drive.tagged('folder').single;
      expect(folder.name, 'GPad');
      expect(folder.parents, ['root']);
      final vault = drive.tagged('vault').single;
      expect(vault.name, DriveBackend.vaultFileName);
      expect(vault.parents, [folder.id]);
      expect(drive.tagged('records').single.parents, [folder.id]);

      // Read again only once it changes.
      drive.requests.clear();
      await first.readVault();
      expect(drive.requests, ['GET /drive/v3/files']);

      final other = await crypto.create(
        'other',
        kdf: KdfParams.insecureForTests,
      );
      expect(await backend().createVault(header(other)), isFalse);
      expect(drive.tagged('vault'), hasLength(1));
      expect(drive.tagged('folder'), hasLength(1));
    });

    test('a setup that stalls can\'t replace a vault made meanwhile', () async {
      final other = await crypto.create(
        'other',
        kdf: KdfParams.insecureForTests,
      );
      final stalled = backend();
      final quick = backend(vaultId: other.header.id);
      stalled.beforePublish = () async {
        expect(await quick.createVault(header(other)), isTrue);
      };
      expect(await stalled.createVault(header()), isFalse);
      // The quick one's vault stands, and the stalled one left nothing.
      expect(await backend().readVault(), header(other));
      expect(drive.tagged('vault'), hasLength(1));
      expect(drive.tagged('folder'), hasLength(1));
      expect(drive.tagged('records'), hasLength(1));
    });

    test('of two setting up at once, exactly one wins', () async {
      for (var round = 0; round < 20; round++) {
        drive = FakeDrive();
        final other = await crypto.create(
          'other',
          kdf: KdfParams.insecureForTests,
        );
        final won = await Future.wait([
          backend().createVault(header()),
          backend(vaultId: other.header.id).createVault(header(other)),
        ]);
        expect(won.where((w) => w), hasLength(1), reason: 'round $round');
        final winner = won[0] ? made : other;
        expect(await backend().readVault(), header(winner));
      }
    });

    test('a vault in the bin is missing', () async {
      await backend().createVault(header());
      drive.trash(drive.tagged('folder').single.id);
      expect(await backend().readVault(), isNull);
    });
  });

  group('records', () {
    late DriveBackend work;

    setUp(() async {
      work = backend();
      await work.createVault(header());
    });

    test('a written file is listed, read and rewritten in place', () async {
      final written = await work.write(record, bytes('one'));
      expect(written.name, '$record.gpad');
      final listed = (await work.list()).single;
      expect((listed.name, listed.tag), (written.name, written.tag));
      expect(await work.read(listed), bytes('one'));

      final again = await work.write(record, bytes('two'));
      expect(again.tag, isNot(written.tag));
      expect(drive.tagged('record'), hasLength(1));
      expect(drive.tagged('record').single.parents, [
        drive.tagged('records').single.id,
      ]);
    });

    test('the tag is the written version, even if replaced at once', () async {
      final home = backend();
      await home.list();
      await work.write(record, bytes('one'));
      await home.list();
      drive.after = (request) async {
        if (request.method != 'PATCH') return;
        drive.after = null;
        await home.write(record, bytes('home'));
      };
      final written = await work.write(record, bytes('work'));
      final now = (await work.list()).single;
      expect(now.tag, isNot(written.tag));
      expect(await work.read(now), bytes('home'));
    });

    test('other vaults, the bin and renamed files are left out', () async {
      await work.write(record, bytes('mine'));
      final other = backend(vaultId: 'f' * 32);
      await other.write('a' * 32, bytes('theirs'));
      final renamed = await work.write('b' * 32, bytes('renamed'));
      drive.files.values.firstWhere((f) => f.name == renamed.name).name =
          'notes.txt';
      final binned = await work.write('c' * 32, bytes('binned'));
      drive.trash(
        drive.files.values.firstWhere((f) => f.name == binned.name).id,
      );
      expect([for (final f in await work.list()) f.name], ['$record.gpad']);
    });

    test('a note made twice counts the older file as its own', () async {
      // Two computers that each didn't see the other's file yet.
      await work.write(record, bytes('first'));
      final home = backend();
      drive.hiddenFromLists.addAll(drive.tagged('record').map((f) => f.id));
      await home.list();
      await home.write(record, bytes('second'));
      drive.hiddenFromLists.clear();

      final listed = await work.list();
      expect(listed, hasLength(2));
      final own = listed.firstWhere((f) => f.isCanonical);
      final copy = listed.firstWhere((f) => !f.isCanonical);
      expect(await work.read(own), bytes('first'));
      expect(await work.read(copy), bytes('second'));
      expect(copy.recordId, record);

      // Writes go to the older one.
      await work.write(record, bytes('merged'));
      expect(await work.read(own), bytes('merged'));
      expect(await work.read(copy), bytes('second'));

      // The copy goes only if it is still the version that was read.
      final copyFile = drive
          .tagged('record')
          .firstWhere((f) => f.revision == 1);
      copyFile
        ..content = bytes('changed')
        ..revision += 1;
      expect(await work.deleteIfUnchanged(copy), isFalse);
      final changed = (await work.list()).firstWhere((f) => !f.isCanonical);
      expect(await work.read(changed), bytes('changed'));
      expect(await work.deleteIfUnchanged(changed), isTrue);
      expect(drive.tagged('record'), hasLength(1));
    });

    test('a file or records folder deleted meanwhile is made again', () async {
      await work.write(record, bytes('one'));
      await work.list();
      drive.files.removeWhere((_, f) => f.appProperties['gpad'] == 'record');
      await work.write(record, bytes('two'));
      expect(drive.tagged('record'), hasLength(1));

      final records = drive.tagged('records').single;
      drive.files.remove(records.id);
      drive.files.removeWhere((_, f) => f.appProperties['gpad'] == 'record');
      final fresh = backend();
      await fresh.list();
      await fresh.write(record, bytes('three'));
      final remade = drive.tagged('records').single;
      expect(remade.parents, [drive.tagged('folder').single.id]);
      expect(drive.tagged('record').single.parents, [remade.id]);
    });

    test(
      'a computer finds its records folder gone, and makes another',
      () async {
        await work.list();
        await work.write(record, bytes('one'));

        // Deleted between two uploads.
        await api().delete(drive.tagged('records').single.id);
        await work.write('a' * 32, bytes('two'));
        final remade = drive.tagged('records').single;
        expect(remade.parents, [drive.tagged('folder').single.id]);
        expect(drive.tagged('record').single.parents, [remade.id]);

        // In the bin by the next round, where new files would be binned too.
        drive.trash(remade.id);
        await work.list();
        await work.write('b' * 32, bytes('three'));
        final again = drive.tagged('records').single;
        expect(again.id, isNot(remade.id));

        // Looked for once a round, not for each new file.
        drive.requests.clear();
        await work.write('c' * 32, bytes('four'));
        expect(drive.requests, ['POST /upload/drive/v3/files']);
        expect(
          {for (final f in await work.list()) f.recordId},
          {'b' * 32, 'c' * 32},
        );
        for (final file in drive.tagged('record')) {
          expect(file.parents, [again.id]);
        }
      },
    );
  });

  group('two computers through Drive', () {
    late Vault homeVault;

    setUp(() async {
      await backend().createVault(header());
      homeVault = crypto.fromKey(made.header, made.vault.exportKey())!;
    });

    SyncEngine engineFor(Notepad notepad, String name, Vault vault) =>
        SyncEngine(
          backend: backend(),
          vault: vault,
          notepad: notepad,
          deviceId: '$name-id',
          deviceName: name,
        );

    Note write(Notepad notepad, String title, String text) {
      final note = notepad.newNote();
      notepad.editText(note, text);
      notepad.rename(note, title);
      return note;
    }

    Note find(Notepad notepad, String title) =>
        notepad.keptNotes.firstWhere((n) => n.title == title);

    test('a note written at work turns up at home, and back', () async {
      final workPad = Notepad.load(NoteStore.inMemory());
      final homePad = Notepad.load(NoteStore.inMemory());
      final work = engineFor(workPad, 'Work PC', made.vault);
      final home = engineFor(homePad, 'Home laptop', homeVault);

      write(workPad, 'SQL', 'select * from orders');
      expect((await work.sync()).uploaded, 1);
      expect((await home.sync()).downloaded, 1);
      expect(find(homePad, 'SQL').text, 'select * from orders');

      homePad.editText(find(homePad, 'SQL'), 'select 1');
      await home.sync();
      await work.sync();
      expect(find(workPad, 'SQL').text, 'select 1');
      expect(drive.tagged('record'), hasLength(1));
      // Nothing readable in Drive.
      final stored = String.fromCharCodes(
        drive.tagged('record').single.content!,
      );
      expect(stored, isNot(contains('select')));
    });

    test('a note changed on both at once is kept twice', () async {
      final workPad = Notepad.load(NoteStore.inMemory());
      final homePad = Notepad.load(NoteStore.inMemory());
      final work = engineFor(workPad, 'Work PC', made.vault);
      final home = engineFor(homePad, 'Home laptop', homeVault);
      write(workPad, 'List', 'eggs');
      await work.sync();
      await home.sync();

      workPad.editText(find(workPad, 'List'), 'eggs\nbread');
      homePad.editText(find(homePad, 'List'), 'eggs\nmilk');
      await work.sync();
      final report = await home.sync();
      expect(report.conflicts, 1);
      await work.sync();
      for (final pad in [workPad, homePad]) {
        expect({
          for (final n in pad.keptNotes) n.title: n.text,
        }, containsPair('List (conflict from Work PC)', 'eggs\nbread'));
        expect(find(pad, 'List').text, 'eggs\nmilk');
      }
    });

    test('a note uploaded twice at once ends up as one file', () async {
      final workPad = Notepad.load(NoteStore.inMemory());
      final homePad = Notepad.load(NoteStore.inMemory());
      final work = engineFor(workPad, 'Work PC', made.vault);
      final home = engineFor(homePad, 'Home laptop', homeVault);
      write(workPad, 'Plan', 'v1');
      await work.sync();
      await home.sync();

      // Someone deleted the file by hand; both put it back, and home's
      // Drive search hasn't seen work's yet.
      drive.files.removeWhere((_, f) => f.appProperties['gpad'] == 'record');
      workPad.editText(find(workPad, 'Plan'), 'v2 from work');
      await work.sync();
      drive.hiddenFromLists.addAll(drive.tagged('record').map((f) => f.id));
      await home.sync();
      drive.hiddenFromLists.clear();
      expect(drive.tagged('record'), hasLength(2));

      await work.sync();
      await home.sync();
      await work.sync();
      // One file per note again. Home's copy came back without the change
      // made at work, from a version work can't place, so its text is kept
      // too, as it would be through a sync folder.
      final names = [for (final f in drive.tagged('record')) f.name];
      expect(names.toSet(), hasLength(names.length));
      Map<String, String> notes(Notepad pad) => {
        for (final n in pad.keptNotes) n.title: n.text,
      };
      expect(notes(workPad), notes(homePad));
      expect(notes(workPad), containsPair('Plan', 'v2 from work'));
      expect(
        notes(workPad),
        containsPair('Plan (conflict from Home laptop)', 'v1'),
      );
    });

    test('a change in a second file reaches the note\'s own file', () async {
      final workPad = Notepad.load(NoteStore.inMemory());
      final homePad = Notepad.load(NoteStore.inMemory());
      final work = engineFor(workPad, 'Work PC', made.vault);
      final home = engineFor(homePad, 'Home laptop', homeVault);
      write(workPad, 'Plan', 'v1');
      await work.sync();
      await home.sync();

      // Home's Drive search misses the note's file, so home's edit goes
      // into a second one.
      drive.hiddenFromLists.addAll(drive.tagged('record').map((f) => f.id));
      homePad.editText(find(homePad, 'Plan'), 'v2');
      await home.sync();
      drive.hiddenFromLists.clear();
      expect(drive.tagged('record'), hasLength(2));

      // Work, which changed nothing, takes the edit and deletes that file.
      await work.sync();
      expect(find(workPad, 'Plan').text, 'v2');
      expect(drive.tagged('record'), hasLength(1));

      // A computer joining now gets the edit, though home hasn't synced
      // since.
      final laptopPad = Notepad.load(NoteStore.inMemory());
      await engineFor(
        laptopPad,
        'Laptop',
        crypto.fromKey(made.header, made.vault.exportKey())!,
      ).sync();
      expect(find(laptopPad, 'Plan').text, 'v2');

      await home.sync();
      expect(find(homePad, 'Plan').text, 'v2');
      expect(drive.tagged('record'), hasLength(1));
    });

    test('a vault from another setup can\'t be synced into', () async {
      final pad = Notepad.load(NoteStore.inMemory());
      final other = await crypto.create(
        'other',
        kdf: KdfParams.insecureForTests,
      );
      final engine = SyncEngine(
        backend: backend(vaultId: other.header.id),
        vault: other.vault,
        notepad: pad,
        deviceId: 'x',
        deviceName: 'X',
      );
      write(pad, 'Mine', 'text');
      await engine.sync();
      // Its files stay out of this vault's lists.
      expect(await backend().list(), isEmpty);
    });
  });
}
