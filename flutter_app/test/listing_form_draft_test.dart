import 'dart:async';
import 'dart:convert';

import 'package:betshuva/listing_form_draft.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _preferencesChannel =
    MethodChannel('plugins.flutter.io/shared_preferences');

/// Exercise the storage boundary, including writes that finish out of order.
class _PreferencesBackend {
  final values = <String, Object>{};
  Future<void> Function(String key, Object value)? beforeWrite;

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'getAll':
        return Map<String, Object>.from(values);
      case 'setString':
        final arguments = call.arguments as Map;
        final key = arguments['key'] as String;
        final value = arguments['value'] as String;
        await beforeWrite?.call(key, value);
        values[key] = value;
        return true;
      case 'remove':
        values.remove((call.arguments as Map)['key']);
        return true;
      default:
        throw StateError('Unexpected preferences call: ${call.method}');
    }
  }
}

Map<String, dynamic> _draft(String revision, String title) => {
      'version': 1,
      'revision': revision,
      'fields': {'title': title, 'description': ''},
      'images': <String?>[],
      'video_url': null,
      'title_manually_edited': true,
    };

String _token(Map<String, dynamic> claims) =>
    'header.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.signature';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PreferencesBackend backend;

  setUp(() {
    SharedPreferences.resetStatic();
    backend = _PreferencesBackend();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_preferencesChannel, backend.handle);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_preferencesChannel, null);
    SharedPreferences.resetStatic();
  });

  test('a partial draft persists and remains separate from another account',
      () async {
    final first = ListingFormDraftStore('account/one');
    final second = ListingFormDraftStore('account/two');
    await first.save(_draft('first', ''));
    await second.save(_draft('second', 'חשבון אחר'));

    final restored = await ListingFormDraftStore('account/one').load();
    expect(restored?['fields'], {'title': '', 'description': ''});
    expect((await second.load())?['fields'],
        {'title': 'חשבון אחר', 'description': ''});
    expect(backend.values.length, 2);
  });

  test('completed media updates its revision without changing saved text',
      () async {
    final store = ListingFormDraftStore('media');
    final original = {
      ..._draft('saved', 'כותרת ידנית'),
      'fields': {'title': 'כותרת ידנית', 'description': 'תיאור ידני'},
      'video_url': '/previous.mp4',
    };
    await store.save(original);
    await store.updateMedia('saved', ['/first.jpg', null, '/third.jpg']);
    expect((await store.load())?['video_url'], '/previous.mp4');

    await store.updateMedia('saved', ['/first.jpg', null, '/third.jpg'],
        videoUrl: '/completed.mp4', updateVideo: true);
    final restored = await store.load();
    expect(restored?['fields'], original['fields']);
    expect(restored?['title_manually_edited'], true);
    expect(restored?['images'], ['/first.jpg', null, '/third.jpg']);
    expect(restored?['video_url'], '/completed.mp4');
  });

  test('background media from an old editor cannot replace a newer draft',
      () async {
    final oldEditor = ListingFormDraftStore('overlap-save');
    final newEditor = ListingFormDraftStore('overlap-save');
    await oldEditor.save(_draft('old', 'טיוטה קודמת'));
    final writingMedia = Completer<void>();
    final releaseMedia = Completer<void>();
    backend.beforeWrite = (key, value) async {
      if ((value as String).contains('/late.jpg')) {
        writingMedia.complete();
        await releaseMedia.future;
      }
    };

    final mediaWrite = oldEditor.updateMedia('old', ['/late.jpg']);
    await writingMedia.future.timeout(const Duration(seconds: 5));
    final newerWrite = newEditor.save(_draft('new', 'טיוטה חדשה'));
    // Let a concurrent storage write proceed if it is not properly queued.
    await Future<void>.delayed(Duration.zero);
    releaseMedia.complete();
    await Future.wait([mediaWrite, newerWrite]);

    final restored = await newEditor.load();
    expect(restored?['revision'], 'new');
    expect((restored?['fields'] as Map)['title'], 'טיוטה חדשה');
    expect(restored?['images'], isEmpty);
  });

  test('publishing and removing a draft prevents upload completion reviving it',
      () async {
    final editor = ListingFormDraftStore('overlap-remove');
    final publisher = ListingFormDraftStore('overlap-remove');
    await editor.save(_draft('published', 'מודעה שפורסמה'));
    final writingMedia = Completer<void>();
    final releaseMedia = Completer<void>();
    backend.beforeWrite = (key, value) async {
      if ((value as String).contains('/late.jpg')) {
        writingMedia.complete();
        await releaseMedia.future;
      }
    };

    final mediaWrite = editor.updateMedia('published', ['/late.jpg']);
    await writingMedia.future.timeout(const Duration(seconds: 5));
    final removal = publisher.remove();
    await Future<void>.delayed(Duration.zero);
    releaseMedia.complete();
    await Future.wait([mediaWrite, removal]);

    expect(await publisher.load(), isNull);
    await editor.updateMedia('published', ['/even-later.jpg']);
    expect(await publisher.load(), isNull);
    expect(backend.values, isEmpty);
  });

  test('an upload for a superseded revision leaves the newer draft intact',
      () async {
    final oldEditor = ListingFormDraftStore('superseded');
    final newEditor = ListingFormDraftStore('superseded');
    await oldEditor.save(_draft('old', 'ישן'));
    await newEditor.save(_draft('new', 'חדש'));
    await oldEditor.updateMedia('old', ['/old.jpg'],
        videoUrl: '/old.mp4', updateVideo: true);

    expect(await newEditor.load(), _draft('new', 'חדש'));
  });

  test('loading refreshes media changes made after preferences were cached',
      () async {
    final store = ListingFormDraftStore('fresh-load');
    await store.save(_draft('saved', 'טיוטה'));
    final key = backend.values.keys.single;
    backend.values[key] = jsonEncode({
      ..._draft('saved', 'טיוטה'),
      'images': ['/finished-elsewhere.jpg'],
    });

    expect((await store.load())?['images'], ['/finished-elsewhere.jpg']);
  });

  test('malformed JSON and unsupported draft versions do not block the editor',
      () async {
    final store = ListingFormDraftStore('damaged');
    await store.save(_draft('initial', ''));
    final key = backend.values.keys.single;
    for (final raw in ['{broken', '[]', 'null', '{"version":2}']) {
      backend.values[key] = raw;
      expect(await store.load(), isNull, reason: raw);
    }
  });

  test('account identity uses profile or JWT claims without persisting tokens',
      () async {
    final token =
        _token({'id': 'jwt-account', 'email': 'private@example.test'});
    expect(listingDraftAccountId({'id': 'profile-account'}, token),
        'profile-account');
    expect(listingDraftAccountId(null, token), 'jwt-account');
    expect(listingDraftAccountId(null, _token({'sub': 'subject'})), 'subject');
    expect(listingDraftAccountId(null, _token({'userId': 'legacy'})), 'legacy');
    expect(listingDraftAccountId(null, 'invalid-token'), isNull);
    expect(listingDraftAccountId(null, _token({'email': 'only@example.test'})),
        isNull);

    final store = ListingFormDraftStore(listingDraftAccountId(null, token)!);
    await store.save(_draft('snapshot', 'טיוטה ללא מזהה התחברות'));
    final persisted = '${backend.values.keys}${backend.values.values}';
    expect(persisted, isNot(contains(token)));
    expect(persisted, isNot(contains('private@example.test')));
  });
}
