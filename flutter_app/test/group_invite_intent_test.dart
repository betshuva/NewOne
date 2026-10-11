import 'package:betshuva/group_invite_intent.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final firstToken = '${'A' * 41}_-';
  final secondToken = 'B' * 43;
  Uri invite(String token) => Uri.https('betshuva.com', '/betshuva-app/',
      {'groupInvite': token, 'unrelated': 'kept'});
  const store = GroupInviteIntentStore();

  test('accepts one 43-character base64url token and rejects malformed links',
      () {
    expect(GroupInviteIntentStore.tokenFromUri(invite(firstToken)), firstToken);
    for (final token in [
      '',
      'A' * 42,
      'A' * 44,
      '${'A' * 42}=',
      '${'A' * 42}/',
      '${'A' * 42}+',
      '${'A' * 42}\n',
      ' ${'A' * 42}',
      '${'A' * 42}א',
    ]) {
      expect(GroupInviteIntentStore.tokenFromUri(invite(token)), isNull);
    }
    expect(
        GroupInviteIntentStore.tokenFromUri(
            Uri.parse('https://betshuva.com/betshuva-app/')),
        isNull);
    expect(
        GroupInviteIntentStore.tokenFromUri(Uri.parse(
            'https://betshuva.com/?groupInvite=$firstToken&groupInvite=$secondToken')),
        isNull);
  });

  test('invite survives login navigation and a recreated store after reload',
      () async {
    expect(await store.captureFromUri(invite(firstToken)), firstToken);
    expect(await const GroupInviteIntentStore().read(), firstToken);
    expect(
        await const GroupInviteIntentStore()
            .captureFromUri(Uri.parse('https://betshuva.com/betshuva-app/')),
        firstToken);
    expect(await store.captureFromUri(invite('invalid')), firstToken);
  });

  test('successful join clears only that invite and ignores its URL on reload',
      () async {
    await store.captureFromUri(invite(firstToken));
    await store.consume(firstToken);
    expect(await const GroupInviteIntentStore().read(), isNull);
    expect(await store.captureFromUri(invite(firstToken)), isNull);
    expect(await store.captureFromUri(invite(secondToken)), secondToken);
  });

  test('older completion cannot erase a newer invite captured concurrently',
      () async {
    await store.captureFromUri(invite(firstToken));
    final capture =
        const GroupInviteIntentStore().captureFromUri(invite(secondToken));
    final completion = store.consume(firstToken);
    expect(await capture, secondToken);
    await completion;
    expect(await store.read(), secondToken);
    expect(await store.captureFromUri(invite(firstToken)), secondToken);
    await store.consume(secondToken);
    expect(await store.read(), isNull);
  });

  test('a new capture queued after completion stays pending', () async {
    await store.captureFromUri(invite(firstToken));
    final completion = store.consume(firstToken);
    final capture =
        const GroupInviteIntentStore().captureFromUri(invite(secondToken));
    await completion;
    expect(await capture, secondToken);
    expect(await store.read(), secondToken);
  });

  test('malformed persisted values cannot become invitations', () async {
    SharedPreferences.setMockInitialValues({
      'pending_group_invite_v1': 42,
      'consumed_group_invite_v1': 'invalid',
    });
    expect(await store.read(), isNull);
    expect(await store.captureFromUri(invite(firstToken)), firstToken);
  });

  test('invalid completion preserves the pending invite', () async {
    await store.captureFromUri(invite(firstToken));
    await expectLater(store.consume('invalid'), throwsArgumentError);
    expect(await store.read(), firstToken);
  });

  test('discarded revoked invite stays dismissed when its URL is reloaded',
      () async {
    await store.captureFromUri(invite(firstToken));
    await store.discard(firstToken);
    expect(await store.read(), isNull);
    expect(await store.captureFromUri(invite(firstToken)), isNull);
  });

  test('discarding an older invite preserves a newer pending invite', () async {
    await store.captureFromUri(invite(firstToken));
    await store.captureFromUri(invite(secondToken));
    await store.discard(firstToken);
    expect(await store.read(), secondToken);
  });

  test('completed invitation stays suppressed for the same account and startup',
      () async {
    await store.captureFromUri(invite(firstToken), accountId: 'account-a');
    await store.consume(firstToken, accountId: 'account-a');
    expect(await store.captureFromUri(invite(firstToken)), isNull);
    expect(
        await const GroupInviteIntentStore()
            .captureFromUri(invite(firstToken), accountId: 'account-a'),
        isNull);
  });

  test('different account can accept the same invitation after signing in',
      () async {
    await store.captureFromUri(invite(firstToken), accountId: 'account-a');
    await store.consume(firstToken, accountId: 'account-a');
    expect(await store.captureFromUri(invite(firstToken)), isNull);
    expect(
        await const GroupInviteIntentStore()
            .captureFromUri(invite(firstToken), accountId: 'account-b'),
        firstToken);
    expect(await store.read(), firstToken);
    await store.consume(firstToken, accountId: 'account-b');
    expect(await store.captureFromUri(invite(firstToken)), isNull);
    expect(
        await store.captureFromUri(invite(firstToken), accountId: 'account-b'),
        isNull);
  });

  test('discard remains global when switching to a different account',
      () async {
    await store.captureFromUri(invite(firstToken), accountId: 'account-a');
    await store.consume(firstToken, accountId: 'account-a');
    await store.discard(firstToken);
    expect(
        await store.captureFromUri(invite(firstToken), accountId: 'account-b'),
        isNull);
  });
}
