import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ListingImageAttachment {
  final String url;
  final String? expectedOldUrl;
  final bool video;

  const ListingImageAttachment(
      {required this.url, this.expectedOldUrl, this.video = false});
}

class ListingImageScanResult {
  final String status;
  final String? reason;

  const ListingImageScanResult({required this.status, this.reason});
}

/// Polls an uploaded listing image independently of its form's lifetime. The
/// server remains responsible for ownership and the final moderation decision.
Future<ListingImageScanResult> waitForListingImageScan({
  required String api,
  required String token,
  required String url,
  bool video = false,
  http.Client? client,
  Duration pollInterval = const Duration(seconds: 15),
  Duration timeout = const Duration(minutes: 30),
}) async {
  final elapsed = Stopwatch()..start();
  final post = client?.post ?? http.post;
  final endpoint = Uri.parse('$api/listing-image-status');
  final headers = {
    'Authorization': 'Bearer $token',
    'Content-Type': 'application/json',
  };
  final body = jsonEncode({
    video ? 'video_urls' : 'image_urls': [url]
  });
  while (elapsed.elapsed < timeout) {
    final remaining = timeout - elapsed.elapsed;
    final requestTimeout = remaining < const Duration(seconds: 30)
        ? remaining
        : const Duration(seconds: 30);
    try {
      final response = await post(endpoint, headers: headers, body: body)
          .timeout(requestTimeout);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final images = data is Map ? data[video ? 'videos' : 'images'] : null;
        if (images is List) {
          for (final image in images) {
            if (image is! Map || image['url'] != url) continue;
            final status = image['status'];
            if (const {'approved', 'rejected', 'unavailable'}
                .contains(status)) {
              return ListingImageScanResult(
                status: status as String,
                reason: image['reason'] is String
                    ? image['reason'] as String
                    : null,
              );
            }
          }
        }
      }
    } catch (_) {
      // Temporary transport/server failures do not discard an image that is
      // still being scanned. The same URL is retried within the time limit.
    }
    final remainingAfterRequest = timeout - elapsed.elapsed;
    if (remainingAfterRequest <= Duration.zero) break;
    final interval =
        pollInterval < Duration.zero ? Duration.zero : pollInterval;
    await Future<void>.delayed(
        interval < remainingAfterRequest ? interval : remainingAfterRequest);
  }
  throw TimeoutException(
      '${video ? 'בדיקת הסרטון' : 'בדיקת התמונה'} לא הסתיימה בזמן. '
      'אפשר לפתוח את המודעה שוב ולבדוק את מצב התמונות',
      timeout);
}

class ListingBackgroundImageJob {
  ListingBackgroundImageJob._({
    required this.id,
    required String api,
    required String token,
    required this.listingId,
    required this.title,
    required this.total,
    required bool includesVideo,
  })  : _api = api,
        _token = token,
        _includesVideo = includesVideo,
        _results = List<ListingImageAttachment?>.filled(total, null);

  final int id;
  final String _api, _token;
  final String listingId, title;
  final int total;
  final bool _includesVideo;
  final List<ListingImageAttachment?> _results;
  final _completion = Completer<void>();
  int _completed = 0, _attachedRevision = 0;
  bool _waiting = true, _linking = false, _attached = false;
  String? _error;
  List<String>? _imageUrls;
  String? _videoUrl;
  bool _hasVideoResult = false;

  int get completed => _completed;
  int get approved => _results.whereType<ListingImageAttachment>().length;
  int get skipped => completed - approved;
  int get attached => _attached ? approved : 0;
  bool get isActive => _waiting || _linking;
  bool get isFinished => !isActive && _error == null;
  bool get canRetry => !isActive && _error != null;
  String? get error => _error;
  List<String>? get imageUrls => _imageUrls;
  String? get videoUrl => _videoUrl;
  bool get hasVideoResult => _hasVideoResult;
  bool get includesVideo =>
      _includesVideo || _results.any((result) => result?.video == true);
  int get approvedImages => _results
      .whereType<ListingImageAttachment>()
      .where((result) => !result.video)
      .length;
  bool get approvedVideo => _results.any((result) => result?.video == true);
  int get attachedRevision => _attachedRevision;

  /// Completes after the first attachment attempt, including an attempt that
  /// needs a retry. Upload futures and their accepted URLs remain owned here.
  Future<void> get completion => _completion.future;
}

final listingBackgroundImages = ListingBackgroundImages();

/// Retains accepted uploads after their listing form closes. This queue covers
/// navigation within the running app; it is not an operating-system service.
class ListingBackgroundImages extends ChangeNotifier {
  ListingBackgroundImages({http.Client? client}) : _client = client;

  final http.Client? _client;
  final _jobs = <ListingBackgroundImageJob>[];
  int _nextId = 0, _revision = 0;
  bool _disposed = false;

  int get revision => _revision;

  List<ListingBackgroundImageJob> forToken(String token) =>
      List.unmodifiable(_jobs.where((job) => job._token == token));

  void _notify() {
    if (!_disposed && hasListeners) notifyListeners();
  }

  void start({
    required String api,
    required String token,
    required String listingId,
    required String title,
    required List<Future<ListingImageAttachment?>> uploads,
    bool includesVideo = false,
  }) {
    if (uploads.isEmpty) return;
    final job = ListingBackgroundImageJob._(
      id: ++_nextId,
      api: api,
      token: token,
      listingId: listingId,
      title: title,
      total: uploads.length,
      includesVideo: includesVideo,
    );
    _jobs.add(job);
    // Attach handlers immediately so individual upload failures never escape
    // the task. The caller may release every reference to the form afterwards.
    unawaited(_run(job, List.of(uploads)));
    _notify();
  }

  Future<void> _run(ListingBackgroundImageJob job,
      List<Future<ListingImageAttachment?>> uploads) async {
    try {
      await Future.wait([
        for (var index = 0; index < uploads.length; index++)
          _collect(job, index, uploads[index]),
      ]);
      job._waiting = false;
      if (job.approved > 0) {
        await _attach(job);
      } else {
        _notify();
      }
    } finally {
      if (!job._completion.isCompleted) job._completion.complete();
    }
  }

  Future<void> _collect(ListingBackgroundImageJob job, int index,
      Future<ListingImageAttachment?> upload) async {
    try {
      final result = await upload;
      if (result != null && result.url.trim().isNotEmpty) {
        job._results[index] = result;
      }
    } catch (_) {
      // A failed or unapproved upload does not become a public listing image.
    } finally {
      job._completed++;
      _notify();
    }
  }

  Future<void> _attach(ListingBackgroundImageJob job) async {
    if (job._linking || job._attached) return;
    job._linking = true;
    job._error = null;
    _notify();
    try {
      final additions = <String>{};
      final replacements = <String, String>{};
      ListingImageAttachment? videoResult;
      for (final result in job._results.whereType<ListingImageAttachment>()) {
        if (result.video) {
          videoResult = result;
          continue;
        }
        final old = result.expectedOldUrl;
        if (old != null && old.isNotEmpty) {
          replacements[old] = result.url;
        } else {
          additions.add(result.url);
        }
      }
      final post = _client?.post ?? http.post;
      final response = await post(
        Uri.parse('${job._api}/listings/'
            '${Uri.encodeComponent(job.listingId)}/images'),
        headers: {
          'Authorization': 'Bearer ${job._token}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'image_urls': additions.toList(),
          'replacements': [
            for (final entry in replacements.entries)
              {'expected_old_url': entry.key, 'url': entry.value},
          ],
          if (videoResult != null) ...{
            'video_url': videoResult.url,
            'expected_old_video_url': videoResult.expectedOldUrl,
          },
        }),
      ).timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final media = job.includesVideo ? 'המדיה' : 'התמונות';
        job._error = 'שמירת $media במודעה נכשלה. אפשר לנסות שוב';
        try {
          final data = jsonDecode(response.body);
          final reason = data is Map ? data['error'] : null;
          if (reason is String && reason.trim().isNotEmpty) {
            job._error = 'שמירת $media במודעה נכשלה: ${reason.trim()}';
          }
        } catch (_) {/* A non-JSON error still leaves the URLs for retry. */}
        return;
      }
      try {
        final data = jsonDecode(response.body);
        final images = data is Map ? data['images'] : null;
        if (images is List && images.every((image) => image is String)) {
          job._imageUrls = List<String>.unmodifiable(images.cast<String>());
        }
        if (data is Map &&
            data.containsKey('video_url') &&
            (data['video_url'] == null || data['video_url'] is String)) {
          job._hasVideoResult = true;
          job._videoUrl = data['video_url'] as String?;
        }
      } catch (_) {/* Older servers may return only an attachment receipt. */}
      job._attached = true;
      job._attachedRevision = ++_revision;
    } catch (_) {
      // Keep the uploaded URLs. A retry only repeats this idempotent link
      // request, never uploads the user's files again.
      job._error = 'שמירת ${job.includesVideo ? 'המדיה' : 'התמונות'} '
          'במודעה נכשלה. אפשר לנסות שוב';
    } finally {
      job._linking = false;
      _notify();
    }
  }

  Future<void> retry(ListingBackgroundImageJob job) async {
    if (!_jobs.contains(job) || !job.canRetry) return;
    await _attach(job);
  }

  void dismiss(ListingBackgroundImageJob job) {
    if (job.isActive || !_jobs.remove(job)) return;
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ListingBackgroundImageStatus extends StatelessWidget {
  final String token;
  final ListingBackgroundImages? manager;

  const ListingBackgroundImageStatus({
    super.key,
    required this.token,
    this.manager,
  });

  @override
  Widget build(BuildContext context) {
    final queue = manager ?? listingBackgroundImages;
    return AnimatedBuilder(
      animation: queue,
      builder: (context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final job in queue.forToken(token))
            _ListingImageJobStatus(job: job, manager: queue),
        ],
      ),
    );
  }
}

class _ListingImageJobStatus extends StatelessWidget {
  final ListingBackgroundImageJob job;
  final ListingBackgroundImages manager;

  const _ListingImageJobStatus({required this.job, required this.manager});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skippedMessage =
        '${job.skipped} ${job.includesVideo ? 'קבצים' : 'תמונות'} לא צורפו — '
        'לא אושרו, עדיין ממתינות לסריקה או נכשלו בהעלאה';
    final String message;
    if (job.error != null) {
      message = job.error!;
    } else if (job.completed < job.total) {
      message = '${job.includesVideo ? 'המדיה נטענת' : 'התמונות נטענות'} '
          'ברקע: ${job.completed} מתוך ${job.total}';
    } else if (job.isActive) {
      message = 'מצרף ${job.approved} '
          '${job.includesVideo ? 'קובצי מדיה' : 'תמונות'} למודעה';
    } else if (job.attached > 0) {
      message = job.approvedVideo
          ? job.approvedImages > 0
              ? '${job.approvedImages} תמונות וסרטון צורפו למודעה'
              : 'הסרטון צורף למודעה'
          : '${job.attached} תמונות צורפו למודעה';
    } else {
      message = skippedMessage;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Material(
        color: job.error != null
            ? theme.colorScheme.errorContainer
            : job.skipped > 0
                ? Colors.orange.shade50
                : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Icon(
                    job.error != null
                        ? Icons.error_outline
                        : job.skipped > 0
                            ? Icons.warning_amber_rounded
                            : job.isFinished
                                ? Icons.check_circle_outline
                                : Icons.cloud_upload_outlined,
                    color: job.skipped > 0 && job.error == null
                        ? Colors.orange.shade800
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(job.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  if (!job.isActive)
                    IconButton(
                      tooltip: job.includesVideo
                          ? 'סגירת עדכון המדיה'
                          : 'סגירת עדכון התמונות',
                      onPressed: () => manager.dismiss(job),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                ]),
                Semantics(liveRegion: true, child: Text(message)),
                if (job.skipped > 0 && message != skippedMessage)
                  Text(skippedMessage, style: theme.textTheme.bodySmall),
                if (job.isActive) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: job.completed < job.total
                        ? job.completed / job.total
                        : null,
                  ),
                ],
                if (job.canRetry)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => unawaited(manager.retry(job)),
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('נסה לצרף שוב'),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
