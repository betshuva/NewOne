import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('com.betshuva.app/media');
const _maxCachedFrames = 80;
const _maxCachedBytes = 8 * 1024 * 1024;
const _maxConcurrentRequests = 2;
const _requestTimeout = Duration(seconds: 30);
final _frames = <String, Uint8List>{};
final _pending = <String, Future<Uint8List?>>{};
final _waiting = Queue<_ThumbnailRequest>();
int _cachedBytes = 0;
int _active = 0;

Future<Uint8List?> loadVideoThumbnail(String url) {
  if (kIsWeb ||
      defaultTargetPlatform != TargetPlatform.android ||
      !_validUrl(url)) {
    return Future.value(null);
  }
  final pending = _pending[url];
  if (pending != null) return pending;
  final cached = _frames.remove(url);
  if (cached != null) {
    _frames[url] = cached;
    return Future.value(cached);
  }

  final request = _ThumbnailRequest(url);
  final result = request.result.future;
  _pending[url] = result;
  _waiting.add(request);
  _drain();
  return result;
}

bool _validUrl(String url) {
  try {
    final uri = Uri.tryParse(url);
    return uri != null &&
        const {'http', 'https'}.contains(uri.scheme) &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || (uri.port > 0 && uri.port <= 65535));
  } on FormatException {
    return false;
  }
}

void _drain() {
  while (_active < _maxConcurrentRequests && _waiting.isNotEmpty) {
    _active++;
    _capture(_waiting.removeFirst());
  }
}

Future<void> _capture(_ThumbnailRequest request) async {
  Uint8List? bytes;
  try {
    bytes = await _channel.invokeMethod<Uint8List>(
        'videoThumbnail', {'url': request.url}).timeout(_requestTimeout);
    if (bytes != null && bytes.isEmpty) bytes = null;
    if (bytes != null && bytes.lengthInBytes <= _maxCachedBytes) {
      _frames[request.url] = bytes;
      _cachedBytes += bytes.lengthInBytes;
      while (
          _frames.length > _maxCachedFrames || _cachedBytes > _maxCachedBytes) {
        _cachedBytes -= _frames.remove(_frames.keys.first)!.lengthInBytes;
      }
    }
  } catch (_) {
    bytes = null;
  } finally {
    // Failed requests leave no cache entry; a later mount can try again.
    _pending.remove(request.url);
    request.result.complete(bytes);
    _active--;
    _drain();
  }
}

class _ThumbnailRequest {
  _ThumbnailRequest(this.url);
  final String url;
  final result = Completer<Uint8List?>();
}
