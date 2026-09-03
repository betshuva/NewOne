import 'dart:typed_data';

Future<Uint8List> captureCurrentAppScreen() =>
    Future.error(UnsupportedError('Screen capture is available on web only'));
