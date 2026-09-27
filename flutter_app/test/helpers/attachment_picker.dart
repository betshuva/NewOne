import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart' show XFile;

class MemoryPickedFile extends PlatformFile {
  MemoryPickedFile(String name, Uint8List data)
      : super(name: name, size: data.length, bytes: data);

  @override
  XFile get xFile => _MemoryFile(name, bytes!);
}

class _MemoryFile extends XFile {
  _MemoryFile(super.path, this.data);
  final Uint8List data;
  @override
  Future<Uint8List> readAsBytes() async => data;
  @override
  Future<int> length() async => data.length;
}

class AttachmentPicker extends FilePicker {
  AttachmentPicker(this.files);
  final List<PlatformFile> files;
  int calls = 0;
  List<String>? extensions;
  bool multiple = false;

  @override
  Future<FilePickerResult?> pickFiles(
      {String? dialogTitle,
      String? initialDirectory,
      FileType type = FileType.any,
      List<String>? allowedExtensions,
      Function(FilePickerStatus)? onFileLoading,
      bool allowCompression = true,
      int compressionQuality = 30,
      bool allowMultiple = false,
      bool withData = false,
      bool withReadStream = false,
      bool lockParentWindow = false,
      bool readSequential = false}) async {
    calls++;
    extensions = allowedExtensions;
    multiple = allowMultiple;
    return files.isEmpty ? null : FilePickerResult(files);
  }
}
