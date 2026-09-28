// Browser regression target. Serve two long WAV files with throttled HTTP range
// responses at /slow-first.wav and /slow-second.wav. Verify that playback begins
// before the full file arrives, then switch sources and restore saved progress.
import 'dart:convert';
import 'package:betshuva/main.dart' show VoiceMessagePlayer;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final progress = <String, Map<String, int>>{
    '/slow-first.wav': {'positionMs': 2000, 'version': 1},
    '/slow-second.wav': {'positionMs': 0, 'version': 0},
  };
  http.runWithClient(() {
    WidgetsFlutterBinding.ensureInitialized();
    runApp(const MaterialApp(home: _StreamingRepro()));
  }, () => MockClient((request) async {
    if (!request.url.path.endsWith('/audio-progress')) {
      throw StateError('Audio bytes must be fetched by the browser player');
    }
    final saved = progress[request.url.queryParameters['fileUrl']]!;
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body);
      saved['positionMs'] = body['positionMs'];
      saved['version'] = saved['version']! + 1;
    }
    return http.Response(jsonEncode(saved), 200);
  }));
}

class _StreamingRepro extends StatefulWidget {
  const _StreamingRepro();
  @override
  State<_StreamingRepro> createState() => _StreamingReproState();
}

class _StreamingReproState extends State<_StreamingRepro> {
  bool first = true;
  @override
  Widget build(BuildContext context) => Scaffold(body: Center(child: Directionality(
    textDirection: TextDirection.rtl,
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      VoiceMessagePlayer(
        url: Uri.base.resolve(first ? '/slow-first.wav' : '/slow-second.wav').toString(),
        fileName: first ? 'שיעור ראשון.wav' : 'שיעור שני.wav',
        token: 'streaming-fixture', isMe: true, senderName: 'Test',
      ),
      TextButton(onPressed: () => setState(() => first = false), child: const Text('הקלטה שנייה')),
      TextButton(onPressed: () => setState(() => first = true), child: const Text('הקלטה ראשונה')),
    ]),
  )));
}
