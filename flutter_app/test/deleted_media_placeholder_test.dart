import 'dart:convert';

import 'package:betshuva/filter_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'own_media_filter_test.dart' as fixtures;

const _messageId = '710c5013-076f-4ef3-adc0-7a6f5621b5d8';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final group in [false, true]) {
    final scope = group ? 'group' : 'private';
    testWidgets(
        '$scope deleted file has a deletion notice without image or restore',
        (tester) async {
      fixtures.size(tester);
      SharedPreferences.setMockInitialValues({
        group ? 'cache_group_msgs_viewer_group' : 'cache_msgs_viewer_friend':
            jsonEncode([
          {
            'id': _messageId,
            'from': 'viewer',
            'isMe': true,
            'isFile': true,
            'fileType': 'image',
            'fileUrl': fixtures.url,
            'fileName': 'previously-available.png',
            'text': '',
            'status': 'sent',
          },
        ]),
      });
      final requests = <http.Request>[];
      await http.runWithClient(() async {
        await tester.pumpWidget(fixtures.chat(group));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('deleted-media-$_messageId')),
            findsOneWidget);
        expect(find.text('הקובץ נמחק'), findsOneWidget);
        expect(find.byType(FilterHiddenImage), findsNothing);
        expect(find.text('להחזיר את התמונה הזו'), findsNothing);
        expect(find.text('התמונה מוסתרת לפי בחירת הסינון שלך'), findsNothing);
        expect(find.text('previously-available.png'), findsNothing);
        expect(
            requests.where((request) =>
                request.url.path.endsWith('.png') ||
                request.url.path.contains('/uploads/')),
            isEmpty);
        expect(
            requests.where((request) =>
                request.url.path.endsWith('/filter-display-events') ||
                request.url.path.endsWith('/filter-visibility')),
            isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
      },
          () => MockClient((request) async {
                requests.add(request);
                if (fixtures.isHistory(request, group)) {
                  return fixtures.json([
                    {
                      'id': _messageId,
                      'sender_id': 'viewer',
                      'sender_name': 'אני',
                      'type': 'image',
                      'file_url': null,
                      'file_name': null,
                      'file_deleted': true,
                      // A deletion must take precedence over old filter metadata too.
                      'filter_hidden': true,
                      'hidden_reason': 'content_filter',
                      'moderation_status': 'approved',
                      'message_status': 'sent',
                      'created_at': '2026-09-17T00:01:00Z',
                    },
                  ]);
                }
                return fixtures.defaultResponse(request);
              }));
    });
  }
}
