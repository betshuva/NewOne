import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:betshuva/main.dart' show VoiceMessagePlayer;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _AudioPlatform extends AudioplayersPlatformInterface {
  final events = <String, StreamController<AudioEvent>>{};
  final sources = <String, String>{};
  final resumedSources = <String>[];
  final positions = <String, int>{};
  final seeks = <int>[];
  final mimeTypes = <String?>[];
  final requestedSources = <String>[];
  int failedSources = 0;
  Future<void> Function(String)? sourceGate;

  @override
  Future<void> create(String playerId) async {
    events[playerId] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Stream<AudioEvent> getEventStream(String playerId) => events[playerId]!.stream;

  @override
  Future<void> setSourceUrl(String playerId, String url,
      {bool? isLocal, String? mimeType}) async {
    sources[playerId] = url;
    requestedSources.add(url);
    mimeTypes.add(mimeType);
    if (failedSources > 0) {
      failedSources--;
      events[playerId]!.addError(StateError('media unavailable'));
      return;
    }
    await sourceGate?.call(url);
    events[playerId]?.add(
        const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true));
  }

  @override
  Future<void> setSourceBytes(String playerId, Uint8List bytes, {String? mimeType}) {
    throw StateError('Audio must stream by URL, never buffer the entire file');
  }

  @override
  Future<int?> getDuration(String playerId) async =>
      Uri.parse(sources[playerId]!).path.endsWith('first.mp3') ? 1598000 : 4009000;

  @override
  Future<int?> getCurrentPosition(String playerId) async => positions[playerId] ?? 0;

  @override
  Future<void> seek(String playerId, Duration position) async {
    positions[playerId] = position.inMilliseconds;
    seeks.add(position.inMilliseconds);
    events[playerId]!.add(AudioEvent(eventType: AudioEventType.seekComplete));
  }

  @override
  Future<void> resume(String playerId) async {
    resumedSources.add(sources[playerId]!);
  }

  @override
  Future<void> dispose(String playerId) async {
    await events.remove(playerId)?.close();
    sources.remove(playerId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

class _GlobalAudioPlatform extends GlobalAudioplayersPlatformInterface {
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

http.Response _media(http.Request request) => http.Response.bytes(
    List.filled(512, request.url.path.endsWith('first.mp3') ? 1 : 2), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('streaming audio shows a source error, retries and preserves query parameters', (tester) async {
    final previousPlatform = AudioplayersPlatformInterface.instance;
    final previousGlobal = GlobalAudioplayersPlatformInterface.instance;
    final platform = _AudioPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _GlobalAudioPlatform();
    addTearDown(() {
      AudioplayersPlatformInterface.instance = previousPlatform;
      GlobalAudioplayersPlatformInterface.instance = previousGlobal;
    });
    platform.failedSources = 1;
    await http.runWithClient(() async {
      try {
        await tester.pumpWidget(const MaterialApp(home: Scaffold(body: VoiceMessagePlayer(
          url: 'https://example.test/first.mp3?v=release', isMe: true, senderName: 'Sender'))));
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('הטעינה נכשלה — לחצו לניסיון חוזר'), findsOneWidget);
        expect(platform.resumedSources, isEmpty);
        await tester.tap(find.byIcon(Icons.refresh));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
        expect(platform.requestedSources, List.filled(2, 'https://example.test/first.mp3?v=release'));
        expect(find.text('first.mp3'), findsOneWidget);
        expect(find.text('0:00 / 26:38'), findsOneWidget);
        expect(platform.mimeTypes, ['audio/mpeg', 'audio/mpeg']);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    }, () => MockClient((request) async {
      throw StateError('Do not eagerly download audio through HTTP');
    }));
  });

  testWidgets('seek, precise jump, pause and remount preserve account progress', (tester) async {
    final previousPlatform = AudioplayersPlatformInterface.instance;
    final previousGlobal = GlobalAudioplayersPlatformInterface.instance;
    final platform = _AudioPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _GlobalAudioPlatform();
    addTearDown(() {
      AudioplayersPlatformInterface.instance = previousPlatform;
      GlobalAudioplayersPlatformInterface.instance = previousGlobal;
    });
    final saved = <String, Map<String, int>>{};
    final client = MockClient((request) async {
      if (!request.url.path.endsWith('/audio-progress')) return _media(request);
      final key = '${request.headers['authorization']}:${request.url.queryParameters['fileUrl']}';
      final current = saved.putIfAbsent(key, () => {'positionMs': 0, 'version': 0});
      if (request.method == 'PUT') {
        final body = jsonDecode(request.body);
        if (body['version'] != current['version']) return http.Response('{}', 409);
        current['positionMs'] = body['positionMs'];
        current['version'] = current['version']! + 1;
      }
      return http.Response(jsonEncode(current), 200);
    });
    Future<void> mount({String token = 'alice', String file = 'first'}) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: VoiceMessagePlayer(
        token: token, url: 'https://example.test/$file.mp3', isMe: true, senderName: 'Sender'))));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await http.runWithClient(() async {
      try {
        await mount();
        var slider = tester.widget<Slider>(find.byType(Slider));
        slider.onChanged!(90000); slider.onChangeEnd!(90000);
        await tester.pump(const Duration(milliseconds: 100));
        expect(find.text('1:30 / 26:38'), findsOneWidget);
        expect(platform.seeks.last, 90000);
        expect(saved['Bearer alice:/first.mp3']!['positionMs'], 90000);

        await tester.tap(find.text('1:30 / 26:38'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '99:99');
        await tester.tap(find.text('מעבר')); await tester.pump();
        expect(find.text('יש להזין זמן תקין'), findsOneWidget);
        await tester.enterText(find.byType(TextField), '12:30');
        await tester.tap(find.text('מעבר'));
        await tester.pumpAndSettle();
        expect(find.text('12:30 / 26:38'), findsOneWidget);
        expect(platform.seeks.last, 750000);

        await tester.tap(find.byIcon(Icons.play_arrow)); await tester.pump();
        platform.positions[platform.sources.keys.single] = 754000;
        await tester.tap(find.byIcon(Icons.pause)); await tester.pump();
        expect(saved['Bearer alice:/first.mp3']!['positionMs'], 754000);
        await tester.pumpWidget(const SizedBox.shrink()); await tester.pump();
        await mount();
        expect(find.text('12:34 / 26:38'), findsOneWidget);
        expect(platform.seeks.last, 754000);
        expect(platform.resumedSources.length, 1); // restore never autoplays

        await mount(file: 'second');
        expect(find.text('0:00 / 66:49'), findsOneWidget);
        await mount(token: 'bob');
        expect(find.text('0:00 / 26:38'), findsOneWidget);
        await mount();
        expect(find.text('12:34 / 26:38'), findsOneWidget);
        platform.events.values.last.add(const AudioEvent(eventType: AudioEventType.complete));
        await tester.pump();
        expect(saved['Bearer alice:/first.mp3']!['positionMs'], 0);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 2));
      }
    }, () => client);
  });

  testWidgets('a reused voice player plays the new file and shows its duration',
      (tester) async {
    final previousPlatform = AudioplayersPlatformInterface.instance;
    final previousGlobal = GlobalAudioplayersPlatformInterface.instance;
    final platform = _AudioPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _GlobalAudioPlatform();
    addTearDown(() {
      AudioplayersPlatformInterface.instance = previousPlatform;
      GlobalAudioplayersPlatformInterface.instance = previousGlobal;
    });

    Future<void> mount(String file) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: VoiceMessagePlayer(
          url: 'https://example.test/$file.mp3',
          fileName: 'שיעור $file.mp3',
          isMe: true,
          senderName: 'Sender',
        )),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }

    await http.runWithClient(() async { try {
      await mount('first');
      expect(find.text('שיעור first.mp3'), findsOneWidget);
      expect(find.text('0:00 / 26:38'), findsOneWidget);
      await mount('second');
      expect(find.text('שיעור second.mp3'), findsOneWidget);
      expect(find.text('שיעור first.mp3'), findsNothing);
      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(platform.resumedSources, ['https://example.test/second.mp3']);
      expect(find.text('0:00 / 66:49'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    } }, () => MockClient((request) async => _media(request)));
  });

  testWidgets('late preparation cannot replace a newer streamed recording', (tester) async {
    final previousPlatform = AudioplayersPlatformInterface.instance;
    final previousGlobal = GlobalAudioplayersPlatformInterface.instance;
    final platform = _AudioPlatform();
    AudioplayersPlatformInterface.instance = platform;
    GlobalAudioplayersPlatformInterface.instance = _GlobalAudioPlatform();
    addTearDown(() {
      AudioplayersPlatformInterface.instance = previousPlatform;
      GlobalAudioplayersPlatformInterface.instance = previousGlobal;
    });
    final slow = Completer<void>();
    platform.sourceGate = (url) => url.endsWith('first.mp3') ? slow.future : Future.value();
    await http.runWithClient(() async {
      Future<void> mount(String file) async {
        await tester.pumpWidget(MaterialApp(home: Scaffold(body: VoiceMessagePlayer(
          url: 'https://example.test/$file.mp3', isMe: true, senderName: 'Sender'))));
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 100));
      }
      try {
        await mount('first');
        await mount('second');
        expect(find.text('0:00 / 66:49'), findsOneWidget);
        slow.complete();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(find.byIcon(Icons.play_arrow)); await tester.pump();
        expect(platform.resumedSources, ['https://example.test/second.mp3']);
        expect(find.text('0:00 / 66:49'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 1));
      }
    }, () => MockClient((request) async {
      throw StateError('Do not eagerly download audio through HTTP');
    }));
  });
}
