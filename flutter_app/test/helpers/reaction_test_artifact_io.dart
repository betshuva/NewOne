import 'dart:io';
import 'dart:typed_data';

Future<void> saveReactionTestArtifact(Uint8List bytes) async {
  const path =
      '/home/yaniv/.local/state/newone-releases/reaction-corner-20261007/reaction-corner.png';
  await File(path).writeAsBytes(bytes, flush: true);
  await Process.run('chmod', ['600', path]);
}
