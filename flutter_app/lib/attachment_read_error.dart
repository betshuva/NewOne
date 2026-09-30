/// A local source could not be read; this is not an upload/server failure.
class AttachmentReadException implements Exception {
  final String fileName;
  final String? reason;
  final Map<String, dynamic>? diagnostics;
  const AttachmentReadException(this.fileName, [this.reason, this.diagnostics]);

  @override
  String toString() => 'לא ניתן לקרוא את הקובץ "$fileName". '
      'ודא שהוא זמין במחשב, העתק אותו מחדש או בחר אותו דרך כפתור ההעלאה.';
}

/// Technical codes only: never file names, paths, contents or error messages.
class ClipboardReadDiagnostics {
  final int batchSize;
  final int index;
  final List<Map<String, String>> _events = [];
  ClipboardReadDiagnostics({this.batchSize = 1, this.index = 0});

  void record(String stage, String code) {
    if (_events.length < 12) _events.add({'stage': stage, 'code': code});
  }

  Map<String, dynamic> toJson() => {
        'origin': 'clipboard',
        'batchSize': batchSize,
        'index': index,
        'events': List<Map<String, String>>.of(_events),
      };
}
