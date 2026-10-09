import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:betshuva/incoming_share.dart';
import 'package:betshuva/incoming_share_actions.dart';
import 'package:betshuva/incoming_share_destination.dart';

void main() {
  testWidgets(
      'approved retry payload bypasses link editing and keeps its delivery identity',
      (tester) async {
    var sends = 0;
    var prepares = 0;
    final message = {
      'text': 'כותרת שאושרה https://example.test/item',
      'sourcePath': null
    };
    final key = incomingDeliveryKey(message);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    await processIncomingShare(context,
                        api: '/api',
                        token: 'session',
                        accountId: 'account',
                        canAct: () => true,
                        share: {
                          'text': 'https://example.test/original',
                          'preparedMessages': [message]
                        },
                        prepareMessages: (_) async {
                          prepares++;
                        },
                        deliver: (messages, _) async {
                          sends++;
                          expect(messages.single['text'], message['text']);
                          expect(incomingDeliveryKey(messages.single), key);
                          return const IncomingDeliveryResult({0});
                        },
                        createListing: (_) async => false,
                        openChat: (_) async {},
                        capture: () async => null);
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(sends, 1);
    expect(prepares, 0);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets(
      'captured file uses explicit name and is persisted before any delivery',
      (tester) async {
    var persisted = false;
    IncomingActionResult? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await processIncomingShare(context,
                        api: '/api',
                        token: 'session',
                        accountId: 'account',
                        canAct: () => true,
                        share: {'action': 'capture'},
                        capture: () async => {
                              'path': '/cache/uuid_photo.jpg',
                              'name': 'photo.jpg',
                              'mime': 'image/jpeg'
                            },
                        prepareMessages: (messages) async {
                          persisted = true;
                          expect(messages.single['fileName'], 'photo.jpg');
                        },
                        deliver: (messages, _) async {
                          expect(persisted, isTrue);
                          expect(messages.single['fileName'], 'photo.jpg');
                          return const IncomingDeliveryResult({0});
                        },
                        createListing: (_) async => false,
                        openChat: (_) async {});
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(result?.outcome, 'completed');
  });

  test(
      'calendar and contact are typed imports, never guessed from an ordinary date',
      () {
    expect(incomingShareHasCalendar({'text': 'פגישה מחר בשעה 10'}), isFalse);
    expect(incomingShareHasCalendar({'text': 'BEGIN:VCALENDAR\nVERSION:2.0'}),
        isTrue);
    expect(isSharedCalendarFile({'name': 'meeting.ICS'}), isTrue);
    expect(isSharedContactFile({'mime': 'text/vcard; charset=utf-8'}), isTrue);
    expect(isSharedCalendarFile({'name': 'meeting.pdf'}), isFalse);
  });

  test(
      'a listing accepts only one to eight local images and preserves message order',
      () {
    Map<String, dynamic> image(int i) =>
        {'path': '/cache/$i.png', 'name': '$i.png', 'mime': 'image/png'};
    expect(
        incomingShareCanCreateListing({
          'files': [image(0), image(1)]
        }),
        isTrue);
    expect(incomingShareCanCreateListing({'files': List.generate(9, image)}),
        isFalse);
    expect(
        incomingShareCanCreateListing({
          'files': [
            image(0),
            {'path': '/cache/a.pdf', 'mime': 'application/pdf'}
          ]
        }),
        isFalse);
    expect(
        incomingShareMessages({
          'files': [image(0), image(1)]
        }).map((m) => m['fileName']),
        ['0.png', '1.png']);
  });

  testWidgets(
      'an event-only share offers the Betshuva calendar, not an unsupported upload',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  onPressed: () => chooseIncomingShareDestination(context, {
                    'files': [
                      {
                        'path': '/cache/a.ics',
                        'name': 'a.ics',
                        'mime': 'text/calendar'
                      }
                    ]
                  }),
                  child: const Text('open'),
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
        find.byKey(const ValueKey('incoming-share-calendar')), findsOneWidget);
    expect(find.byKey(const ValueKey('incoming-share-chat')), findsNothing);
    expect(find.byKey(const ValueKey('incoming-share-listing')), findsNothing);
  });

  testWidgets(
      'partially accepted files are acknowledged individually and other files remain for retry',
      (tester) async {
    IncomingActionResult? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await processIncomingShare(context,
                        api: '/api',
                        token: 'session',
                        accountId: 'account',
                        canAct: () => true,
                        share: {
                          'files': [
                            {
                              'path': '/cache/a.pdf',
                              'name': 'a.pdf',
                              'mime': 'application/pdf'
                            },
                            {
                              'path': '/cache/b.mp4',
                              'name': 'b.mp4',
                              'mime': 'video/mp4'
                            }
                          ]
                        },
                        deliver: (messages, recipient) async {
                          expect(messages.length, 2);
                          return const IncomingDeliveryResult({0});
                        },
                        createListing: (_) async =>
                            throw StateError('wrong route'),
                        openChat: (_) async {},
                        capture: () async => null);
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(result?.outcome, 'retry');
    expect(result?.completedPaths, ['/cache/a.pdf']);
    expect(result?.clearText, isFalse);
  });

  testWidgets('a different or disposed account cannot start a share',
      (tester) async {
    var sends = 0;
    IncomingActionResult? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await processIncomingShare(context,
                        api: '/api',
                        token: 'session',
                        accountId: 'account',
                        canAct: () => false,
                        share: {'text': 'hello'},
                        deliver: (_, __) async {
                          sends++;
                          return const IncomingDeliveryResult({0});
                        },
                        createListing: (_) async => false,
                        openChat: (_) async {},
                        capture: () async => null);
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(sends, 0);
    expect(result?.outcome, 'retry');
  });

  testWidgets(
      'a gallery share opens a listing draft without sending to a conversation',
      (tester) async {
    var sends = 0;
    var drafts = 0;
    IncomingActionResult? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    result = await processIncomingShare(context,
                        api: '/api',
                        token: 'session',
                        accountId: 'account',
                        canAct: () => true,
                        share: {
                          'files': [
                            {
                              'path': '/cache/a.png',
                              'name': 'a.png',
                              'mime': 'image/png'
                            },
                            {
                              'path': '/cache/b.png',
                              'name': 'b.png',
                              'mime': 'image/png'
                            }
                          ]
                        },
                        deliver: (_, __) async {
                          sends++;
                          return const IncomingDeliveryResult({0, 1});
                        },
                        createListing: (images) async {
                          drafts++;
                          expect(images.map((XFile f) => f.name),
                              ['a.png', 'b.png']);
                          return true;
                        },
                        openChat: (_) async {},
                        capture: () async => null);
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('incoming-share-listing')));
    await tester.pumpAndSettle();
    expect(drafts, 1);
    expect(sends, 0);
    expect(result?.outcome, 'completed');
  });

  testWidgets(
      'a stale direct share target from another account performs no writes',
      (tester) async {
    Object? error;
    var sends = 0;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                    body: TextButton(
                  child: const Text('open'),
                  onPressed: () async {
                    try {
                      await processIncomingShare(context,
                          api: '/api',
                          token: 'session',
                          accountId: 'account',
                          canAct: () => true,
                          share: {
                            'text': 'hello',
                            'targetShortcutId': 'other:recipient'
                          },
                          deliver: (_, __) async {
                            sends++;
                            return const IncomingDeliveryResult({0});
                          },
                          createListing: (_) async => false,
                          openChat: (_) async {},
                          capture: () async => null);
                    } catch (e) {
                      error = e;
                    }
                  },
                )))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(error, isA<FormatException>());
    expect(sends, 0);
  });
}
