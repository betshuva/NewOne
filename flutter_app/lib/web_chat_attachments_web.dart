// Browser Blob slices keep transfer and hashing memory bounded for large files.
// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart' show XFile;
import 'chat_attachment_files.dart';
import 'attachment_read_error.dart';

final _selectedFiles = <String, WebChatAttachmentFile>{};

@JS('crypto.subtle')
external _SubtleCrypto? get _subtleCrypto;

extension type _SubtleCrypto(JSObject _) implements JSObject {
  external JSPromise<JSArrayBuffer> digest(
      JSString algorithm, JSUint8Array bytes);
}

@JS()
extension type _StreamingBlob(JSObject _) implements JSObject {
  external JSObject stream();
}

@JS('Response')
extension type _BlobResponse._(JSObject _) implements JSObject {
  external factory _BlobResponse(JSObject body);
  external JSPromise<JSObject> blob();
}

@JS()
extension type _ClipboardFileItem(JSObject _) implements JSObject {
  external JSPromise<JSObject?> getAsFileSystemHandle();
}

@JS()
extension type _ClipboardFileHandle(JSObject _) implements JSObject {
  external String get kind;
  external JSPromise<JSObject> getFile();
}

// Request the handle synchronously during the user's paste event. This grants
// access only to the selected file; no directory or write permission is sought.
Future<html.File?> Function() clipboardFileFromItem(
    html.DataTransferItem item, {ClipboardReadDiagnostics? diagnostics}) {
  try {
    final object = item as JSObject;
    if (!object.hasProperty('getAsFileSystemHandle'.toJS).toDart) {
      diagnostics?.record('handle', 'unsupported');
      return () async => null;
    }
    final handle = _ClipboardFileItem(object)
        .getAsFileSystemHandle()
        .toDart
        .catchError((Object error) {
          diagnostics?.record('handle', _clipboardErrorCode(error));
          return null;
        });
    return () async {
      try {
        final value = await handle;
        if (value == null) {
          diagnostics?.record('handle', 'unavailable');
          return null;
        }
        diagnostics?.record('handle', 'ok');
        final fileHandle = _ClipboardFileHandle(value);
        if (fileHandle.kind != 'file') {
          diagnostics?.record('fresh_file', 'not_file');
          return null;
        }
        // Fetch fresh file metadata only when the initial reference fails.
        final file = await fileHandle.getFile().toDart as html.File;
        diagnostics?.record('fresh_file', 'ok');
        return file;
      } catch (error) {
        diagnostics?.record('fresh_file', _clipboardErrorCode(error));
        return null;
      }
    };
  } catch (error) {
    diagnostics?.record('handle', _clipboardErrorCode(error));
    return () async => null;
  }
}

String _clipboardErrorCode(Object error) {
  if (error is html.DomException) return _knownClipboardCode(error.name);
  if (error is StateError) return 'StateError';
  if (error is TypeError) return 'TypeError';
  // Promise rejections can be JS errors rather than dart:html exceptions.
  // Extract only a known code; never include their potentially private message.
  final match = RegExp(r'\b(NotReadableError|NotAllowedError|SecurityError|NotFoundError|AbortError|InvalidStateError|NotSupportedError|TypeError|RangeError)\b')
      .firstMatch(error.toString());
  return match?.group(1) ?? 'unknown';
}

String _knownClipboardCode(String name) => const {
  'NotReadableError', 'NotAllowedError', 'SecurityError', 'NotFoundError',
  'AbortError', 'InvalidStateError', 'NotSupportedError', 'TypeError', 'RangeError',
}.contains(name) ? name : 'unknown';

class WebChatAttachmentFile extends PlatformFile {
  final html.File source;
  final String objectUrl;
  Future<html.File?>? _snapshot;
  Object? _snapshotError;
  ClipboardReadDiagnostics? _diagnostics;

  WebChatAttachmentFile(this.source)
      : objectUrl = html.Url.createObjectUrlFromBlob(source),
        super(name: source.name, size: source.size) {
    _selectedFiles[objectUrl] = this;
  }

  factory WebChatAttachmentFile.clipboard(html.File source,
      {Future<html.File?> Function()? fallback,
      ClipboardReadDiagnostics? diagnostics}) {
    final attachment = WebChatAttachmentFile(source);
    attachment._diagnostics = diagnostics ?? ClipboardReadDiagnostics();
    // Start reading while the paste event still owns its file references.
    // A stream-backed browser Blob owns the bytes independently of the source;
    // unlike an ArrayBuffer, it does not allocate the whole file in Dart memory.
    // Handle rejection immediately, even while confirmation/other files wait.
    attachment._snapshot = _copyClipboardWithFallback(source, fallback, attachment._diagnostics!)
        .then<html.File?>((file) => file, onError: (Object error) {
      attachment._snapshotError = error;
      return null;
    });
    return attachment;
  }

  Future<html.File> get uploadSource async {
    if (_snapshot == null) return source;
    final copy = await _snapshot;
    if (copy == null) {
      throw AttachmentReadException(name, _snapshotError?.toString(), _diagnostics?.toJson());
    }
    return copy;
  }

  static Future<html.File> _copyClipboardWithFallback(
      html.File source, Future<html.File?> Function()? fallback,
      ClipboardReadDiagnostics diagnostics) async {
    try {
      return await _copyClipboardFile(source, diagnostics, 'snapshot');
    } catch (error) {
      diagnostics.record('snapshot', _clipboardErrorCode(error));
      final fresh = await fallback?.call();
      // Never substitute a different file for the one the user pasted.
      if (fresh == null || fresh.name != source.name) {
        diagnostics.record('fallback', fresh == null ? 'unavailable' : 'name_mismatch');
        rethrow;
      }
      try {
        return await _copyClipboardFile(fresh, diagnostics, 'fallback');
      } catch (error) {
        diagnostics.record('fallback', _clipboardErrorCode(error));
        rethrow;
      }
    }
  }

  static Future<html.File> _copyClipboardFile(html.File file,
      ClipboardReadDiagnostics diagnostics, String stage) async {
    diagnostics.record(stage, 'started');
    final stream = _StreamingBlob(file as JSObject).stream();
    final blob = await _BlobResponse(stream).blob().toDart;
    diagnostics.record(stage, 'ok');
    return html.File([blob as html.Blob], file.name,
        {'type': file.type, 'lastModified': file.lastModified});
  }

  @override
  XFile get xFile => XFile(objectUrl,
      name: name,
      mimeType: source.type.isEmpty ? null : source.type,
      length: size);
}

Future<List<PlatformFile>?> pickWebChatAttachments() async {
  final input = html.FileUploadInputElement()
    ..multiple = true
    ..accept = chatAttachmentExtensions.map((ext) => '.$ext').join(',');
  final done = Completer<List<PlatformFile>?>();
  final change = input.onChange.listen((_) {
    if (!done.isCompleted) {
      done.complete(input.files?.map(WebChatAttachmentFile.new).toList());
    }
  });
  final cancel = input.on['cancel'].listen((_) {
    if (!done.isCompleted) done.complete(null);
  });
  input.click();
  try {
    return await done.future;
  } finally {
    await change.cancel();
    await cancel.cancel();
    input.remove();
  }
}

void releaseWebChatAttachments(List<PlatformFile>? files) {
  for (final file in files ?? <PlatformFile>[]) {
    if (file is WebChatAttachmentFile) {
      _selectedFiles.remove(file.objectUrl);
      html.Url.revokeObjectUrl(file.objectUrl);
    }
  }
}

Future<({int statusCode, String body})?> uploadPickedWebAttachment({
  required dynamic file,
  required String url,
  required String token,
  required Map<String, String> fields,
}) async {
  html.Blob? source;
  final attachment = file is WebChatAttachmentFile
      ? file : file is XFile ? _selectedFiles[file.path] : null;
  String name;
  if (file is WebChatAttachmentFile) {
    source = await file.uploadSource;
    name = file.name;
  } else if (file is XFile) {
    name = file.name;
    source = await _selectedFiles[file.path]?.uploadSource;
    if (source == null && file.path.startsWith('blob:')) {
      final loaded =
          await html.HttpRequest.request(file.path, responseType: 'blob');
      source = loaded.response as html.Blob;
    }
    source ??= html.Blob([await file.readAsBytes()],
        file.mimeType ?? 'application/octet-stream');
  } else if (file is PlatformFile && file.bytes != null) {
    name = file.name;
    source = html.Blob([file.bytes!]);
  } else {
    return null;
  }
  final blob = source;
  final base = url.substring(0, url.length - '/upload'.length);
  final sortedFields = Map.fromEntries(
      fields.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  Future<List<int>> readPart(html.Blob part) async {
    final reader = html.FileReader()..readAsArrayBuffer(part);
    await reader.onLoadEnd.first;
    if (reader.error != null) {
      attachment?._diagnostics?.record('chunk_read', _knownClipboardCode(reader.error!.name));
      throw AttachmentReadException(name, reader.error!.name, attachment?._diagnostics?.toJson());
    }
    final value = reader.result;
    return value is ByteBuffer ? value.asUint8List() : value as List<int>;
  }

  // Hash the complete file in bounded chunks so a changed middle cannot resume an older file. Never store an access token.
  String owner = token;
  try {
    owner =
        '${jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))))['id']}';
  } catch (_) {}
  final identityFields = Map<String, String>.from(sortedFields)
    ..remove('clientUploadId');
  Stream<List<int>> identityBytes() async* {
    yield utf8
        .encode(jsonEncode([base, owner, name, blob.size, identityFields]));
    const chunkBytes = 4 * 1024 * 1024;
    for (var start = 0; start < blob.size; start += chunkBytes) {
      final part = await readPart(
          blob.slice(start, math.min(start + chunkBytes, blob.size)));
      final subtle = _subtleCrypto;
      if (subtle == null) {
        yield sha256.convert(part).bytes;
      } else {
        final data = part is Uint8List ? part : Uint8List.fromList(part);
        final digest = await subtle.digest('SHA-256'.toJS, data.toJS).toDart;
        yield digest.toDart.asUint8List();
      }
    }
  }

  final fingerprint = (await sha256.bind(identityBytes()).first).toString();
  final storageKey = 'upload-session-v1-$fingerprint';
  String? id;
  try {
    id = html.window.localStorage[storageKey];
  } catch (_) {}
  id ??= _uploadUuid();
  try {
    html.window.localStorage[storageKey] = id;
  } catch (_) {}
  final metadata = {
    'id': id,
    'name': name,
    'size': blob.size,
    'mime': blob.type.isEmpty ? 'application/octet-stream' : blob.type,
    'fields': sortedFields
  };
  Map<String, dynamic> decode(({int statusCode, String body}) response) =>
      jsonDecode(response.body) as Map<String, dynamic>;
  var response = await _retryRequest('GET', '$base/upload-sessions/$id', token);
  if (response.statusCode == 404) {
    response = await _retryRequest('POST', '$base/upload-sessions', token,
        data: jsonEncode(metadata), contentType: 'application/json');
  }
  if (response.statusCode == 410 || response.statusCode == 409) {
    id = _uploadUuid();
    metadata['id'] = id;
    try {
      html.window.localStorage[storageKey] = id;
    } catch (_) {}
    response = await _retryRequest('POST', '$base/upload-sessions', token,
        data: jsonEncode(metadata), contentType: 'application/json');
  }
  if (response.statusCode != 200) return response;
  var state = decode(response);
  final sessionUrl = '$base/upload-sessions/$id';
  var offset = (state['offset'] as num).toInt();
  while (offset < blob.size) {
    final end =
        math.min(offset + (state['chunkBytes'] as num).toInt(), blob.size);
    try {
      response = await _sendUploadRequest('PUT', sessionUrl, token,
          data: blob.slice(offset, end),
          contentType: 'application/octet-stream',
          offset: offset);
      if (response.statusCode == 200) {
        offset = (decode(response)['offset'] as num).toInt();
        continue;
      }
      if (![408, 409, 429, 500, 502, 503, 504].contains(response.statusCode)) {
        return response;
      }
    } catch (_) {
      // The server may have committed this chunk even though its response was lost.
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    response = await _retryRequest('GET', sessionUrl, token);
    if (response.statusCode != 200) return response;
    state = decode(response);
    offset = (state['offset'] as num).toInt();
  }
  while (true) {
    if (state['result'] is Map) {
      final result = state['result'] as Map;
      try {
        html.window.localStorage.remove(storageKey);
      } catch (_) {}
      return (
        statusCode: (result['statusCode'] as num).toInt(),
        body: jsonEncode(result['data'])
      );
    }
    if (state['processing'] != true) {
      response = await _retryRequest('POST', url, token,
          data: jsonEncode({'uploadSessionId': id}),
          contentType: 'application/json');
      if (response.statusCode != 202) {
        try {
          html.window.localStorage.remove(storageKey);
        } catch (_) {}
        return response;
      }
    }
    await Future<void>.delayed(const Duration(seconds: 2));
    response = await _retryRequest('GET', sessionUrl, token);
    if (response.statusCode != 200) return response;
    state = decode(response);
  }
}

String _uploadUuid() {
  final bytes = Uint8List(16);
  html.window.crypto!.getRandomValues(bytes);
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final value = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${value.substring(0, 8)}-${value.substring(8, 12)}-${value.substring(12, 16)}-${value.substring(16, 20)}-${value.substring(20)}';
}

Future<({int statusCode, String body})> _retryRequest(
    String method, String url, String token,
    {Object? data, String? contentType}) async {
  for (var attempt = 0;; attempt++) {
    try {
      final result = await _sendUploadRequest(method, url, token,
          data: data, contentType: contentType);
      if (![408, 429, 500, 502, 503, 504].contains(result.statusCode)) {
        return result;
      }
    } catch (_) {}
    if (attempt >= 10 && html.window.navigator.onLine != false) {
      throw StateError(
          'החיבור נותק. ההתקדמות נשמרה; אפשר לבחור שוב את אותו הקובץ כדי להמשיך');
    }
    await Future<void>.delayed(
        Duration(seconds: math.min(30, 1 << math.min(attempt, 5))));
  }
}

Future<({int statusCode, String body})> _sendUploadRequest(
    String method, String url, String token,
    {Object? data, String? contentType, int? offset}) async {
  final request = html.HttpRequest();
  final done = Completer<({int statusCode, String body})>();
  request.open(method, url);
  request.timeout = 300000;
  request.setRequestHeader('Authorization', 'Bearer $token');
  if (contentType != null) {
    request.setRequestHeader('Content-Type', contentType);
  }
  if (offset != null) request.setRequestHeader('Upload-Offset', '$offset');
  final load = request.onLoad.listen((_) {
    if (!done.isCompleted) {
      done.complete(
          (statusCode: request.status ?? 0, body: request.responseText ?? ''));
    }
  });
  void failed(html.ProgressEvent _) {
    if (!done.isCompleted) done.completeError(StateError('החיבור לשרת נקטע'));
  }

  final error = request.onError.listen(failed);
  final abort = request.onAbort.listen(failed);
  final timeout = request.onTimeout.listen(failed);
  request.send(data);
  try {
    return await done.future;
  } finally {
    await load.cancel();
    await error.cancel();
    await abort.cancel();
    await timeout.cancel();
  }
}
