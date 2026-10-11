import 'dart:async';
import 'dart:convert';

import 'package:betshuva/group_invite_join.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const api = 'https://betshuva.com/betshuva-app/api';
  const sessionToken = 'private-session-token';
  final inviteToken = 'A' * 43;
  final group = <String, dynamic>{
    'id': 'shared-group',
    'name': 'משפחת אליהו',
    'status': 'member',
    'role': 'member',
    'member_count': 12,
    'share_phone': false,
    'profile_pic_url': null,
    'filter_override': {'nonHumanImages': true, 'modestImages': false},
  };

  Future<Map<String, dynamic>> join({String? token, String endpoint = api}) =>
      joinSharedGroupInvite(
          api: endpoint,
          sessionToken: sessionToken,
          inviteToken: token ?? inviteToken);
  http.Response jsonResponse(Object value, [int status = 200]) =>
      http.Response(jsonEncode(value), status,
          headers: {'content-type': 'application/json; charset=utf-8'});

  for (final alreadyMember in [false, true]) {
    test('joins with Bearer and empty JSON; alreadyMember=$alreadyMember',
        () async {
      final returnedGroup = {
        ...group,
        'role': alreadyMember ? 'admin' : 'member'
      };
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.toString(), '$api/group-invites/$inviteToken/join');
        expect(request.headers['Authorization'], 'Bearer $sessionToken');
        expect(request.headers['Content-Type'], 'application/json');
        expect(jsonDecode(request.body), isEmpty);
        return jsonResponse(
            {'group': returnedGroup, 'alreadyMember': alreadyMember});
      });
      final result =
          await http.runWithClient(() => join(endpoint: '$api/'), () => client);
      expect(result, returnedGroup);
      expect(result['share_phone'], isFalse);
      expect(result['filter_override'], group['filter_override']);
      expect(result['name'], 'משפחת אליהו');
    });
  }

  test('malformed invitation never reaches HTTP or exposes its value',
      () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return jsonResponse({'group': group});
    });
    await http.runWithClient(() async {
      for (final token in [
        '',
        'A' * 42,
        'A' * 44,
        '${'A' * 42}/',
        '${'A' * 42}=',
        '${'A' * 42}\n',
      ]) {
        await expectLater(
            join(token: token),
            throwsA(isA<GroupInviteJoinException>()
                .having((error) => error.code, 'code', 'INVALID_GROUP_INVITE')
                .having((error) => error.terminal, 'terminal', isFalse)
                .having((error) => error.toString(), 'safe message',
                    'קישור ההזמנה אינו תקין')));
      }
    }, () => client);
    expect(calls, 0);
  });

  test('empty session fails locally with an authentication error', () async {
    var called = false;
    final client = MockClient((request) async {
      called = true;
      return jsonResponse({'group': group});
    });
    await http.runWithClient(() async {
      await expectLater(
          joinSharedGroupInvite(
              api: api, sessionToken: ' ', inviteToken: inviteToken),
          throwsA(isA<GroupInviteJoinException>()
              .having((error) => error.statusCode, 'status', 401)));
    }, () => client);
    expect(called, isFalse);
  });

  for (final invalidGroup in [
    null,
    [],
    <String, dynamic>{},
    {...group, 'id': ''},
    {...group, 'id': 12},
    {...group, 'name': '  '},
    {...group, 'status': 'pending'},
    {...group, 'role': null},
    {...group, 'role': ''},
  ]) {
    test('rejects invalid group response $invalidGroup', () async {
      final client = MockClient((request) async =>
          jsonResponse({'group': invalidGroup, 'alreadyMember': false}));
      await http.runWithClient(() async {
        await expectLater(
            join(),
            throwsA(isA<GroupInviteJoinException>()
                .having((error) => error.statusCode, 'status', 200)
                .having((error) => error.code, 'code',
                    'INVALID_GROUP_INVITE_RESPONSE')
                .having((error) => error.terminal, 'terminal', isFalse)));
      }, () => client);
    });
  }

  for (final body in ['not-json', '[]', 'null', '"string"']) {
    test('rejects malformed successful response $body', () async {
      final client = MockClient((request) async => http.Response(body, 200));
      await http.runWithClient(() async {
        await expectLater(
            join(),
            throwsA(isA<GroupInviteJoinException>().having(
                (error) => error.code,
                'code',
                'INVALID_GROUP_INVITE_RESPONSE')));
      }, () => client);
    });
  }

  for (final status in [401, 403, 404, 410, 429, 500, 503]) {
    test('HTTP $status preserves status and distinguishes terminal failures',
        () async {
      final client = MockClient((request) async => jsonResponse({
            'error': 'Server echoed $inviteToken and $sessionToken',
            'code': 'GROUP_INVITE_UNAVAILABLE',
          }, status));
      await http.runWithClient(() async {
        try {
          await join();
          fail('Join must fail');
        } on GroupInviteJoinException catch (error) {
          expect(error.statusCode, status);
          expect(error.code, 'GROUP_INVITE_UNAVAILABLE');
          expect(error.terminal, status == 404 || status == 410);
          expect(error.toString(), isNot(contains(inviteToken)));
          expect(error.toString(), isNot(contains(sessionToken)));
        }
      }, () => client);
    });
  }

  test('non-JSON revoked response is still terminal', () async {
    final client = MockClient((request) async => http.Response('expired', 404));
    await http.runWithClient(() async {
      await expectLater(
          join(),
          throwsA(isA<GroupInviteJoinException>()
              .having((error) => error.statusCode, 'status', 404)
              .having((error) => error.code, 'code', isNull)
              .having((error) => error.terminal, 'terminal', isTrue)));
    }, () => client);
  });

  test('server error codes cannot echo secrets', () async {
    final client = MockClient((request) async => jsonResponse({
          'code': inviteToken,
        }, 500));
    await http.runWithClient(() async {
      await expectLater(
          join(),
          throwsA(isA<GroupInviteJoinException>()
              .having((error) => error.code, 'code', isNull)));
    }, () => client);
  });

  test('network failure stays retryable without exposing request details',
      () async {
    final client = MockClient((request) async {
      throw http.ClientException('failed with $sessionToken', request.url);
    });
    await http.runWithClient(() async {
      await expectLater(
          join(),
          throwsA(isA<GroupInviteJoinException>()
              .having((error) => error.statusCode, 'status', isNull)
              .having((error) => error.terminal, 'terminal', isFalse)
              .having((error) => error.toString(), 'safe message',
                  'לא ניתן להתחבר לשרת. בדקו את החיבור ונסו שוב')));
    }, () => client);
  });

  testWidgets('timeout after 20 seconds stays retryable', (tester) async {
    final client = MockClient((request) => Completer<http.Response>().future);
    await http.runWithClient(() async {
      Object? failure;
      join().then<void>((_) => fail('Request should not complete'),
          onError: (Object error) => failure = error);
      await tester.pump();
      await tester.pump(const Duration(seconds: 19));
      expect(failure, isNull);
      await tester.pump(const Duration(seconds: 1));
      expect(
          failure,
          isA<GroupInviteJoinException>()
              .having((error) => error.statusCode, 'status', isNull)
              .having((error) => error.terminal, 'terminal', isFalse)
              .having((error) => error.message, 'message',
                  'השרת לא הגיב בזמן. נסו להצטרף שוב'));
    }, () => client);
  });
}
