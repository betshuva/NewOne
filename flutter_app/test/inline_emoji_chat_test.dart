import 'dart:convert';
import 'dart:async';

import 'package:betshuva/inline_custom_emoji.dart';
import 'package:betshuva/main.dart';
import 'package:betshuva/location_message_preview.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/foundation.dart' show kIsWeb, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

const _group = {
  'id': 'emoji-test-group',
  'name': 'קבוצת בדיקה',
  'status': 'member',
  'role': 'member',
  'send_permission': 'all',
};
const _uploadedUrl = '/api/uploads/emoji-test-sticker.png';
const _draft = 'טיוטה שנשמרת';
final _keyboardWavBytes = base64Decode(
    'UklGRsAIAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YZwIAAAAACH/hf8//30D9wN0Bzz95wGH+tX8ogE29U33cwEj/dnxI/wCA3rm2QP1ABD0mu5XEZL6DPM/9aAUFAybFI0Regk8Gd0AqAUWDu4D7gpd/nwB/+cV7jnwCemC7yTsMPTRAjv7bP2q+Uf9pBVnDFELMPxmDjf6BgCaEhkFegDiAncGCAOT8PPpJfM38m/xtQkgCWH5qgVb/64QBQQK//v+bQgm/98H5Q/h/xf58g1E/t3wee5q73/99AHs97HugPiUCkL/vAw3C9r1+wnVCZQGtv9OCQz7jgLrAVYN4Qn5+Jn9aPS1Bf4Do/UK/rf9cfMcA/P+7wVjAT32AP/h+JkOuw2gDF0AIvq6CyQMvPdg//70DAM0ArTzz/pQ/Hj23AMh+6/3pf/DBAL7Yf48DeMGDAPOBMT8c/4NABwEGvza+uj2qgAU+DwE2gLL8wP3Xf+E9872bwbGAAUAnQbfB5b9d/ylAogCDgMeB3YF8Anj+Rz+HvwHBBP5m/eW+xX76/jd+FUEV/3dBMwAzfmLCagHOgreCcMIN/7GAin+VgB0+mr+iwYi+wwCsvzf+2UD8wPn/aIARvn9+yEGfQG7ATcFVvzkA/4CsAc3/oUIXfwl/csBFgKv+5L54QJI+nX+tv5V/K7+X/4ABLP7oAKG/Q8A5gPi/1gAkgWJ/c4BqwcaB+v75vzd/MsDpwIyAj/8y/lBAQEAVP/RA8IAc/qqA8T+GwNkBlD+TP49/qwCiv+DAicDd/0xAfr8sv5aAnMB9/kh/dT7efkaAUQAP/0/AgABVwDt/N39ZgWjBVkCvAQwAvj9Wf10/hcDuQHcAdkBxvsG/NT6pAC/ASH+TgDz/LkDngPkBN8DpQT6/ZkDUgDEBHMDigO0Ah7+pQEk/I4BNAFX/LIAJv4z/QUBQf0v/ND9L/9WA1sEyf91AtcAyQSXARkEOf6hA/P9ygLR/Xz8Yv4hAF79Rv/G/ir+pf/v/SEBFP0mAw4BaAK1AlwChACt/hAC2f95/0oCMwFw/jT+iP5S/p39pfxc/mUBIACfAVMA6v6RAOT9sP+kAI4B/gH0ALoAXv99AGwClgEb/mr9Wv/B/yT+ewAoANr/0P3m/U/9pP4EAA0Cnf5qAI0Bmv/tAe4Aqv9cATT+UQEkAfH9Iv/b/SQBI/8Z/QL+rQAo/9AAeAAKAqIAUAI/Aj0BwgHrADQC+wA8AnIBLQAd/9r+KQB4AGL/sP9P/pX9b/6A/tf+1/+S/iD/AgE6AQ//ZQDuAHwAtP9cAOgBoADRACwBqgAw/8n92P4fAG8AygAd/00AzP8nABv/Sf8kAAH/FQA5AWQAo/+BAF7/vQDJ/rr/EQBQ/v//Zf5I/w3+Bf+X/gL/XQBs/6EAAgGL/zb/KP+qAPUBMQD3AD0ByQDuAEwBLf+S/sn+nf7u/5z/uf73/zEAyf7//3kADv/rAGQBbf9R/w8A8wCYATgA4wBM/5oAUwD+/mYAdwDR/7D+lgAkADj/d/9u/9X/mf/PAN0Acv9WAbYAJAHjAEwA2gA+Abv/tQAMANT/ov8iACn/QwA2AMv+XgA3/7r/GgDG/zr/2wCz/9L/7wAdABQBtwDl/1j/6wBM/1AA0P8zAAQA5f+c/yAA+f4+/xkAiv8WAAEAMAAYAK0ADgCsAP3/8P+x/7//j/8fAGEAav9j/7r/CwBjALX/Xf8i/1T/cv90/03/IQDW/+QAWACTAMr/zwBCALwARAAOAPD/hf9G/2UAu/8mAJX/Kv/o/zT/Yv/5/7f/qACh/34AWQCbAO//TAAxACYAmgCzANL/IAAMACMAVABw/2z/7v9f/2v/Wv9T/+L/GgDV/9T/ZABsAC4AcACuAIMATgBLAIYA8P8BAA0ARQAlAFz/cv+X/wwA5v+q/47/KAA4AIEAIAApAMz/xv8lAAcA8P/C/4IAWAAOAFcAVgACAKD/aP8IAMr/9/85AKP/BgAdAAoAwP8BAAUAUQB5AAoAUQD2/3QATgANAO7/yP/A/zkAxP/Y/zQA9//n/9b/tf/g/zYAJwBJAOn/LwB3AB0ASgDd/28AJQDZ/8H//f/0/53/MwAiANP/m/8YAOb/EgD4/9v/QABgAO//JwAQAGcAJABbAFMA8P84APX/PADy/xsAw//C/+z/KgDg/7L/8v/d/wMACgAGAPr/7P85ACkA+v9DANr/NQApADAA7/8NABsAKgDl/6f/4//w/xcAHADq//z/+/8jAAIAJwDt/xcAVQAHAC8AJgA5ADIALADt/9//CQAJABMAsf+2//j/HAApABIA9f/X/xgANwANACsAQwDn/zYA/f8CAOX/CAAFABcA0v/E/xIA9v/Q/xQAyv/t/93/4//Q/yMAMQAgAPL/DwAGABwAHwAIAPT/JgDm//L/9v/c//b/9P8YANv/GAD//+H///8NABcA4f8UAA4AMgAAACsAGgADABcAEQASABAABwARAP3/EAD7/+D/6//4/wYA2f/s/xIA7P/t/w4AMAASAC4AJwD9/yMABwAaABIA8v/f/xYA2/8RAAkAAAASABMACwDy/xEA4v8IAAYAFgAYABMAIgApAPP/+P/p/xoAAwAVAOj/3P8IAAsA5//u/+D/EQDu//z/6f8ZAPL/BgAUABkAJQAHABgA9v8CAO7/AAD5/xMA4P/w//L/DAAHAOH/AQD8/xQA+P/8//X/9P8aAAgAEgARAA8A8v8UAPj/8P8CAOn/BwDr/+r/BwDu/+f/CQDj/wsA7v/w//j/9/8OAPT/9P8WAP7/AQD5//P/DQACAAgA+/8FAPn/6P/3/wkA5v8EAAkA/v/9/xMA8/8EAAMADwAIABcA+P/3/wkA9P/5/wQA///2/wwA+v/3//z/6/8AAAcAAQAHAAcA+P8CAPz/AQAFAAQA+v8EAAoAAAD3/w4A8f8HAO//7v8BAAMA+//9//3/9//y/w==');
final _pngBytes = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aH9sAAAAASUVORK5CYII=');
final _labels = List.generate(150, (index) => 'אימוג׳י לבדיקה ${index + 1}');
const _creamContrastLabels = [
  'שמחה',
  'צחוק',
  'חיוך',
  'קריצה',
  'נשיקה',
  'שלווה',
  'אהבה',
  'התרגשות',
  'עיניים נוצצות',
  'הפתעה',
  'ספק',
  'מחשבה',
  'רוגע',
  'דאגה',
  'בכי',
  'תסכול',
];
const _newLibraryEmojiVariants = ['קרם', 'ירוק בהיר', 'ירוק חזק'];
final _newLibraryEmojiItems = List.generate(
    48,
    (index) => {
          'id': 'user-emojis-${167 + index}',
          'emojiId': 167 + index,
          'label': '${_creamContrastLabels[index % 16]} — '
              '${_newLibraryEmojiVariants[index ~/ 16]}',
          'url': '/betshuva-app/api/expressions/emoji/${167 + index}',
          'animated': false,
        });
var _bundledCatalogReads = 0;
var _keyboardSoundAssetReads = 0;
final _keyboardAudioCalls = <MethodCall>[];
final _keyboardAudioChannels = <String>{};
var _bundledColoredArtwork = false;
var _bundledRemovedArtwork = false;
const _standardCatalog = [
  {
    'emoji': '😀',
    'category': 'פנים ורגשות',
    'label_he': 'חיוך',
    'twemoji_code': '1f600',
  },
  {
    'emoji': '👍',
    'category': 'מחוות',
    'label_he': 'אגודל למעלה',
    'twemoji_code': '1f44d',
  },
  {
    'emoji': '❤️',
    'category': 'לבבות',
    'label_he': 'לב אדום',
    'twemoji_code': '2764',
  },
];
const _svgFixture =
    '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" '
    'viewBox="0 0 36 36"><circle cx="18" cy="18" r="16" fill="#ffcc4d"/></svg>';

// Production's catalog is immutable per bundle. Each harness gets its own
// immutable fixture so cached futures cannot outlive an earlier test's mock.
class _MessageEmojiBundle extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async {
    if (key == 'assets/twemoji/emoji_allowlist.json') {
      return ByteData.sublistView(
          Uint8List.fromList(utf8.encode(jsonEncode(_standardCatalog))));
    }
    if (key.startsWith('assets/twemoji/svg/')) {
      return ByteData.sublistView(Uint8List.fromList(utf8.encode(_svgFixture)));
    }
    return rootBundle.load(key);
  }
}

Map<String, dynamic> get _bundledCatalog => {
      'version': 3,
      'categories': [
        {
          'id': 'user-stickers',
          'title': 'מדבקות בתשובה',
          'path': 'user-20260907',
          if (_bundledColoredArtwork) 'coloredPath': 'user-20261008-color',
          'prefix': 'sticker',
          'extension': 'png',
          'labels': _labels,
          if (_bundledRemovedArtwork)
            'removedIds': List.generate(102, (index) => index + 49),
        },
      ],
    };

Map<String, dynamic> get _catalog => {
      'version': 3,
      'categories': [
        {
          'id': 'user-stickers',
          'title': 'מדבקות בתשובה',
          'items': List.generate(
              _labels.length,
              (index) => {
                    'label': _labels[index],
                    'url':
                        '/betshuva-app/expression-library/user-20260907/sticker-${(index + 1).toString().padLeft(2, '0')}.png',
                  }),
        },
      ],
    };

class _ChatHarness {
  final bool isGroup;
  final int catalogStatus;
  final bool allowText;
  final bool allowImages;
  final bool withHistory;
  final int uploadStatus;
  final bool coloredArtwork;
  final bool removedArtwork;
  final bool splitCatalog;
  final List<Map<String, dynamic>> extraEmojiItems;
  final List<Map<String, dynamic>> extraStickerItems;
  final bool adminInvites;
  final bool isGuide;
  final Future<http.Response> Function()? sendResponse;
  final pendingInviteIds = <String>{'invited-user'};
  int liveEmojiCount = 49;
  int liveStickerCount = 150;
  final List<Map<String, dynamic>>? history;
  final requests = <http.Request>[];
  final messageEmojiBundle = _MessageEmojiBundle();
  final socket = io.io(
    'http://localhost:1',
    io.OptionBuilder().disableAutoConnect().enableForceNew().build(),
  );

  _ChatHarness(
      {required this.isGroup,
      this.catalogStatus = 200,
      this.allowText = true,
      this.allowImages = true,
      this.withHistory = false,
      this.uploadStatus = 200,
      this.coloredArtwork = false,
      this.removedArtwork = false,
      this.splitCatalog = false,
      this.extraEmojiItems = const [],
      this.extraStickerItems = const [],
      this.adminInvites = false,
      this.isGuide = false,
      this.sendResponse,
      this.history});

  late final client = MockClient((request) async {
    requests.add(request);
    dynamic body = <String, dynamic>{};
    final path = request.url.path;
    if (request.method == 'GET' && path.endsWith('.png')) {
      return http.Response.bytes(_pngBytes, 200,
          headers: {'content-type': 'image/png'});
    } else if (request.method == 'POST' && path.endsWith('/upload')) {
      return http.Response(
          jsonEncode(uploadStatus == 200
              ? {'url': _uploadedUrl, 'status': 'approved'}
              : {'error': 'העלאת המדבקה נכשלה'}),
          uploadStatus,
          headers: {'content-type': 'application/json; charset=utf-8'});
    } else if (request.method == 'POST' && path.endsWith('/messages')) {
      if (sendResponse != null) return sendResponse!();
      body = {'id': 'emoji-sent-message', 'status': 'sent'};
    } else if (path.endsWith('/expressions/catalog')) {
      final catalog = _catalog;
      if (splitCatalog) {
        catalog['version'] = 4;
        catalog['categories'] = [
          {
            'id': 'user-emojis',
            'items': List.generate(
                liveEmojiCount,
                (index) => {
                      'label': 'אימוג׳י שרת ${index + 1}',
                      'url':
                          '/betshuva-app/api/expressions/emoji/${index < 49 ? index + 1 : index + 102}',
                    })
          },
          {
            'id': 'user-stickers',
            'items': List.generate(
                liveStickerCount,
                (index) => {
                      'label': 'מדבקה שרת ${index + 1}',
                      'url':
                          '/betshuva-app/expression-library/user-20260907/sticker-01.png',
                      'libraryUrl':
                          '/betshuva-app/expression-library/stickers/new-${index + 1}.png',
                    })
          },
        ];
      }
      if (removedArtwork) {
        for (final category in catalog['categories'] as List) {
          (category['items'] as List).removeWhere((item) {
            final id = inlineEmojiIdFromUrl(item['url'] as String)!;
            return id >= 49 && id <= 150;
          });
        }
      }
      if (coloredArtwork) {
        for (final category in catalog['categories'] as List) {
          for (final item in category['items'] as List) {
            item['coloredUrl'] = (item['url'] as String)
                .replaceFirst('user-20260907', 'user-20261008-color');
          }
        }
      }
      if (extraStickerItems.isNotEmpty) {
        final category = (catalog['categories'] as List).firstWhere((c) => c['id'] == 'user-stickers') as Map;
        category['items'] = [...(category['items'] as List), ...extraStickerItems];
      }
      if (extraEmojiItems.isNotEmpty) {
        final emojiCategory = (catalog['categories'] as List)
            .firstWhere((category) => category['id'] == 'user-emojis') as Map;
        emojiCategory['items'] = <Map<String, dynamic>>[
          ...(emojiCategory['items'] as List)
              .map((item) => Map<String, dynamic>.from(item as Map)),
          ...extraEmojiItems.map((item) => Map<String, dynamic>.from(item)),
        ];
      }
      return http.Response(jsonEncode(catalog), catalogStatus,
          headers: {'content-type': 'application/json; charset=utf-8'});
    } else if (adminInvites && path.endsWith('/users/directory')) {
      body = [
        {'id': 'existing-member', 'name': 'חבר קיים'},
        {'id': 'invited-user', 'name': 'מוזמן קודם'},
        {'id': 'new-invite-user', 'name': 'משתמש חדש'},
      ];
    } else if (adminInvites &&
        request.method == 'POST' &&
        path.endsWith('/members')) {
      pendingInviteIds.add(jsonDecode(request.body)['userId'] as String);
      body = {'ok': true};
    } else if (path.endsWith('/groups')) {
      body = [
        {..._group, if (adminInvites) 'role': 'admin'}
      ];
    } else if (path.endsWith('/groups/emoji-test-group')) {
      body = <String, dynamic>{
        'members': [
          {
            'id': 'emoji-test-user',
            'name': 'משתמש לבדיקה',
            'role': adminInvites ? 'admin' : 'member'
          },
          if (adminInvites)
            {'id': 'existing-member', 'name': 'חבר קיים', 'role': 'member'},
        ],
      };
      if (adminInvites) body['pending_invite_ids'] = pendingInviteIds.toList();
    } else if (path.contains('/messages/') || path.endsWith('/messages')) {
      body = history ??
          (withHistory
              ? [
                  {
                    'id': 'existing-emoji-message',
                    'sender_id': 'emoji-test-recipient',
                    'body': 'הודעה קיימת',
                    'created_at': '2026-09-17T00:00:00Z'
                  }
                ]
              : []);
    } else if (path.endsWith('/filter-settings')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': allowImages},
        'personalFilter': {'text': allowText, 'nonHumanImages': allowImages},
        'requiresChoice': false,
      };
    } else if (path.endsWith('/receiving-filter')) {
      body = {
        'filter': {'text': allowText, 'nonHumanImages': allowImages},
      };
    }
    return http.Response(jsonEncode(body), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  });

  Finder get composer => find.byWidgetPredicate((widget) =>
      widget is TextField &&
      widget.decoration?.hintText ==
          (isGroup
              ? 'הודעה לקבוצה...'
              : allowText
                  ? 'כתוב הודעה...'
                  : 'הנמען אינו מקבל תוכן טקסטואלי'));

  TextEditingController controller(WidgetTester tester) =>
      tester.widget<TextField>(composer).controller!;

  List<http.Request> get sentHttpMessages => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/messages'))
      .toList();

  List<http.Request> get uploads => requests
      .where((request) =>
          request.method == 'POST' && request.url.path.endsWith('/upload'))
      .toList();

  List<Map<String, dynamic>> get sentSocketMessages => socket.sendBuffer
      .whereType<Map>()
      .map((packet) => packet['data'])
      .whereType<List>()
      .where((data) =>
          data.isNotEmpty &&
          const ['chat:message', 'group:message'].contains(data.first))
      .map((data) => Map<String, dynamic>.from(data[1] as Map))
      .toList();

  void expectNothingSent() {
    expect(sentHttpMessages, isEmpty);
    expect(sentSocketMessages, isEmpty);
    expect(uploads, isEmpty);
  }

  void expectOneTextMessage(String wireText) {
    expect(uploads, isEmpty);
    late Map<String, dynamic> message;
    if (isGroup) {
      expect(sentSocketMessages, hasLength(1));
      expect(sentHttpMessages, isEmpty);
      message = sentSocketMessages.single;
      expect(message['groupId'], _group['id']);
    } else {
      expect(sentHttpMessages, hasLength(1));
      expect(sentSocketMessages, isEmpty);
      final request = sentHttpMessages.single;
      expect(request.url.path, endsWith('/messages'));
      message = jsonDecode(request.body) as Map<String, dynamic>;
      expect(message['toUserId'],
          isGuide ? kSystemGuideId : 'emoji-test-recipient');
    }
    expect(message['text'], wireText);
    expect(message['fileType'], isNull);
    expect(message['fileUrl'], isNull);
    expect(message['fileName'], isNull);
    expect(message['stickerId'], isNull);
  }

  void expectOneSticker() {
    expect(uploads, hasLength(1));
    final upload = uploads.single;
    final multipart = latin1.decode(upload.bodyBytes);
    expect(multipart, contains('name="builtinExpression"\r\n\r\ntrue'));
    expect(multipart, isNot(contains('name="scanReport"')));
    expect(multipart, contains('name="clientUploadId"'));
    expect(multipart, contains('name="${isGroup ? 'groupId' : 'toUserId'}"'));
    expect(sentHttpMessages, hasLength(1));
    expect(sentSocketMessages, isEmpty);
    final request = sentHttpMessages.single;
    expect(
        request.url.path,
        isGroup
            ? endsWith('/groups/emoji-test-group/messages')
            : endsWith('/messages'));
    final message = jsonDecode(request.body) as Map<String, dynamic>;
    expect(message['fileType'], 'image');
    expect(message['fileUrl'], _uploadedUrl);
    expect(message['fileName'], isNotEmpty);
    expect(message['text'], isNull);
    expect(message['stickerId'], isNull);
    if (!isGroup) expect(message['toUserId'], 'emoji-test-recipient');
  }

  Future<void> mount(WidgetTester tester) async {
    _bundledColoredArtwork = coloredArtwork;
    _bundledRemovedArtwork = removedArtwork;
    addTearDown(() {
      socket.dispose();
      client.close();
    });
    await tester.pumpWidget(MaterialApp(
      home: DefaultAssetBundle(
        bundle: messageEmojiBundle,
        child: Directionality(
          textDirection: TextDirection.rtl,
          child: isGroup
              ? GroupChatScreen(
                  token: 'emoji-test-token',
                  me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                  group: Map<String, dynamic>.from(
                      {..._group, if (adminInvites) 'role': 'admin'}),
                  socket: socket,
                  embedded: true,
                )
              : ChatScreen(
                  token: 'emoji-test-token',
                  me: const {'id': 'emoji-test-user', 'name': 'משתמש לבדיקה'},
                  recipient: {
                    'id': isGuide ? kSystemGuideId : 'emoji-test-recipient',
                    'name': 'חבר לבדיקה',
                  },
                  socket: socket,
                  embedded: true,
                ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(composer, findsOneWidget);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  }
}

Finder get _picker => find.byType(BottomSheet);
Finder get _grid =>
    find.descendant(of: _picker, matching: find.byType(SliverGrid));
Finder get _search =>
    find.descendant(of: _picker, matching: find.byType(TextField));
Finder get _done => find.byKey(const ValueKey('expression-done'));
Future<void> _ensureDoneVisible(WidgetTester tester) async {
  await tester.ensureVisible(_done);
  await tester.pump();
}

Future<void> _enterSearch(WidgetTester tester, String query) async {
  await tester.pumpAndSettle();
  if (_search.evaluate().isEmpty) {
    await tester
        .ensureVisible(find.byKey(const ValueKey('expression-search-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('expression-search-toggle')));
    await tester.pumpAndSettle();
  }
  await tester.enterText(_search, query);
}

bool _pickerShowsStickers(WidgetTester tester) =>
    tester
        .widget<Image>(
          find.descendant(of: _grid, matching: find.byType(Image)).first,
        )
        .width ==
    null;

Finder get _stickerShortcut =>
    find.byKey(const ValueKey('chat-stickers-shortcut'));
Finder get _inlineEmojiShortcut =>
    find.byKey(const ValueKey('chat-inline-emoji-shortcut'));

void _expectFlatImages(WidgetTester tester,
    {int count = 150, bool stickers = false}) {
  expect(find.descendant(of: _picker, matching: find.byType(TabBar)),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.byType(ChoiceChip)),
      findsNothing);
  expect(
      find.descendant(of: _picker, matching: find.byType(Text)), findsNothing);
  expect(
      find.descendant(
          of: _picker, matching: find.text(stickers ? 'אימוג׳י' : 'מדבקות')),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.text('של בתשובה')),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.text('רגילים')),
      findsNothing);
  expect(find.descendant(of: _picker, matching: find.text('מדבקות בתשובה')),
      findsNothing);
  expect(find.byKey(const ValueKey('inline-emoji-1f600')), findsNothing);
  expect(_grid, findsOneWidget);
  expect(tester.widget<SliverGrid>(_grid).delegate.estimatedChildCount, count);
  final layout = tester.widget<SliverGrid>(_grid).gridDelegate
      as SliverGridDelegateWithFixedCrossAxisCount;
  expect(layout.crossAxisCount, greaterThanOrEqualTo(1));
  expect(layout.mainAxisExtent,
      inExclusiveRange(0, (stickers ? 80 : (kIsWeb ? 36 : 44)) + 1));
}

Future<void> _openPicker(WidgetTester tester,
    {bool stickers = false,
    bool defaultStickers = true,
    int count = 150}) async {
  await _openShortcut(tester, stickers: stickers, count: count);
}

Future<void> _openShortcut(WidgetTester tester,
    {required bool stickers, int count = 150}) async {
  final composer = find.byType(TextField).first;
  final controller = tester.widget<TextField>(composer).controller!;
  final original = controller.value;
  await tester.showKeyboard(composer);
  controller.value = original;
  await tester.pump();
  await tester.tap(stickers ? _stickerShortcut : _inlineEmojiShortcut);
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
  for (var attempt = 0; _grid.evaluate().isEmpty && attempt < 8; attempt++) {
    await tester.drag(
        find.descendant(of: _picker, matching: find.byType(CustomScrollView)),
        const Offset(0, -60));
    await tester.pumpAndSettle();
  }
  _expectFlatImages(tester, stickers: stickers, count: count);
}

void _expectComposerShortcuts(WidgetTester tester, {bool hasText = true}) {
  expect(_stickerShortcut, findsOneWidget);
  expect(_inlineEmojiShortcut, findsOneWidget);
  final stickerButton = tester.widget<IconButton>(_stickerShortcut);
  final emojiButton = tester.widget<IconButton>(_inlineEmojiShortcut);
  expect(stickerButton.tooltip, 'מדבקות');
  expect(emojiButton.tooltip, 'אימוג׳י');
  expect((stickerButton.icon as Icon).icon, Icons.sticky_note_2_outlined);
  expect((emojiButton.icon as Icon).icon, Icons.emoji_emotions_outlined);

  final input = find.byType(TextField).first;
  final attachment = find.byIcon(Icons.attach_file);
  final send = find.byIcon(hasText ? Icons.send : Icons.mic);
  expect(find.byIcon(hasText ? Icons.mic : Icons.send), findsNothing);
  expect(
      tester.getCenter(attachment).dx, greaterThan(tester.getCenter(input).dx));
  expect(tester.getCenter(send).dx, lessThan(tester.getCenter(input).dx));
  for (final shortcut in [_stickerShortcut, _inlineEmojiShortcut]) {
    expect(tester.getRect(shortcut).top,
        greaterThanOrEqualTo(tester.getRect(input).bottom));
  }
}

void _expectComposerKeyboard(WidgetTester tester, _ChatHarness app,
    {required bool visible}) {
  expect(tester.widget<TextField>(app.composer).focusNode!.hasFocus, visible);
  if (!kIsWeb) expect(tester.testTextInput.isVisible, visible);
}

Future<void> _focusComposer(WidgetTester tester, _ChatHarness app) async {
  await tester.showKeyboard(app.composer);
  await tester.pump();
  _expectComposerKeyboard(tester, app, visible: true);
}

Finder _imageTile(int id, {bool colored = false}) => find.byKey(ValueKey(
    'expression-image-https://betshuva.com/betshuva-app/expression-library/${colored ? 'user-20261008-color' : 'user-20260907'}/sticker-${id.toString().padLeft(2, '0')}.png'));

Future<void> _selectEmoji(WidgetTester tester, int id,
    {bool colored = false}) async {
  final sendsSticker = _pickerShowsStickers(tester);
  await tester.ensureVisible(_imageTile(id, colored: colored));
  await tester.pumpAndSettle();
  await tester.tap(_imageTile(id, colored: colored));
  if (sendsSticker) {
    // Standalone media exercises real browser FileReader/IndexedDB events and
    // image decoding, which cannot complete on Flutter's synthetic test clock.
    // Pump each stage while yielding to that I/O, rather than waiting for a
    // photo placeholder animation to stop before the decoding event arrives.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
    }
  } else {
    await tester.pumpAndSettle();
  }
  if (sendsSticker) {
    expect(_picker, findsNothing);
    final fields = find.byType(TextField);
    if (fields.evaluate().isNotEmpty) {
      expect(
          tester.widget<TextField>(fields.last).focusNode?.hasFocus, isFalse);
    }
    return;
  }
  expect(_picker, findsOneWidget);
  if (find.byType(SnackBar).evaluate().isNotEmpty) {
    final close =
        find.descendant(of: _picker, matching: find.byIcon(Icons.close));
    final scrollable =
        find.descendant(of: _picker, matching: find.byType(Scrollable)).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(close);
  } else {
    await _ensureDoneVisible(tester);
    await tester.tap(_done);
  }
  await tester.pumpAndSettle();
  expect(_picker, findsNothing);
}

Future<void> _openInlineTab(WidgetTester tester, {int count = 150}) async {
  if (_pickerShowsStickers(tester)) {
    await _ensureDoneVisible(tester);
    await tester.tap(_done);
    await tester.pumpAndSettle();
    await _openShortcut(tester, stickers: false, count: count);
  }
  _expectFlatImages(tester, count: count);
}

void _expectSmallEmoji(WidgetTester tester, Finder scope, int id) {
  final image = find.descendant(
    of: scope,
    matching: find.byKey(ValueKey('inline-custom-emoji-$id')),
  );
  expect(image, findsOneWidget);
  final size = tester.getSize(image);
  expect(size.width, inInclusiveRange(21.78, 29.15));
  expect(size.height, inInclusiveRange(21.78, 29.15));
}

TextSelection _logicalSelection(TextEditingController controller) {
  int offset(int index) => index < 0
      ? index
      : inlineEmojiPlainText(controller.text.substring(0, index)).length;
  return TextSelection(
      baseOffset: offset(controller.selection.baseOffset),
      extentOffset: offset(controller.selection.extentOffset));
}

void main() {
  for (final isGroup in [false, true]) {
    testWidgets('image menu saves a shared sticker with rights without sending it ($isGroup)', (tester) async {
      final app = _ChatHarness(isGroup: isGroup, history: [{
        'id': 'shared-source-photo', 'sender_id': 'emoji-test-recipient',
        'recipient_id': 'emoji-test-user', 'sender_name': 'חבר',
        'file_url': '/uploads/shared-source.png', 'file_name': 'source.png',
        'file_type': 'image', 'message_status': 'sent',
        'created_at': '2026-10-14T12:00:00Z',
      }]);
      await http.runWithClient(() async {
        await app.mount(tester);
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        await tester.tap(find.byTooltip('אפשרויות הודעה').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('שמור כמדבקה משותפת'));
        await tester.pumpAndSettle();
        final title = find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == 'שם המדבקה');
        await tester.enterText(title, 'שלום לכולם');
        final save = find.widgetWithText(ElevatedButton, 'שמור מדבקה');
        expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
        await tester.tap(save);
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        expect(app.uploads, hasLength(1));
        final body = latin1.decode(app.uploads.single.bodyBytes);
        expect(body, contains('name="sharedSticker"'));
        expect(body, contains('name="rightsConfirmed"'));
        expect(app.sentHttpMessages, isEmpty);
        expect(app.sentSocketMessages, isEmpty);
        expect(find.text('המדבקה נשמרה בספרייה המשותפת'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  for (final isGroup in [false, true]) {
    testWidgets('shared user sticker sends from the library without uploading ($isGroup)', (tester) async {
      final app = _ChatHarness(isGroup: isGroup, splitCatalog: true, extraStickerItems: [
        {'id': 'shared-sticker-one', 'label': 'מדבקה משותפת', 'url': '/uploads/shared-sticker.png',
          'sharedSticker': {'id': 'shared-one', 'title': 'מדבקה משותפת',
            'preview_url': '/uploads/shared-sticker.png', 'file_name': 'betshuva-shared-sticker-one.png'}}
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester, stickers: true, count: 151);
        await _enterSearch(tester, 'מדבקה משותפת');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('expression-image-https://betshuva.com/uploads/shared-sticker.png')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        expect(app.requests.where((r) => r.url.path.endsWith('/upload')), isEmpty);
        final sent = app.requests.where((r) => r.method == 'POST' && r.url.path.endsWith('/messages')).single;
        expect(jsonDecode(sent.body)['fileName'], 'betshuva-shared-sticker-one.png');
        expect(jsonDecode(sent.body)['fileType'], 'image');
        expect(app.requests.any((r) => r.url.path.endsWith('/gifs/shared-one/use')), isTrue);
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!kIsWeb) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events'
      ]) {
        messenger.setMockMethodCallHandler(
            MethodChannel(channel), (_) async => null);
      }
      // Initialize the plugin outside the per-widget fake clock so later tests
      // do not await a completed future owned by an earlier clock.
      await AudioPlayer.global.ensureInitialized();
    }
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _keyboardAudioCalls.clear();
    _keyboardSoundAssetReads = 0;
    if (!kIsWeb) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [
        'xyz.luan/audioplayers.global',
        'xyz.luan/audioplayers.global/events'
      ]) {
        messenger.setMockMethodCallHandler(
            MethodChannel(channel), (_) async => null);
      }
      messenger.setMockMethodCallHandler(
          const MethodChannel('xyz.luan/audioplayers'), (call) async {
        _keyboardAudioCalls.add(call);
        final playerId = (call.arguments as Map)['playerId'] as String;
        final channel = 'xyz.luan/audioplayers/events/$playerId';
        if (call.method == 'create') {
          _keyboardAudioChannels.add(channel);
          messenger.setMockMethodCallHandler(
              MethodChannel(channel), (_) async => null);
        }
        final event = switch (call.method) {
          'setSourceBytes' => {'event': 'audio.onPrepared', 'value': true},
          'seek' => {'event': 'audio.onSeekComplete'},
          _ => null,
        };
        if (event != null) {
          messenger.handlePlatformMessage(channel,
              const StandardMethodCodec().encodeSuccessEnvelope(event), (_) {});
        }
        if (call.method == 'resume') {
          Timer(const Duration(milliseconds: 25), () {
            messenger.handlePlatformMessage(
                channel,
                const StandardMethodCodec()
                    .encodeSuccessEnvelope({'event': 'audio.onComplete'}),
                (_) {});
          });
        }
        return call.method == 'getCurrentPosition' ? 0 : null;
      });
    }
    _bundledCatalogReads = 0;
    _bundledColoredArtwork = false;
    rootBundle.evict('assets/stickers/user-catalog.json');
    rootBundle.evict('assets/twemoji/emoji_allowlist.json');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The Chrome test host does not serve project assets. Exercise the real
    // fallback parser with a bundled-catalog fixture, independent of that host.
    messenger.setMockMessageHandler('flutter/assets', (message) {
      final key = const StringCodec().decodeMessage(message);
      if (key == 'assets/sounds/keyboard-click.wav') {
        _keyboardSoundAssetReads++;
        return Future.value(ByteData.sublistView(_keyboardWavBytes));
      }
      if (key == 'assets/stickers/user-catalog.json') {
        _bundledCatalogReads++;
        return Future.value(ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(_bundledCatalog)))));
      }
      if (key == 'assets/twemoji/emoji_allowlist.json') {
        return Future.value(ByteData.sublistView(
            Uint8List.fromList(utf8.encode(jsonEncode(_standardCatalog)))));
      }
      if (key?.startsWith('assets/twemoji/svg/') ?? false) {
        return Future.value(
            ByteData.sublistView(Uint8List.fromList(utf8.encode(_svgFixture))));
      }
      return messenger.delegate.send('flutter/assets', message) ??
          Future.value(null);
    });
  });
  tearDown(() {
    if (!kIsWeb) {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in _keyboardAudioChannels) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), null);
      }
      _keyboardAudioChannels.clear();
    }
    rootBundle.evict('assets/stickers/user-catalog.json');
    rootBundle.evict('assets/twemoji/emoji_allowlist.json');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', null);
  });

  for (final isGuide in [false, true]) {
    final kind = isGuide ? 'IsraelChat' : 'private';
    for (final status in [200, 400, 422, 503]) {
      testWidgets(
        '$kind send button closes the keyboard before deferred HTTP $status',
        (tester) async {
          final response = Completer<http.Response>();
          final started = Completer<void>();
          final app = _ChatHarness(
            isGroup: false,
            isGuide: isGuide,
            sendResponse: () {
              started.complete();
              return response.future;
            },
          );
          await http.runWithClient(() async {
            await app.mount(tester);
            await tester.enterText(app.composer, 'הודעה לבדיקה');
            await _focusComposer(tester, app);
            await tester.tap(
              find.byKey(const ValueKey('chat-composer-action')),
            );
            await tester.pump();
            _expectComposerKeyboard(tester, app, visible: false);
            for (var i = 0; !started.isCompleted && i < 20; i++) {
              await tester.pump(const Duration(milliseconds: 20));
            }
            expect(started.isCompleted, isTrue);
            expect(response.isCompleted, isFalse);
            response.complete(
              http.Response(
                jsonEncode(
                  status == 200
                      ? {'id': 'accepted-text', 'status': 'sent'}
                      : {
                          'error': 'השליחה לא אושרה',
                          if (status == 422) 'code': 'CHAT_CONTENT_BLOCKED',
                        },
                ),
                status,
                headers: {'content-type': 'application/json; charset=utf-8'},
              ),
            );
            await tester.pumpAndSettle();
            _expectComposerKeyboard(tester, app, visible: false);
            await tester.pump(const Duration(seconds: 6));
            await app.dispose(tester);
            if (status == 422) await tester.pump(const Duration(minutes: 2));
          }, () => app.client);
        },
      );
    }

    testWidgets(
      '$kind send button keeps a new draft focused after deferred HTTP',
      (tester) async {
        final response = Completer<http.Response>();
        final started = Completer<void>();
        final app = _ChatHarness(
          isGroup: false,
          isGuide: isGuide,
          sendResponse: () {
            started.complete();
            return response.future;
          },
        );
        await http.runWithClient(() async {
          await app.mount(tester);
          await tester.enterText(app.composer, 'ראשונה');
          await _focusComposer(tester, app);
          await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
          await tester.pump();
          _expectComposerKeyboard(tester, app, visible: false);
          for (var i = 0; !started.isCompleted && i < 20; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(started.isCompleted, isTrue);
          await tester.enterText(app.composer, 'טיוטה חדשה');
          response.complete(
            http.Response(jsonEncode({'id': 'accepted-text'}), 200),
          );
          await tester.pumpAndSettle();
          expect(app.controller(tester).text, 'טיוטה חדשה');
          _expectComposerKeyboard(tester, app, visible: true);
          await app.dispose(tester);
        }, () => app.client);
      },
    );
  }

  testWidgets(
    'group send button closes the keyboard without a socket acknowledgement',
    (tester) async {
      final app = _ChatHarness(isGroup: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'הודעה בקבוצה');
        await _focusComposer(tester, app);
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pump();
        _expectComposerKeyboard(tester, app, visible: false);
        await tester.pumpAndSettle();
        app.expectOneTextMessage('הודעה בקבוצה');
        _expectComposerKeyboard(tester, app, visible: false);
        await app.dispose(tester);
      }, () => app.client);
    },
  );

  for (final isGroup in [false, true]) {
    for (final stickers in [false, true]) {
      testWidgets(
        '${isGroup ? 'group' : 'private'} opens ${stickers ? 'stickers' : 'emoji'} before focusing an empty draft',
        (tester) async {
          final app = _ChatHarness(isGroup: isGroup);
          await http.runWithClient(() async {
            await app.mount(tester);
            _expectComposerKeyboard(tester, app, visible: false);
            final shortcut = stickers ? _stickerShortcut : _inlineEmojiShortcut;
            expect(shortcut, findsOneWidget);
            await tester.tap(shortcut);
            await tester.pumpAndSettle();
            expect(_picker, findsOneWidget);
            expect(_pickerShowsStickers(tester), stickers);
            expect(app.controller(tester).text, isEmpty);
            app.expectNothingSent();
            await app.dispose(tester);
          }, () => app.client);
        },
      );
    }
    testWidgets(
      '${isGroup ? 'group' : 'private'} compact composer retains multiline input',
      (tester) async {
        final app = _ChatHarness(isGroup: isGroup);
        await http.runWithClient(() async {
          await app.mount(tester);
          final field = tester.widget<TextField>(app.composer);
          expect(field.minLines, 1);
          expect(field.maxLines, 4);
          expect(field.textInputAction, TextInputAction.newline);
          final emptyHeight = tester.getSize(app.composer).height;
          expect(emptyHeight, lessThanOrEqualTo(42));
          await tester.enterText(
            app.composer,
            'שורה ראשונה\nשורה שנייה\nשורה שלישית',
          );
          await tester.pump();
          expect(tester.getSize(app.composer).height, greaterThan(emptyHeight));
          expect(app.controller(tester).text, contains('\nשורה שנייה\n'));
          await app.dispose(tester);
        }, () => app.client);
      },
    );
  }

  testWidgets('web expression picker fills the composer width without labels',
      (tester) async {
    final app = _ChatHarness(isGroup: false);
    await http.runWithClient(() async {
      await app.mount(tester);
      await _openPicker(tester, stickers: true);
      final panel = find.byKey(const ValueKey('expression-picker-panel'));
      expect(tester.getSize(panel).width, 800);
      expect(tester.getSize(panel).height, lessThanOrEqualTo(254));
      final preview = find.descendant(
        of: _imageTile(1),
        matching: find.byType(Image),
      );
      expect(tester.getSize(preview).width, lessThanOrEqualTo(75));
      expect(tester.getSize(preview).height, lessThanOrEqualTo(75));
      await _openInlineTab(tester);
      expect(tester.getSize(panel).width, 800);
      expect(tester.getSize(panel).height, lessThanOrEqualTo(122));
      expect(_search, findsNothing);
      final grid = tester.widget<SliverGrid>(_grid).gridDelegate
          as SliverGridDelegateWithFixedCrossAxisCount;
      expect(grid.crossAxisCount, greaterThan(5));
      expect(find.descendant(of: _picker, matching: find.byType(Text)),
          findsNothing);
      app.expectNothingSent();
      await app.dispose(tester);
    }, () => app.client);
  }, skip: !kIsWeb);

  for (final isGroup in [false, true]) {
    final chatKind = isGroup ? 'group' : 'private';

    for (final state in ['incoming', 'read', 'failed']) {
      testWidgets(
          '$chatKind sender header contains time and status once ($state)',
          (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final isMe = state != 'incoming';
        final app = _ChatHarness(isGroup: isGroup, history: [
          {
            'id': 'compact-header-message',
            'sender_id': isMe ? 'emoji-test-user' : 'emoji-test-recipient',
            'sender_name': 'שם משתמש ארוך מאוד לבדיקת מסך צר',
            'type': 'text',
            'body': 'הודעה קומפקטית',
            'created_at': '2026-09-17T14:09:00Z',
            'message_status': state,
            'is_edited': isMe,
          },
        ]);
        await http.runWithClient(() async {
          await app.mount(tester);
          final header = find.byWidgetPredicate((widget) =>
              widget.key is ValueKey &&
              (widget.key! as ValueKey)
                  .value
                  .toString()
                  .startsWith('message-sender-'));
          expect(header, findsOneWidget);
          final time = find.descendant(
              of: header,
              matching: find.byWidgetPredicate((widget) =>
                  widget is Text &&
                  RegExp(r'^\d{2}:\d{2}$').hasMatch(widget.data ?? '')));
          expect(time, findsOneWidget);
          expect(find.text(tester.widget<Text>(time).data!), findsOneWidget);
          final headerRect = tester.getRect(header);
          expect(headerRect.height, lessThanOrEqualTo(30));
          expect(tester.getRect(time).bottom,
              lessThanOrEqualTo(headerRect.bottom));
          expect(tester.getRect(time).bottom,
              lessThan(tester.getRect(find.text('הודעה קומפקטית')).top));
          expect(find.descendant(of: header, matching: find.text('נערך')),
              isMe ? findsOneWidget : findsNothing);
          expect(
              find.descendant(
                  of: header,
                  matching: find.byIcon(state == 'failed'
                      ? (isGroup ? Icons.error_outline : Icons.done)
                      : Icons.done_all)),
              isMe ? findsOneWidget : findsNothing);
          expect(tester.takeException(), isNull);
          await app.dispose(tester);
        }, () => app.client);
      });
    }

    if (isGroup) {
      testWidgets(
          'group marks prior invitations and refreshes after inviting a new user',
          (tester) async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        const contactsChannel =
            MethodChannel('github.com/QuisApp/flutter_contacts');
        messenger.setMockMethodCallHandler(contactsChannel, (_) async => false);
        addTearDown(
            () => messenger.setMockMethodCallHandler(contactsChannel, null));
        final app = _ChatHarness(isGroup: true, adminInvites: true);
        await http.runWithClient(() async {
          await app.mount(tester);
          final menu = tester.widget<PopupMenuButton<String>>(
              find.byType(PopupMenuButton<String>).first);
          menu.onSelected!('add');
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pumpAndSettle();
          expect(find.text('כבר חבר בקבוצה'), findsOneWidget);
          expect(find.text('הוזמן – ממתין לאישור'), findsOneWidget);
          for (final name in ['חבר קיים', 'מוזמן קודם']) {
            final row = find.ancestor(
                of: find.text(name), matching: find.byType(ListTile));
            final checkbox = tester.widget<Checkbox>(
                find.descendant(of: row, matching: find.byType(Checkbox)));
            expect(checkbox.value, isTrue);
            expect(checkbox.onChanged, isNull);
            await tester.tap(find.text(name));
          }
          expect(find.text('בחר חברים'), findsOneWidget);
          await tester.tap(find.text('משתמש חדש'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('הוסף 1 נבחרים'));
          await tester.pumpAndSettle();
          final posts = app.requests
              .where(
                  (r) => r.method == 'POST' && r.url.path.endsWith('/members'))
              .toList();
          expect(posts, hasLength(1));
          expect(jsonDecode(posts.single.body), {'userId': 'new-invite-user'});
          menu.onSelected!('add');
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pumpAndSettle();
          expect(find.text('הוזמן – ממתין לאישור'), findsNWidgets(2));
          expect(find.text('בחר חברים'), findsOneWidget);
          await tester.tap(find.text('ביטול'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await app.dispose(tester);
        }, () => app.client);
      });
    }

    testWidgets(
        '$chatKind displays a shared location map instead of the raw URL',
        (tester) async {
      final url = Uri.https('www.google.com', '/maps/search/',
          {'api': '1', 'query': 'רחובות'}).toString();
      final app = _ChatHarness(isGroup: isGroup, history: [
        {
          'id': 'location-preview-message',
          'sender_id': 'emoji-test-user',
          'sender_name': 'משתמש לבדיקה',
          'type': 'text',
          'body': 'רחובות\n$url',
          'created_at': '2026-09-17T14:09:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        expect(find.byType(LocationMessagePreview), findsOneWidget);
        expect(find.text('רחובות'), findsOneWidget);
        expect(find.text('www.google.com'), findsNothing);
        expect(
            find.byWidgetPredicate((widget) =>
                widget is InlineEmojiText &&
                widget.text.contains('https://www.google.com')),
            findsNothing);
        await tester.ensureVisible(find.text('רחובות'));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        await tester.tap(find.text('רחובות'));
        // Web chat also recognizes double-click-to-copy; let its timer expire.
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(find.text('Google Maps'), findsOneWidget);
        expect(find.text('Waze'), findsOneWidget);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind removes blank lines without merging content or losing emoji',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer,
            '\n שלום\r\n \t\r\n  שורה שנייה\n\n${inlineEmojiCharacter(1)}\n ');
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('chat-composer-action')));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('שלום\n  שורה שנייה\n[[bt-emoji:001]]');
        expect(app.controller(tester).text, isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    for (final stickers in [false, true]) {
      testWidgets(
          '$chatKind opens ${stickers ? 'stickers' : 'emoji'} with a mouse and an empty draft',
          (tester) async {
        final app = _ChatHarness(isGroup: isGroup);
        await http.runWithClient(() async {
          await app.mount(tester);
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 100)));
          await tester.pumpAndSettle();
          await tester.tap(app.composer, kind: PointerDeviceKind.mouse);
          await tester.pumpAndSettle();
          expect(app.controller(tester).text, isEmpty);
          final shortcut = stickers ? _stickerShortcut : _inlineEmojiShortcut;
          final gesture = await tester.startGesture(tester.getCenter(shortcut),
              kind: PointerDeviceKind.mouse);
          await tester.pump();
          expect(shortcut, findsOneWidget);
          expect(tester.widget<TextField>(app.composer).focusNode!.hasFocus,
              isTrue,
              reason: 'Focus must survive the mouse press on the shortcut');
          await gesture.up();
          for (var attempt = 0;
              _picker.evaluate().isEmpty && attempt < 8;
              attempt++) {
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 100)));
            await tester.pumpAndSettle();
          }
          expect(_picker, findsOneWidget,
              reason:
                  'panel=${find.byKey(const ValueKey('expression-picker-panel')).evaluate().length}; '
                  'requests=${app.requests.map((r) => r.url.path).toList()}');
          expect(_pickerShowsStickers(tester), stickers);
          expect(app.controller(tester).text, isEmpty);
          app.expectNothingSent();
          await app.dispose(tester);
        }, () => app.client);
      }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
    }

    testWidgets(
        '$chatKind switches recording and send without moving the composer',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final action = find.byKey(const ValueKey('chat-composer-action'));
        final tools = find.byKey(const ValueKey('chat-composer-shortcuts'));
        final inputRect = tester.getRect(app.composer);
        final toolsRect = tester.getRect(tools);
        final actionRect = tester.getRect(action);
        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(find.byIcon(Icons.send), findsNothing);
        expect(_stickerShortcut, findsOneWidget);
        expect(_inlineEmojiShortcut, findsOneWidget);
        expect(tester.widget<IconButton>(action).onPressed, isNotNull);
        await tester.tap(app.composer);
        await tester.pump();
        expect(app.controller(tester).text, isEmpty);
        _expectComposerShortcuts(tester, hasText: false);
        expect(find.byIcon(Icons.mic), findsOneWidget);
        expect(tester.getRect(app.composer), inputRect);
        expect(tester.getRect(tools), toolsRect);
        tester.widget<TextField>(app.composer).focusNode!.unfocus();
        await tester.pump();
        expect(_stickerShortcut, findsOneWidget);
        expect(_inlineEmojiShortcut, findsOneWidget);
        await tester.enterText(app.composer, 'שלום');
        await tester.pump();
        _expectComposerShortcuts(tester);
        expect(tester.getRect(app.composer), inputRect);
        expect(tester.getRect(tools), toolsRect);
        expect(tester.getRect(action), actionRect);
        await _focusComposer(tester, app);
        await tester.tap(action);
        await tester.pumpAndSettle();
        app.expectOneTextMessage('שלום');
        expect(app.controller(tester).text, isEmpty);
        expect(find.byIcon(Icons.mic), findsOneWidget);
        _expectComposerKeyboard(tester, app, visible: false);
        expect(_stickerShortcut, findsOneWidget);
        expect(_inlineEmojiShortcut, findsOneWidget);
        expect(tester.getRect(app.composer), inputRect);
        await tester.enterText(app.composer, 'נמחק');
        await tester.pump();
        _expectComposerKeyboard(tester, app, visible: true);
        expect(app.controller(tester).text, 'נמחק');
        expect(find.byIcon(Icons.send), findsOneWidget);
        app.controller(tester).clear();
        await tester.pump();
        expect(find.byIcon(Icons.mic), findsOneWidget);
        _expectComposerShortcuts(tester, hasText: false);
        expect(tester.getRect(tools), toolsRect);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind composer stays above the picker and respects a moved caret',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, '');
        await tester.pump();
        await tester.enterText(app.composer, 'שלום');
        await tester.pump();
        await _openShortcut(tester, stickers: false);
        final clicksAfterTyping =
            _keyboardAudioCalls.where((call) => call.method == 'resume').length;
        if (kIsWeb) expect(_keyboardSoundAssetReads, 0);
        if (!kIsWeb)
          expect(clicksAfterTyping, greaterThan(0),
              reason: _keyboardAudioCalls
                  .map((call) => call.method)
                  .toList()
                  .toString());
        final panel = find.byKey(const ValueKey('expression-picker-panel'));
        expect(tester.getRect(app.composer).bottom,
            lessThanOrEqualTo(tester.getRect(panel).top));
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 1);
        await tester.tap(_imageTile(1));
        await tester.pumpAndSettle();
        expect(inlineEmojiPlainText(controller.text),
            'ש${inlineEmojiCharacter(1)}לום');
        expect(find.byKey(const ValueKey('inline-custom-emoji-1')),
            findsOneWidget);
        expect(_picker, findsOneWidget);
        if (kIsWeb) expect(_keyboardSoundAssetReads, 0);
        if (!kIsWeb) {
          expect(
              _keyboardAudioCalls
                  .where((call) => call.method == 'resume')
                  .length,
              greaterThan(clicksAfterTyping));
          expect(
              _keyboardAudioCalls
                  .where((call) => call.method == 'setAudioContext')
                  .every((call) => (call.arguments as Map)['audioFocus'] == 0),
              isTrue);
        }
        app.expectNothingSent();
        await tester.tap(app.composer);
        await tester.pumpAndSettle();
        expect(_picker, findsNothing);
        expect(inlineEmojiPlainText(controller.text),
            'ש${inlineEmojiCharacter(1)}לום');
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind sends the visible draft while the picker stays open',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'שלום');
        await _openShortcut(tester, stickers: false);
        await tester.tap(_imageTile(1));
        await tester.pumpAndSettle();
        final first = inlineEmojiPlainText(app.controller(tester).text);
        await _focusComposer(tester, app);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        _expectComposerKeyboard(tester, app, visible: false);
        app.expectOneTextMessage(encodeInlineEmojiText(first));
        expect(_picker, findsOneWidget);
        expect(app.controller(tester).text, isEmpty);
        await tester.tap(_imageTile(2));
        await tester.pumpAndSettle();
        expect(inlineEmojiPlainText(app.controller(tester).text),
            inlineEmojiCharacter(2));
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        expect(_picker, findsNothing);
        _expectComposerKeyboard(tester, app, visible: false);
        await app.dispose(tester);
      }, () => app.client);
    });

    for (final catalogStatus in [200, 503]) {
      testWidgets(
          '$chatKind removed choices retain original IDs with catalog $catalogStatus',
          (tester) async {
        final app = _ChatHarness(
          isGroup: isGroup,
          catalogStatus: catalogStatus,
          removedArtwork: true,
        );
        await http.runWithClient(() async {
          await app.mount(tester);
          await _openPicker(tester, stickers: true, count: 48);
          await _openInlineTab(tester, count: 48);
          for (final id in [49, 84, 85, 150]) {
            await _enterSearch(tester, _labels[id - 1]);
            await tester.pumpAndSettle();
            expect(_grid, findsNothing);
            expect(find.byIcon(Icons.search_off), findsOneWidget);
          }
          await _enterSearch(tester, _labels[47]);
          await tester.pumpAndSettle();
          expect(_imageTile(48), findsOneWidget);
          await _selectEmoji(tester, 48);
          expect(inlineEmojiPlainText(app.controller(tester).text),
              inlineEmojiCharacter(48));
          app.expectNothingSent();
          await app.dispose(tester);
        }, () => app.client);
      });
    }

    testWidgets(
        '$chatKind emoji-only draft adds each choice on the left before and after send',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openShortcut(tester, stickers: false);
        double? firstChoiceX;
        for (final id in [1, 2, 3]) {
          await tester.tap(_imageTile(id));
          await tester.pumpAndSettle();
          final x = tester
              .getCenter(find.byKey(const ValueKey('inline-custom-emoji-1')))
              .dx;
          firstChoiceX ??= x;
          expect(x, closeTo(firstChoiceX, 0.01));
        }
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(app.composer).textDirection,
            TextDirection.rtl);
        final positions = [
          for (final id in [1, 2, 3])
            tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id'))).dx
        ];
        expect(positions[0], greaterThan(positions[1]));
        expect(positions[1], greaterThan(positions[2]));
        final editable = tester.state<EditableTextState>(find.descendant(
            of: app.composer, matching: find.byType(EditableText)));
        final controller = app.controller(tester);
        final caret = editable.renderEditable
            .getLocalRectForCaret(
                TextPosition(offset: controller.selection.extentOffset))
            .left;
        expect(caret, lessThan(positions.last));
        app.expectNothingSent();
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage(
            '[[bt-emoji:003]][[bt-emoji:002]][[bt-emoji:001]]');
        final sentPositions = [
          for (final id in [1, 2, 3])
            tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id'))).dx
        ];
        expect(sentPositions[0], greaterThan(sentPositions[1]));
        expect(sentPositions[1], greaterThan(sentPositions[2]));
        expect(tester.widget<TextField>(app.composer).textDirection,
            TextDirection.rtl);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind repeated emoji selections keep the picker open and append in order',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 3);
        await _openShortcut(tester, stickers: false);
        await _enterSearch(tester, 'אימוג׳י לבדיקה');
        await tester.pumpAndSettle();
        for (final id in [1, 2, 3]) {
          await tester.tap(_imageTile(id));
        }
        await tester.pumpAndSettle();
        expect(_picker, findsOneWidget);
        expect(
            tester
                .widget<EditableText>(find.descendant(
                    of: _search, matching: find.byType(EditableText)))
                .controller
                .text,
            'אימוג׳י לבדיקה');
        final text =
            '${_draft.substring(0, 3)}${inlineEmojiCharacter(3)}${inlineEmojiCharacter(2)}${inlineEmojiCharacter(1)}${_draft.substring(3)}';
        expect(inlineEmojiPlainText(controller.text), text);
        expect(tester.widget<TextField>(app.composer).textDirection,
            TextDirection.rtl);
        final positions = [
          for (final id in [1, 2, 3])
            tester.getCenter(find.byKey(ValueKey('inline-custom-emoji-$id'))).dx
        ];
        expect(positions[0], greaterThan(positions[1]));
        expect(positions[1], greaterThan(positions[2]));
        final editable = tester
            .state<EditableTextState>(find.descendant(
                of: app.composer, matching: find.byType(EditableText)))
            .renderEditable;
        final runStart = controller.text.indexOf('\u2066') + 1;
        final caret = [
          for (var i = 0; i <= 3; i++)
            editable
                .getLocalRectForCaret(TextPosition(
                    offset: runStart + i,
                    affinity: i == 3
                        ? TextAffinity.upstream
                        : TextAffinity.downstream))
                .left
        ];
        for (var i = 0; i < 3; i++) expect(caret[i], lessThan(caret[i + 1]));
        app.expectNothingSent();
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage(encodeInlineEmojiText(text));
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind repeated stickers send separately in order and preserve the draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        final controller = app.controller(tester);
        controller.selection =
            const TextSelection(baseOffset: 5, extentOffset: 2);
        final before = controller.value;
        for (final id in [1, 2, 3]) {
          await _openShortcut(tester, stickers: true);
          await _selectEmoji(tester, id);
        }
        expect(_picker, findsNothing);
        for (var i = 0; i < 30; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        expect(app.uploads, hasLength(3));
        expect(app.sentHttpMessages, hasLength(3));
        final files = app.sentHttpMessages
            .map((request) => jsonDecode(request.body)['fileName'])
            .toList();
        expect(files, [
          'betshuva-sticker-01.png',
          'betshuva-sticker-02.png',
          'betshuva-sticker-03.png'
        ]);
        expect(controller.value, before);
        expect(_picker, findsNothing);
        await app.dispose(tester);
      }, () => app.client);
    }, skip: kIsWeb);

    testWidgets(
        '$chatKind composer shortcuts open the requested mode and retain the caret',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        await tester.pump();
        _expectComposerShortcuts(tester);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 3);
        final before = controller.value;

        for (final stickers in [true, false]) {
          await _openShortcut(tester, stickers: stickers);
          expect(controller.value, before);
          app.expectNothingSent();
          await tester.tap(find.byTooltip('סגירה'));
          await tester.pumpAndSettle();
          expect(_picker, findsNothing);
          expect(controller.value, before);
        }

        await _openShortcut(tester, stickers: false);
        await _selectEmoji(tester, 2);
        final text =
            '${_draft.substring(0, 3)}${inlineEmojiCharacter(2)}${_draft.substring(3)}';
        expect(inlineEmojiPlainText(controller.text), text);
        expect(_logicalSelection(controller),
            const TextSelection.collapsed(offset: 4));
        app.expectNothingSent();
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage(encodeInlineEmojiText(text));
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind sticker shortcut immediately sends media and keeps the draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 3);
        final before = controller.value;
        await _openShortcut(tester, stickers: true);
        await _selectEmoji(tester, 1);
        app.expectOneSticker();
        expect(controller.value, before);
        await app.dispose(tester);
      }, () => app.client);
      // Web resumable media is exercised by the production-browser smoke.
    }, skip: kIsWeb);

    testWidgets('$chatKind composer shortcuts fit a 320-pixel viewport',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'בדיקה');
        await tester.pump();
        _expectComposerShortcuts(tester);
        expect(tester.takeException(), isNull);
        expect(tester.getSize(app.composer).width, greaterThanOrEqualTo(80));
        for (final tool in [
          find.byIcon(Icons.send),
          _inlineEmojiShortcut,
          _stickerShortcut,
          find.byIcon(Icons.attach_file),
        ]) {
          final rect = tester.getRect(tool);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
        }
        await _openPicker(tester);
        final tile = _imageTile(1);
        final image = find.descendant(of: tile, matching: find.byType(Image));
        expect(
            tester.getSize(tile).width, greaterThanOrEqualTo(kIsWeb ? 36 : 44));
        expect(tester.getSize(tile).height,
            greaterThanOrEqualTo(kIsWeb ? 36 : 44));
        if (kIsWeb) {
          expect(tester.getSize(image).width, closeTo(29.04, 0.001));
          expect(tester.getSize(image).height, closeTo(29.04, 0.001));
        }
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    for (final stickers in [true, false]) {
      testWidgets(
          '$chatKind ${stickers ? 'sticker' : 'inline emoji'} shortcut honors its receiving filter',
          (tester) async {
        final app = _ChatHarness(
            isGroup: isGroup, allowText: stickers, allowImages: !stickers);
        await http.runWithClient(() async {
          await app.mount(tester);
          app.controller(tester).text = 'בדיקה';
          await tester.pump();
          await tester.tap(stickers ? _stickerShortcut : _inlineEmojiShortcut);
          await tester.pumpAndSettle();
          expect(_picker, findsNothing,
              reason: 'A blocked shortcut must not open the other mode');
          expect(
              find.textContaining(
                  '${stickers ? 'מדבקות' : 'אימוג׳י בתוך הטקסט'} חסום'),
              findsOneWidget);
          expect(
              app.requests.where((request) =>
                  request.url.path.endsWith('/expressions/catalog')),
              isEmpty);
          app.expectNothingSent();
          expect(tester.takeException(), isNull);
          await app.dispose(tester);
        }, () => app.client);
      });
    }

    testWidgets('$chatKind downloads the colored sticker from a dual catalog',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup, coloredArtwork: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 3);
        final before = controller.value;
        await _openPicker(tester, stickers: true);
        expect(_imageTile(1), findsNothing);
        expect(_imageTile(1, colored: true), findsOneWidget);
        await _selectEmoji(tester, 1, colored: true);

        app.expectOneSticker();
        expect(controller.value, before);
        expect(
            app.requests.where((request) =>
                request.method == 'GET' &&
                request.url.path.endsWith(
                    '/expression-library/user-20261008-color/sticker-01.png')),
            hasLength(1));
        expect(
            app.requests.where((request) =>
                request.method == 'GET' &&
                request.url.path.endsWith(
                    '/expression-library/user-20260907/sticker-01.png')),
            isEmpty);
        await app.dispose(tester);
      }, () => app.client);
      // Browser resumable uploads use XMLHttpRequest and bypass this HTTP mock.
      // The production-bundle Playwright smoke covers the web media transport.
    }, skip: kIsWeb);

    testWidgets('$chatKind colored artwork retains the saved inline emoji ID',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup, coloredArtwork: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, 'שלום 😀 סוף');
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 5);
        await _openPicker(tester);
        expect(_imageTile(1), findsNothing);
        expect(_imageTile(1, colored: true), findsOneWidget);
        await _selectEmoji(tester, 1, colored: true);

        expect(inlineEmojiPlainText(controller.text),
            'שלום ${inlineEmojiCharacter(1)}😀 סוף');
        app.expectNothingSent();
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('שלום [[bt-emoji:001]]😀 סוף');
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind sends a sticker immediately without sending or clearing the draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = 'שלום ${inlineEmojiCharacter(2)} טיוטה';
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection(
            baseOffset: 7, extentOffset: 2, isDirectional: true);
        final before = controller.value;
        await _openPicker(tester, stickers: true);
        app.expectNothingSent();

        await _selectEmoji(tester, 1);

        app.expectOneSticker();
        expect(controller.value, before);
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
      // Browser resumable uploads use XMLHttpRequest and bypass this HTTP mock.
      // The production-bundle Playwright smoke covers the web media transport.
    }, skip: kIsWeb);

    testWidgets('$chatKind keeps the draft after a failed sticker upload',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup, uploadStatus: 500);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, _draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 3);
        final before = controller.value;
        await _openPicker(tester, stickers: true);
        await _selectEmoji(tester, 1);

        expect(app.uploads, hasLength(1));
        expect(app.sentHttpMessages, isEmpty);
        expect(app.sentSocketMessages, isEmpty);
        expect(controller.value, before);
        expect(find.text('העלאת המדבקה נכשלה'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
      // Browser resumable uploads use XMLHttpRequest and bypass this HTTP mock.
      // The production-bundle Playwright smoke covers the web media transport.
    }, skip: kIsWeb);

    testWidgets(
        '$chatKind inserts a small emoji at the caret and sends only on explicit send',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        const draft = 'שלום abc עולם';
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        expect(controller, isA<InlineEmojiController>());
        controller.selection = const TextSelection.collapsed(offset: 5);
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pumpAndSettle();
        await _openPicker(tester);
        final inlineTile = _imageTile(1);
        final picture =
            find.descendant(of: inlineTile, matching: find.byType(Image));
        expect(tester.widget<Image>(picture).width, closeTo(29.04, 0.001));
        expect(tester.widget<Image>(picture).height, closeTo(29.04, 0.001));
        if (kIsWeb) {
          expect(tester.getSize(picture).width, closeTo(29.04, 0.001));
          expect(tester.getSize(picture).height, closeTo(29.04, 0.001));
        }
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)))
                .bottom,
            lessThanOrEqualTo(268));
        final hitSize = tester.getSize(inlineTile);
        expect(hitSize.width, greaterThanOrEqualTo(kIsWeb ? 36 : 44));
        expect(hitSize.height, greaterThanOrEqualTo(kIsWeb ? 36 : 44));
        app.expectNothingSent();
        expect(
            app.requests.where(
                (request) => request.url.path.endsWith('/expressions/catalog')),
            hasLength(1));
        await _selectEmoji(tester, 1);
        final raw = 'שלום ${inlineEmojiCharacter(1)}abc עולם';
        expect(inlineEmojiPlainText(controller.text), raw);
        expect(_logicalSelection(controller),
            const TextSelection.collapsed(offset: 6));
        app.expectNothingSent();
        _expectSmallEmoji(tester, app.composer, 1);
        expect(encodeInlineEmojiText(raw), 'שלום [[bt-emoji:001]]abc עולם');

        await _focusComposer(tester, app);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        _expectComposerKeyboard(tester, app, visible: false);
        app.expectOneTextMessage('שלום [[bt-emoji:001]]abc עולם');
        expect(inlineEmojiPlainText(controller.text), isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets('$chatKind can search and close images without changing draft',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = '$_draft ${inlineEmojiCharacter(1)}';
        await tester.enterText(app.composer, draft);
        app.controller(tester).selection = const TextSelection(
          baseOffset: 5,
          extentOffset: 1,
        );
        final before = app.controller(tester).value;
        await _openPicker(tester);
        await _enterSearch(tester, _labels.last);
        await tester.pumpAndSettle();
        _expectFlatImages(tester,
            count:
                _labels.where((label) => label.contains(_labels.last)).length);
        expect(_imageTile(150), findsOneWidget);
        app.expectNothingSent();

        await tester.tap(find.byTooltip('סגירה'));
        await tester.pumpAndSettle();
        expect(app.controller(tester).value, before);
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind inserts another custom image beside a saved emoji without autosending',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = 'שלום abc ${inlineEmojiCharacter(1)} סוף';
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 5);

        await _openPicker(tester);
        await _openInlineTab(tester);
        app.expectNothingSent();
        await _selectEmoji(tester, 3);

        expect(inlineEmojiPlainText(controller.text),
            'שלום ${inlineEmojiCharacter(3)}abc ${inlineEmojiCharacter(1)} סוף');
        expect(_logicalSelection(controller),
            const TextSelection.collapsed(offset: 6));
        _expectSmallEmoji(tester, app.composer, 1);
        app.expectNothingSent();

        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage(
            'שלום [[bt-emoji:003]]abc [[bt-emoji:001]] סוף');
        expect(inlineEmojiPlainText(controller.text), isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind switches both image modes and replaces a reversed selection inline',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        final draft = 'לפני ${inlineEmojiCharacter(2)} להחליף אחרי';
        final start = draft.indexOf('להחליף');
        final end = start + 'להחליף'.length;
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection =
            // The existing emoji has a pair of editor-only bidi isolates.
            TextSelection(baseOffset: end + 2, extentOffset: start + 2);

        await _openPicker(tester);
        await _openInlineTab(tester);
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        await _openShortcut(tester, stickers: true);
        _expectFlatImages(tester, stickers: true);
        await _enterSearch(tester, _labels.last);
        await tester.pumpAndSettle();
        _expectFlatImages(tester, count: 1, stickers: true);
        expect(_imageTile(150), findsOneWidget);

        await _openInlineTab(tester);
        await _enterSearch(tester, _labels[2]);
        await tester.pumpAndSettle();
        expect(_imageTile(1), findsNothing);
        expect(_imageTile(3), findsOneWidget);
        app.expectNothingSent();
        await _selectEmoji(tester, 3);

        expect(inlineEmojiPlainText(controller.text),
            '${draft.substring(0, start)}${inlineEmojiCharacter(3)}${draft.substring(end)}');
        expect(_logicalSelection(controller),
            TextSelection.collapsed(offset: start + 1));
        _expectSmallEmoji(tester, app.composer, 2);
        app.expectNothingSent();

        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('לפני [[bt-emoji:002]] [[bt-emoji:003]] אחרי');
        expect(inlineEmojiPlainText(controller.text), isEmpty);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind replaces a reversed selection and preserves the caret on reopening',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        const draft = 'לפני להחליף אחרי';
        final start = draft.indexOf('להחליף');
        final end = start + 'להחליף'.length;
        await tester.enterText(app.composer, draft);
        final controller = app.controller(tester);
        controller.selection =
            TextSelection(baseOffset: end, extentOffset: start);
        await _openPicker(tester);
        await _selectEmoji(tester, 2);
        final first =
            '${draft.substring(0, start)}${inlineEmojiCharacter(2)}${draft.substring(end)}';
        expect(inlineEmojiPlainText(controller.text), first);
        expect(_logicalSelection(controller),
            TextSelection.collapsed(offset: start + 1));
        app.expectNothingSent();

        await _openPicker(tester);
        await _enterSearch(tester, _labels.last);
        await tester.pumpAndSettle();
        await _selectEmoji(tester, 150);
        final expected =
            '${draft.substring(0, start)}${inlineEmojiCharacter(150)}${inlineEmojiCharacter(2)}${draft.substring(end)}';
        expect(inlineEmojiPlainText(controller.text), expected);
        expect(_logicalSelection(controller),
            TextSelection.collapsed(offset: start + 2));
        _expectSmallEmoji(tester, app.composer, 2);
        _expectSmallEmoji(tester, app.composer, 150);
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind hydrates an own text emoji for editing and patches encoded text',
        (tester) async {
      const original = 'עריכה [[bt-emoji:001]] המשך';
      final app = _ChatHarness(isGroup: isGroup, history: [
        {
          'id': 'existing-own-emoji',
          'sender_id': 'emoji-test-user',
          'sender_name': 'משתמש לבדיקה',
          'type': 'text',
          'body': original,
          'created_at': '2026-09-17T00:00:00Z',
        },
      ]);
      await http.runWithClient(() async {
        await app.mount(tester);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        await tester
            .longPress(find.byKey(const ValueKey('inline-custom-emoji-1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'The existing-message actions must fit before editing');
        await tester.tap(find.text('ערוך הודעה'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'Loading the existing emoji into the editor must fit');
        final controller = app.controller(tester);
        final raw = 'עריכה ${inlineEmojiCharacter(1)} המשך';
        expect(inlineEmojiPlainText(controller.text), raw);
        controller.selection =
            TextSelection.collapsed(offset: controller.text.length);
        await _openPicker(tester);
        await _selectEmoji(tester, 2);
        expect(inlineEmojiPlainText(controller.text),
            '$raw${inlineEmojiCharacter(2)}');
        app.expectNothingSent();
        expect(app.requests.where((request) => request.method == 'PATCH'),
            isEmpty);

        await _focusComposer(tester, app);
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        _expectComposerKeyboard(tester, app, visible: false);
        final patches =
            app.requests.where((request) => request.method == 'PATCH').toList();
        expect(patches, hasLength(1));
        expect(
            patches.single.url.path, endsWith('/messages/existing-own-emoji'));
        expect(jsonDecode(patches.single.body),
            {'body': '$original[[bt-emoji:002]]'});
        app.expectNothingSent();
        expect(inlineEmojiPlainText(controller.text), isEmpty);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 1);
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 2);
        await app.dispose(tester);
      }, () => app.client);
    });

    testWidgets(
        '$chatKind typed Unicode emoji is enlarged without media upload',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup);
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.enterText(app.composer, '😀');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        final messages = isGroup
            ? app.sentSocketMessages
            : app.sentHttpMessages
                .map((request) =>
                    jsonDecode(request.body) as Map<String, dynamic>)
                .toList();
        expect(messages, hasLength(1));
        expect(messages.single['text'], '😀');
        expect(app.uploads, isEmpty);
        final emoji = find.byKey(const ValueKey('message-unicode-emoji-1f600'));
        expect(emoji, findsOneWidget);
        expect(tester.getSize(emoji), const Size(44, 44));
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  testWidgets('colored bundled fallback supplies all 150 images in both modes',
      (tester) async {
    final app =
        _ChatHarness(isGroup: false, catalogStatus: 503, coloredArtwork: true);
    await http.runWithClient(() async {
      await app.mount(tester);
      await _openPicker(tester, stickers: true);
      expect(_bundledCatalogReads, 1);
      expect(_imageTile(1, colored: true), findsOneWidget);
      expect(_imageTile(1), findsNothing);
      await _openInlineTab(tester);
      await _enterSearch(tester, _labels.last);
      await tester.pumpAndSettle();
      await _selectEmoji(tester, 150, colored: true);
      expect(inlineEmojiPlainText(app.controller(tester).text),
          inlineEmojiCharacter(150));
      app.expectNothingSent();
      await app.dispose(tester);
    }, () => app.client);
  });

  for (final isGroup in [false, true]) {
    final chatKind = isGroup ? 'group' : 'private';
    for (final policy in [
      (allowText: false, allowImages: false),
      (allowText: false, allowImages: true),
      (allowText: true, allowImages: false),
      (allowText: true, allowImages: true),
    ]) {
      testWidgets('$chatKind separates sticker and text permissions: $policy',
          (tester) async {
        final app = _ChatHarness(
            isGroup: isGroup,
            allowText: policy.allowText,
            allowImages: policy.allowImages);
        await http.runWithClient(() async {
          await app.mount(tester);
          await tester.tap(find.byIcon(Icons.attach_file));
          await tester.pumpAndSettle();
          final menu = find.byKey(const ValueKey('chat-attachment-menu'));
          expect(menu, findsOneWidget);
          expect(find.text('מדבקות ואימוג׳י'), findsNothing);
          expect(
              find.descendant(
                  of: menu,
                  matching: find.byIcon(Icons.emoji_emotions_outlined)),
              findsNothing);
          Navigator.of(tester.element(menu)).pop();
          await tester.pumpAndSettle();
          final available = policy.allowText || policy.allowImages;
          if (!available) {
            app.controller(tester).text = 'בדיקה';
            await tester.pump();
            for (final shortcut in [
              (finder: _stickerShortcut, label: 'מדבקות'),
              (finder: _inlineEmojiShortcut, label: 'אימוג׳י בתוך הטקסט'),
            ]) {
              await tester.tap(shortcut.finder);
              await tester.pumpAndSettle();
              expect(_picker, findsNothing);
              expect(find.textContaining('${shortcut.label} חסום'),
                  findsOneWidget);
              ScaffoldMessenger.of(tester.element(app.composer))
                  .clearSnackBars();
              await tester.pumpAndSettle();
            }
            app.expectNothingSent();
          } else {
            await _openPicker(tester,
                stickers: policy.allowImages,
                defaultStickers: policy.allowImages);
            expect(find.byType(ChoiceChip), findsNothing);
            if (policy.allowText) {
              await _openInlineTab(tester);
              await _selectEmoji(tester, 1);
              expect(inlineEmojiPlainText(app.controller(tester).text),
                  inlineEmojiCharacter(1));
              app.expectNothingSent();
            } else {
              await _selectEmoji(tester, 1);
              app.expectOneSticker();
              expect(
                  inlineEmojiPlainText(app.controller(tester).text), isEmpty);
            }
          }
          await app.dispose(tester);
        }, () => app.client);
        // Only the image-only policy sends media; other web policy cases retain
        // the real picker and insertion behavior under the HTTP mock.
      }, skip: kIsWeb && !policy.allowText && policy.allowImages);
    }

    testWidgets(
        '$chatKind catalog failure exposes all 150 images in both modes',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup, catalogStatus: 503);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester, stickers: true);
        expect(_bundledCatalogReads, 1);
        _expectFlatImages(tester, stickers: true);
        await _openInlineTab(tester);
        await _enterSearch(tester, _labels.last);
        await tester.pumpAndSettle();
        await _selectEmoji(tester, 150);
        expect(inlineEmojiPlainText(app.controller(tester).text),
            inlineEmojiCharacter(150));
        app.expectNothingSent();
        _expectSmallEmoji(tester, app.composer, 150);
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('[[bt-emoji:150]]');
        _expectSmallEmoji(tester, find.byType(InlineEmojiText), 150);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  for (final isGroup in [false, true]) {
    testWidgets(
        'split server libraries refresh additions and send new emoji and stickers ($isGroup)',
        (tester) async {
      final app = _ChatHarness(isGroup: isGroup, splitCatalog: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester, count: 49);
        app.liveEmojiCount = 50;
        app.liveStickerCount = 151;
        await tester.pump(const Duration(seconds: 16));
        await tester.pumpAndSettle();
        expect(
            tester.widget<SliverGrid>(_grid).delegate.estimatedChildCount, 50);
        await _enterSearch(tester, 'אימוג׳י שרת 50');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey(
            'expression-image-https://betshuva.com/betshuva-app/api/expressions/emoji/151')));
        await tester.pumpAndSettle();
        expect(encodeInlineEmojiText(app.controller(tester).text),
            '[[bt-emoji:151]]');
        await tester.pump();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage('[[bt-emoji:151]]');
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        await _openPicker(tester, stickers: true, count: 151);
        await _enterSearch(tester, 'מדבקה שרת 151');
        await tester.pumpAndSettle();
        final uploadsBefore =
            app.requests.where((r) => r.url.path.endsWith('/upload')).length;
        await tester.tap(find.byKey(const ValueKey(
            'expression-image-https://betshuva.com/betshuva-app/expression-library/stickers/new-151.png')));
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)));
        }
        expect(app.requests.where((r) => r.url.path.endsWith('/upload')).length,
            uploadsBefore + 1);
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  for (final isGroup in [false, true]) {
    testWidgets(
        'custom emoji growth keeps Unicode unchanged in 320-pixel chat ($isGroup)',
        (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final app = _ChatHarness(
        isGroup: isGroup,
        splitCatalog: true,
        extraEmojiItems: _newLibraryEmojiItems,
        history: [
          {
            'id': 'existing-unicode-emoji-message',
            'sender_id': 'emoji-test-recipient',
            'body': '😀',
            'created_at': '2026-10-13T00:00:00Z',
          },
          {
            'id': 'existing-new-library-emoji-message',
            'sender_id': 'emoji-test-recipient',
            'body': 'חדש [[bt-emoji:167]] [[bt-emoji:182]] '
                '[[bt-emoji:183]] [[bt-emoji:198]] '
                '[[bt-emoji:199]] [[bt-emoji:214]] טוב',
            'created_at': '2026-10-13T00:01:00Z',
          },
        ],
      );
      app.liveEmojiCount = 65;
      await http.runWithClient(() async {
        await app.mount(tester);
        await tester.pumpAndSettle();
        final customMessageSize = isGroup ? 24.5025 : 22.869;
        for (final id in [167, 182, 183, 198, 199, 214]) {
          final image = find.byKey(ValueKey('inline-custom-emoji-$id'));
          expect(image, findsOneWidget);
          expect(
              tester.getSize(image).width, closeTo(customMessageSize, 0.001));
          expect(
              tester.getSize(image).height, closeTo(customMessageSize, 0.001));
        }
        final unicode =
            find.byKey(const ValueKey('message-unicode-emoji-1f600'));
        expect(unicode, findsOneWidget);
        expect(tester.getSize(unicode), const Size(44, 44),
            reason:
                'Ordinary Unicode emoji retain their previous display size');
        await tester.enterText(app.composer, 'שלום 😀 עולם');
        final controller = app.controller(tester);
        controller.selection = const TextSelection.collapsed(offset: 5);
        await _openPicker(tester, count: 113);
        await _enterSearch(tester, 'קרם');
        await tester.pumpAndSettle();
        expect(
            tester.widget<SliverGrid>(_grid).delegate.estimatedChildCount, 16);
        for (final entry in [
          (id: 167, label: 'שמחה — קרם'),
          (id: 183, label: 'שמחה — ירוק בהיר'),
          (id: 214, label: 'תסכול — ירוק חזק'),
        ]) {
          await _enterSearch(tester, entry.label);
          await tester.pumpAndSettle();
          expect(
              tester.widget<SliverGrid>(_grid).delegate.estimatedChildCount, 1);
          final tile = find.byKey(ValueKey(
              'expression-image-https://betshuva.com/betshuva-app/api/expressions/emoji/${entry.id}'));
          final picture =
              find.descendant(of: tile, matching: find.byType(Image));
          expect(tester.widget<Image>(picture).width, closeTo(29.04, 0.001));
          expect(tester.widget<Image>(picture).height, closeTo(29.04, 0.001));
          expect(tester.getRect(tile).left, greaterThanOrEqualTo(0));
          expect(tester.getRect(tile).right, lessThanOrEqualTo(320));
        }
        await tester.tap(find.byKey(const ValueKey(
            'expression-image-https://betshuva.com/betshuva-app/api/expressions/emoji/214')));
        await tester.pumpAndSettle();
        const sentText = 'שלום [[bt-emoji:214]]😀 עולם';
        expect(encodeInlineEmojiText(controller.text), sentText);
        _expectSmallEmoji(tester, app.composer, 214);
        app.expectNothingSent();
        await tester.tap(find.byIcon(Icons.send));
        await tester.pumpAndSettle();
        app.expectOneTextMessage(sentText);
        final sentBody = find.byWidgetPredicate(
            (widget) => widget is InlineEmojiText && widget.text == sentText);
        expect(sentBody, findsOneWidget);
        final sentCustom = find.descendant(
            of: sentBody,
            matching: find.byKey(const ValueKey('inline-custom-emoji-214')));
        expect(tester.getSize(sentCustom).width,
            closeTo(customMessageSize, 0.001));
        final sentUnicode = find.descendant(
            of: sentBody,
            matching:
                find.byKey(const ValueKey('message-unicode-emoji-1f600')));
        expect(tester.getSize(sentUnicode).width,
            closeTo(isGroup ? 22.275 : 20.79, 0.001),
            reason: 'Unicode size remains unchanged in mixed messages');
        expect(tester.takeException(), isNull);
        await app.dispose(tester);
      }, () => app.client);
    });
  }

  for (final viewport in [
    (size: const Size(390, 844), keyboard: 300.0),
    (size: const Size(320, 568), keyboard: 300.0),
    (size: const Size(568, 320), keyboard: 180.0),
  ]) {
    testWidgets('both emoji lists fit ${viewport.size} with the keyboard open',
        (tester) async {
      tester.view.physicalSize = viewport.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final app = _ChatHarness(isGroup: false, withHistory: true);
      await http.runWithClient(() async {
        await app.mount(tester);
        await _openPicker(tester, stickers: true);
        tester.view.viewInsets = FakeViewPadding(bottom: viewport.keyboard);
        await _enterSearch(tester, _labels.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)))
                .bottom,
            lessThanOrEqualTo(viewport.size.height - viewport.keyboard));
        await _openInlineTab(tester);
        final standardScroll = find
            .descendant(
                of: find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)),
                matching: find.byType(Scrollable))
            .first;
        await _enterSearch(tester, _labels.first);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.descendant(
                    of: _picker, matching: find.byType(CustomScrollView)))
                .bottom,
            lessThanOrEqualTo(viewport.size.height - viewport.keyboard));
        app.expectNothingSent();
        final smile = _imageTile(1);
        await tester.scrollUntilVisible(smile, 60, scrollable: standardScroll);
        await tester.pumpAndSettle();
        await tester.tap(smile);
        await tester.pumpAndSettle();
        expect(_picker, findsOneWidget);
        await _ensureDoneVisible(tester);
        await tester.tap(_done);
        await tester.pumpAndSettle();
        expect(_picker, findsNothing);
        expect(inlineEmojiPlainText(app.controller(tester).text),
            inlineEmojiCharacter(1));
        app.expectNothingSent();
        await app.dispose(tester);
      }, () => app.client);
    });
  }
}
