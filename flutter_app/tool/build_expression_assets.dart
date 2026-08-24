import 'dart:io';

import 'package:image/image.dart' as img;

const _columns = 5;
const _rows = 4;
const _count = 20;

void main() {
  final root = Directory('assets/expressions/items-v2')
    ..createSync(recursive: true);
  _clear(root);
  _splitSheet(
      sourcePath: 'assets/expressions/source/emotions-sheet-v2.png',
      output: Directory('${root.path}/smiles')..createSync(),
      prefix: 'smile');
  _splitSheet(
      sourcePath: 'assets/expressions/source/holidays-sheet-v2.png',
      output: Directory('${root.path}/stickers')..createSync(),
      prefix: 'sticker');
  _splitSheet(
      sourcePath: 'assets/expressions/source/family-sheet-v2.png',
      output: Directory('${root.path}/family')..createSync(),
      prefix: 'family');
  final animatedTiles = _splitSheet(
      sourcePath: 'assets/expressions/source/animated-sheet-v2.png',
      output: Directory('${root.path}/animated-preview')..createSync(),
      prefix: 'animated');
  final gifOutput = Directory('${root.path}/gifs')..createSync();
  for (var index = 0; index < animatedTiles.length; index++) {
    final name = (index + 1).toString().padLeft(2, '0');
    _writeAnimatedGif(animatedTiles[index],
        File('${gifOutput.path}/animated-$name.gif'), index);
  }
  stdout.writeln(
      'Created $_count smiles, $_count stickers, $_count family expressions and $_count GIFs.');
}

void _clear(Directory directory) {
  if (!directory.existsSync()) return;
  for (final entity in directory.listSync()) {
    entity.deleteSync(recursive: true);
  }
}

List<img.Image> _splitSheet(
    {required String sourcePath,
    required Directory output,
    required String prefix}) {
  final source = img.decodePng(File(sourcePath).readAsBytesSync());
  if (source == null) throw StateError('Could not decode $sourcePath');
  final cellWidth = source.width ~/ _columns;
  final cellHeight = source.height ~/ _rows;
  final tiles = <img.Image>[];
  for (var row = 0; row < _rows; row++) {
    for (var column = 0; column < _columns; column++) {
      final index = row * _columns + column + 1;
      final crop = img.copyCrop(source,
          x: column * cellWidth,
          y: row * cellHeight,
          width: column == _columns - 1
              ? source.width - column * cellWidth
              : cellWidth,
          height:
              row == _rows - 1 ? source.height - row * cellHeight : cellHeight);
      final tile = img.copyResize(crop, width: 320, height: 320);
      final name = index.toString().padLeft(2, '0');
      File('${output.path}/$prefix-$name.png')
          .writeAsBytesSync(img.encodePng(tile));
      tiles.add(tile);
    }
  }
  return tiles;
}

void _writeAnimatedGif(img.Image source, File target, int index) {
  final animation = img.Image.from(source)..frameDuration = 130;
  final pattern = index % 4;
  for (var frameIndex = 1; frameIndex < 8; frameIndex++) {
    final phase = frameIndex <= 4 ? frameIndex : 8 - frameIndex;
    img.Image frame;
    if (pattern == 0) {
      frame = img.adjustColor(img.Image.from(source),
          brightness: 1 + phase * 0.035, saturation: 1 + phase * 0.03);
    } else if (pattern == 1) {
      final angle = (frameIndex.isEven ? 1 : -1) * phase * 1.5;
      frame = img.copyResize(img.copyRotate(source, angle: angle),
          width: source.width, height: source.height);
    } else if (pattern == 2) {
      final size = source.width - phase * 7;
      final smaller = img.copyResize(source, width: size, height: size);
      frame =
          img.Image(width: source.width, height: source.height, numChannels: 4);
      img.compositeImage(frame, smaller,
          dstX: (source.width - size) ~/ 2, dstY: (source.height - size) ~/ 2);
    } else {
      frame = img.adjustColor(img.Image.from(source),
          brightness: 1 + phase * 0.025, contrast: 1 + phase * 0.035);
    }
    frame.frameDuration = 130;
    animation.addFrame(frame);
  }
  target.writeAsBytesSync(img.encodeGif(animation));
}
