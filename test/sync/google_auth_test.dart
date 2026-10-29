import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:goatpad/src/sync/google_auth.dart';

import 'fake_drive.dart';

void main() {
  late FakeDrive drive;

  setUp(() => drive = FakeDrive());

  Future<GoogleAuth> signIn({
    Future<void> Function(Uri url)? browser,
    Future<void>? cancel,
    Duration timeout = const Duration(minutes: 10),
  }) => GoogleAuth.signIn(
    FakeDrive.ownClient,
    open: browser ?? drive.allow,
    cancel: cancel,
    httpClient: drive.client,
    timeout: timeout,
  );

  test('signing in gets a lasting sign-in, checked with PKCE', () async {
    Uri? asked;
    final auth = await signIn(
      browser: (url) {
        asked = url;
        return drive.allow(url);
      },
    );
    expect(asked!.host, 'accounts.google.com');
    expect(
      asked!.queryParameters['redirect_uri'],
      startsWith('http://127.0.0.1:'),
    );
    expect(asked!.queryParameters['state'], hasLength(greaterThan(20)));
    // The fake only hands out a token for the verifier that matches.
    expect(drive.refreshTokens, contains(auth.refreshToken));
    expect(await auth.accessToken(), startsWith('access-'));
    expect(drive.requests, ['POST /token']);
  });

  test('a request that isn\'t Google coming back is ignored', () async {
    final auth = await signIn(
      browser: (url) async {
        await FakeDrive.comeBack(url, {'code': 'forged', 'state': 'wrong'});
        await drive.allow(url);
      },
    );
    expect(drive.refreshTokens, [auth.refreshToken]);
  });

  test('saying no, or cancelling, or waiting too long fails', () async {
    await expectLater(
      signIn(browser: drive.deny),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('cancelled'),
        ),
      ),
    );

    final cancel = Completer<void>();
    final cancelled = signIn(browser: (_) async {}, cancel: cancel.future);
    cancel.complete();
    await expectLater(cancelled, throwsA(isA<GoogleAuthException>()));

    await expectLater(
      signIn(browser: (_) async {}, timeout: const Duration(milliseconds: 50)),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('too long'),
        ),
      ),
    );
    expect(drive.refreshTokens, isEmpty);
  });

  test('leaving the Drive box unticked is refused', () async {
    drive.grantedScope = 'openid';
    await expectLater(
      signIn(),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('leave that box ticked'),
        ),
      ),
    );
  });

  test('a client Google doesn\'t know is reported', () async {
    await expectLater(
      GoogleAuth.signIn(
        const GoogleClient(id: 'someone-else', secret: 'nope'),
        open: drive.allow,
        httpClient: drive.client,
      ),
      throwsA(
        isA<GoogleAuthException>().having(
          (e) => e.message,
          'message',
          contains('check its ID and secret'),
        ),
      ),
    );
  });

  test('access tokens are reused until they nearly run out', () async {
    final signedIn = await signIn();
    var now = DateTime(2026, 10, 29, 12);
    final auth = GoogleAuth(
      FakeDrive.ownClient,
      signedIn.refreshToken,
      httpClient: drive.client,
      clock: () => now,
    );
    drive.requests.clear();
    final first = await auth.accessToken();
    expect(await auth.accessToken(), first);
    // Two at once share one refresh.
    final both = await Future.wait([auth.accessToken(), auth.accessToken()]);
    expect(both, [first, first]);
    expect(drive.requests, hasLength(1));

    now = now.add(const Duration(minutes: 59));
    final second = await auth.accessToken();
    expect(second, isNot(first));
    expect(drive.requests, hasLength(2));

    // Refused early: a new one next time.
    auth.refused(second);
    expect(await auth.accessToken(), isNot(second));
  });

  test('a revoked sign-in asks to sign in again', () async {
    final auth = await signIn();
    auth.refused(await auth.accessToken());
    drive.revokeAll();
    await expectLater(auth.accessToken(), throwsA(isA<GoogleSignInNeeded>()));
  });

  test('a sign-in survives the keychain, for its own client only', () async {
    final auth = await signIn();
    final secret = auth.toSecret();
    expect(
      GoogleAuth.fromSecret(FakeDrive.ownClient, secret)!.refreshToken,
      auth.refreshToken,
    );
    expect(
      GoogleAuth.fromSecret(
        const GoogleClient(id: 'another', secret: 'x'),
        secret,
      ),
      isNull,
    );
    expect(
      GoogleAuth.fromSecret(FakeDrive.ownClient, Uint8List.fromList([1, 2])),
      isNull,
    );
  });
}
