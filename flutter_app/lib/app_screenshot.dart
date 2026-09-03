import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import 'file_download.dart';
import 'screen_capture.dart';

const _api = 'https://betshuva.com/betshuva-app/api';
const _israelId = '00000000-0000-4000-8000-000000000002';
const _bugDescriptionTemplate = '''מה ניסיתי לעשות:

מה קרה בפועל:

מה ציפיתי שיקרה:

פרטים נוספים:''';
const _developmentDescriptionTemplate = '''מה הייתי רוצה שיהיה אפשר לעשות:

למי זה יעזור:

איך הייתי מציע שזה יעבוד:

פרטים נוספים:''';

String _descriptionTemplate(String requestType) => requestType == 'development'
    ? _developmentDescriptionTemplate
    : _bugDescriptionTemplate;

final appScreenshotNavigatorKey = GlobalKey<NavigatorState>();
final appScreenshotBoundaryKey = GlobalKey();
final appScreenshotToken = ValueNotifier<String?>(null);
final appScreenshotBusy = ValueNotifier<bool>(false);
Future<void> Function(String issueId)? appScreenshotIssueOpened;
Future<void> Function(BuildContext context, Uint8List bytes, String name)?
    appScreenshotTargetSender;
final appScreenshotDestination = ValueNotifier<AppScreenshotDestination>(
    const AppScreenshotDestination.user(_israelId));
final Map<Object, VoidCallback> _appScreenshotMenus = {};

void registerAppScreenshotMenu(Object owner, VoidCallback openMenu) {
  _appScreenshotMenus.remove(owner);
  _appScreenshotMenus[owner] = openMenu;
}

void unregisterAppScreenshotMenu(Object owner) {
  _appScreenshotMenus.remove(owner);
}

bool openRegisteredAppScreenshotMenu() {
  if (_appScreenshotMenus.isEmpty) return false;
  _appScreenshotMenus.values.last();
  return true;
}

class AppScreenshotDestination {
  final String kind;
  final String id;
  const AppScreenshotDestination._(this.kind, this.id);
  const AppScreenshotDestination.user(String id) : this._('user', id);
  const AppScreenshotDestination.group(String id) : this._('group', id);
  bool sameAs(AppScreenshotDestination other) =>
      kind == other.kind && id == other.id;
}

Future<void> openAppScreenshot(
  BuildContext context, {
  String? token,
  AppScreenshotDestination? destination,
}) async {
  final authToken = token ?? appScreenshotToken.value;
  if (appScreenshotBusy.value) return;
  if (authToken == null || authToken.isEmpty) {
    final messengerContext = appScreenshotNavigatorKey.currentContext;
    if (messengerContext != null) {
      ScaffoldMessenger.maybeOf(messengerContext)?.showSnackBar(const SnackBar(
          content: Text('לא ניתן לצלם: יש להתחבר מחדש לאפליקציה')));
    }
    return;
  }
  appScreenshotBusy.value = true;
  try {
    final capturePixelRatio =
        MediaQuery.devicePixelRatioOf(context).clamp(1.0, 2.0);
    // Browsers require getDisplayMedia to run directly inside the click's user
    // activation. Even a short delay can make Chrome reject the request before
    // showing its tab picker.
    final Uint8List captured;
    if (kIsWeb) {
      captured =
          await captureCurrentAppScreen().timeout(const Duration(seconds: 45));
    } else {
      await WidgetsBinding.instance.endOfFrame;
      final boundary = appScreenshotBoundaryKey.currentContext
          ?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('app capture boundary unavailable');
      }
      final image = await boundary.toImage(pixelRatio: capturePixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('app capture failed');
      captured = data.buffer.asUint8List();
    }
    if (!context.mounted) return;
    final navigator = appScreenshotNavigatorKey.currentState;
    if (navigator == null) throw StateError('app navigator unavailable');
    final resolvedDestination = destination ?? appScreenshotDestination.value;
    final edited = await navigator.push<_ScreenshotResult>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _ScreenshotEditor(
        bytes: captured,
        sendsToIsrael: resolvedDestination.kind == 'user' &&
            resolvedDestination.id == _israelId,
      ),
    ));
    if (edited == null || !context.mounted) return;
    final name =
        'betshuva-screenshot-${DateTime.now().millisecondsSinceEpoch}.png';
    if (edited.saveOnly) {
      final saved = await triggerBytesDownload(edited.bytes, name, 'image/png');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                saved ? 'צילום המסך נשמר' : 'לא ניתן לשמור את צילום המסך')));
      }
      return;
    }
    if (edited.sendToIsrael) {
      await _createIssueFromScreenshot(context, authToken, edited, name);
    } else if (edited.chooseTargets) {
      final sender = appScreenshotTargetSender;
      if (sender == null) {
        throw StateError('screenshot target picker unavailable');
      }
      await sender(context, edited.bytes, name);
    } else {
      await _sendScreenshot(
          context, authToken, resolvedDestination, edited.bytes, name);
    }
  } catch (error) {
    debugPrint('App screenshot failed: $error');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('לא ניתן לצלם את המסך כעת')));
    }
  } finally {
    appScreenshotBusy.value = false;
  }
}

Future<Map<String, dynamic>> _uploadIssueFile(
    String token, List<int> bytes, String name, String mimeType) async {
  final mimeParts = mimeType.split('/');
  final request = http.MultipartRequest('POST', Uri.parse('$_api/upload'))
    ..headers['Authorization'] = 'Bearer $token'
    ..files.add(http.MultipartFile.fromBytes('file', bytes,
        filename: name,
        contentType: MediaType(
            mimeParts.first,
            mimeParts.length > 1
                ? mimeParts[1].split(';').first
                : 'octet-stream')));
  final response = await request.send().timeout(const Duration(seconds: 210));
  final body = await response.stream.bytesToString();
  final decoded = jsonDecode(body);
  if (response.statusCode != 200 || decoded is! Map || decoded['url'] == null) {
    throw StateError(decoded is Map
        ? decoded['error']?.toString() ?? 'העלאת הקובץ נכשלה'
        : 'העלאת הקובץ נכשלה');
  }
  return Map<String, dynamic>.from(decoded);
}

Future<void> _createIssueFromScreenshot(BuildContext context, String token,
    _ScreenshotResult result, String screenshotName) async {
  final uploaded = <String>[];
  final screenshot =
      await _uploadIssueFile(token, result.bytes, screenshotName, 'image/png');
  uploaded.add(screenshot['url'].toString());
  for (final file in result.additionalFiles) {
    final bytes = file.bytes;
    if (bytes == null) throw StateError('לא ניתן לקרוא את ${file.name}');
    final mime = file.extension == null
        ? 'application/octet-stream'
        : switch (file.extension!.toLowerCase()) {
            'jpg' || 'jpeg' => 'image/jpeg',
            'png' => 'image/png',
            'gif' => 'image/gif',
            'pdf' => 'application/pdf',
            'docx' =>
              'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'mp4' => 'video/mp4',
            'webm' => 'video/webm',
            'mov' => 'video/quicktime',
            'wav' => 'audio/wav',
            'm4a' => 'audio/mp4',
            _ => 'application/octet-stream',
          };
    final attachment = await _uploadIssueFile(token, bytes, file.name, mime);
    uploaded.add(attachment['url'].toString());
  }
  final response = await http.post(Uri.parse('$_api/support-issues'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'issueType':
            result.israelRequestType == 'development' ? 'feature' : 'bug',
        'description': result.israelDescription,
        'attachmentUrls': uploaded,
        'clientContext': {
          'platform': 'web',
          'screen': Uri.base.queryParameters['screen'] ?? Uri.base.path,
          'pageUrl': Uri.base.toString(),
        },
      }));
  final decoded = jsonDecode(response.body);
  if (response.statusCode != 201 || decoded is! Map || decoded['id'] == null) {
    throw StateError(decoded is Map
        ? decoded['error']?.toString() ?? 'פתיחת הקריאה נכשלה'
        : 'פתיחת הקריאה נכשלה');
  }
  final issueId = decoded['id'].toString();
  if (context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('הקריאה נפתחה: $issueId')));
  }
  await appScreenshotIssueOpened?.call(issueId);
}

Future<void> _sendScreenshot(
  BuildContext context,
  String token,
  AppScreenshotDestination destination,
  Uint8List bytes,
  String name, {
  String? israelRequestType,
  String? israelDescription,
}) async {
  final request = http.MultipartRequest('POST', Uri.parse('$_api/upload'))
    ..headers['Authorization'] = 'Bearer $token'
    ..fields[destination.kind == 'group' ? 'groupId' : 'toUserId'] =
        destination.id
    ..files.add(http.MultipartFile.fromBytes(
      'file',
      bytes,
      filename: name,
      contentType: MediaType('image', 'png'),
    ));
  final upload = await request.send().timeout(const Duration(seconds: 60));
  final uploadBody = await upload.stream.bytesToString();
  if (upload.statusCode != 200) throw StateError('screenshot upload failed');
  final decoded = jsonDecode(uploadBody);
  if (decoded is! Map || decoded['url'] == null) {
    throw StateError('screenshot upload response invalid');
  }
  if (decoded['status'] == 'rejected') {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text(decoded['reason']?.toString() ?? 'צילום המסך נחסם בסריקה')));
    }
    return;
  }
  if (decoded['status'] == 'pending') {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('צילום המסך נשלח לסריקה ויישלח לאחר אישור')));
    }
    return;
  }
  final payload = {
    'fileUrl': decoded['url'],
    'fileName': decoded['fileName'] ?? name,
    'fileType': decoded['fileType'] ?? 'image',
  };
  final response = destination.kind == 'group'
      ? await http.post(Uri.parse('$_api/groups/${destination.id}/messages'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(payload))
      : await http.post(Uri.parse('$_api/messages'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({...payload, 'toUserId': destination.id}));
  if (response.statusCode != 200) throw StateError('screenshot send failed');
  if (destination.id == _israelId && israelDescription?.isNotEmpty == true) {
    final typeLabel =
        israelRequestType == 'development' ? 'בקשת פיתוח' : 'דיווח על תקלה';
    final detailsResponse = await http.post(Uri.parse('$_api/messages'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'toUserId': _israelId,
          'text': '$typeLabel המצורף לצילום המסך:\n$israelDescription',
        }));
    if (detailsResponse.statusCode != 200) {
      throw StateError('screenshot description send failed');
    }
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(destination.id == _israelId
            ? 'צילום המסך נשלח לשירות ה-AI'
            : 'צילום המסך נשלח')));
  }
}

class AppScreenshotButton extends StatelessWidget {
  const AppScreenshotButton({super.key});

  @override
  Widget build(BuildContext context) => !kIsWeb
      ? const SizedBox.shrink()
      : Positioned(
          left: 16,
          bottom: 78,
          child: Material(
            elevation: 6,
            color: const Color(0xFF1B6CA8),
            shape: const CircleBorder(),
            child: IconButton(
              tooltip: 'פתיחת תפריט צילום מסך',
              color: Colors.white,
              icon: const Icon(Icons.screenshot_monitor_outlined),
              onPressed: openRegisteredAppScreenshotMenu,
            ),
          ),
        );
}

class _ScreenshotResult {
  final Uint8List bytes;
  final bool saveOnly;
  final bool sendToIsrael;
  final bool chooseTargets;
  final String? israelRequestType;
  final String? israelDescription;
  final List<PlatformFile> additionalFiles;
  const _ScreenshotResult(this.bytes,
      {required this.saveOnly,
      this.sendToIsrael = false,
      this.chooseTargets = false,
      this.israelRequestType,
      this.israelDescription,
      this.additionalFiles = const []});
}

enum _EditTool { crop, blur, mark, text }

class _ScreenshotEditor extends StatefulWidget {
  final Uint8List bytes;
  final bool sendsToIsrael;
  const _ScreenshotEditor({required this.bytes, required this.sendsToIsrael});
  @override
  State<_ScreenshotEditor> createState() => _ScreenshotEditorState();
}

class _ScreenshotEditorState extends State<_ScreenshotEditor> {
  final _outputKey = GlobalKey();
  final List<List<Offset>> _strokes = [];
  final List<Offset> _blurPoints = [];
  final List<String> _texts = [];
  _EditTool _tool = _EditTool.crop;
  double _left = 0, _right = 0, _top = 0, _bottom = 0;
  String? _activeCropEdge;
  bool _working = false;

  Future<void> _addText() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('הוספת טקסט'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 120,
          decoration: const InputDecoration(hintText: 'הקלד טקסט'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('ביטול')),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('הוסף'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text != null && text.isNotEmpty) setState(() => _texts.add(text));
  }

  Future<void> _finish(bool saveOnly,
      {bool sendToIsrael = false,
      bool chooseTargets = false,
      String? israelRequestType,
      String? israelDescription,
      List<PlatformFile> additionalFiles = const []}) async {
    if (_working) return;
    setState(() => _working = true);
    await WidgetsBinding.instance.endOfFrame;
    final boundary =
        _outputKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    final image = await boundary?.toImage(pixelRatio: 2);
    final data = await image?.toByteData(format: ui.ImageByteFormat.png);
    image?.dispose();
    if (!mounted) return;
    if (data == null) {
      setState(() => _working = false);
      return;
    }
    Navigator.pop(
        context,
        _ScreenshotResult(data.buffer.asUint8List(),
            saveOnly: saveOnly,
            sendToIsrael: sendToIsrael,
            chooseTargets: chooseTargets,
            israelRequestType: israelRequestType,
            israelDescription: israelDescription,
            additionalFiles: additionalFiles));
  }

  Future<void> _sendToIsrael() async {
    var requestType = 'bug';
    var activeTemplate = _descriptionTemplate(requestType);
    final additionalFiles = <PlatformFile>[];
    final controller = TextEditingController(text: activeTemplate);
    final details = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('פתיחת קריאה'),
          content: SizedBox(
            width: 440,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                'צילום המסך, התיאור והקבצים שתצרף יישמרו יחד בקריאה לצוות הפיתוח. לאחר הפתיחה תועבר לקריאה, ושירות ה-AI ישלח בצ׳אט אישור עם פרטי הפנייה וקישור ישיר למעקב.',
                textDirection: TextDirection.rtl,
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                      value: 'bug',
                      label: Text('דיווח תקלה'),
                      icon: Icon(Icons.bug_report_outlined)),
                  ButtonSegment(
                      value: 'development',
                      label: Text('בקשת פיתוח'),
                      icon: Icon(Icons.lightbulb_outline)),
                ],
                selected: {requestType},
                onSelectionChanged: (value) {
                  final previousTemplate = activeTemplate;
                  setDialogState(() {
                    requestType = value.first;
                    activeTemplate = _descriptionTemplate(requestType);
                    if (controller.text.trim().isEmpty ||
                        controller.text == previousTemplate) {
                      controller.value = TextEditingValue(
                        text: activeTemplate,
                        selection: TextSelection.collapsed(
                            offset: activeTemplate.length),
                      );
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                onChanged: (_) => setDialogState(() {}),
                autofocus: true,
                minLines: 8,
                maxLines: 10,
                textDirection: TextDirection.rtl,
                decoration: const InputDecoration(
                  labelText: 'מה קרה או מה תרצה להוסיף?',
                  hintText: 'תאר את התקלה או הבקשה...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final picked = await FilePicker.platform
                        .pickFiles(allowMultiple: true, withData: true);
                    if (picked == null) return;
                    setDialogState(() {
                      additionalFiles
                        ..clear()
                        ..addAll(picked.files.take(9));
                    });
                  },
                  icon: const Icon(Icons.attach_file),
                  label: Text(additionalFiles.isEmpty
                      ? 'הוסף קבצים לפנייה'
                      : 'צורפו ${additionalFiles.length} קבצים נוספים'),
                ),
              ),
              if (additionalFiles.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                      additionalFiles.map((file) => file.name).join(', '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(fontSize: 11)),
                ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('ביטול')),
            FilledButton.icon(
              onPressed: controller.text.trim().isEmpty ||
                      controller.text == activeTemplate
                  ? null
                  : () => Navigator.pop(dialogContext, {
                        'type': requestType,
                        'description': controller.text.trim(),
                      }),
              icon: const Icon(Icons.send),
              label: const Text('פתח קריאה'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (details == null || !mounted) return;
    await _finish(false,
        sendToIsrael: true,
        israelRequestType: details['type'],
        israelDescription: details['description'],
        additionalFiles: additionalFiles);
  }

  Widget _toolButton(_EditTool tool, IconData icon, String label) => ChoiceChip(
        selected: _tool == tool,
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onSelected: (_) {
          setState(() => _tool = tool);
          if (tool == _EditTool.text) _addText();
        },
      );

  @override
  Widget build(BuildContext context) {
    final visibleWidth = 1 - _left - _right;
    final visibleHeight = 1 - _top - _bottom;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: Text(compact ? 'צילום מסך' : 'עריכת צילום מסך'),
        leading: IconButton(
            tooltip: 'סגור',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.pop(context)),
        actions: compact
            ? null
            : [
                TextButton.icon(
                  onPressed: _working ? null : _sendToIsrael,
                  icon: const Icon(Icons.support_agent, color: Colors.white),
                  label: const Text('פנייה לתמיכה',
                      style: TextStyle(color: Colors.white)),
                ),
                TextButton.icon(
                  onPressed: _working ? null : () => _finish(true),
                  icon:
                      const Icon(Icons.download_outlined, color: Colors.white),
                  label:
                      const Text('שמור', style: TextStyle(color: Colors.white)),
                ),
                FilledButton.icon(
                  onPressed: _working
                      ? null
                      : () =>
                          _finish(false, chooseTargets: widget.sendsToIsrael),
                  icon: const Icon(Icons.send),
                  label: Text(
                      widget.sendsToIsrael ? 'שלח למשתמש או לקבוצה' : 'שלח'),
                ),
                const SizedBox(width: 10),
              ],
      ),
      body: Column(children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          alignment: WrapAlignment.center,
          children: [
            _toolButton(_EditTool.crop, Icons.crop, 'חיתוך'),
            _toolButton(_EditTool.blur, Icons.blur_on, 'טשטוש'),
            _toolButton(_EditTool.mark, Icons.brush_outlined, 'סימון'),
            _toolButton(_EditTool.text, Icons.text_fields, 'טקסט'),
            ActionChip(
              avatar: const Icon(Icons.undo, size: 18),
              label: const Text('בטל אחרון'),
              onPressed: () => setState(() {
                if (_texts.isNotEmpty) {
                  _texts.removeLast();
                } else if (_strokes.isNotEmpty) {
                  _strokes.removeLast();
                } else if (_blurPoints.isNotEmpty) {
                  _blurPoints.removeLast();
                }
              }),
            ),
          ],
        ),
        if (_tool == _EditTool.crop)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 5),
            child: Text('לחיתוך: גרור פנימה מהצד שברצונך להסיר'),
          ),
        if (widget.sendsToIsrael)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: Text(
              'מידע בטוח · AI הוא שירות אוטומטי ומדריך התמיכה של אפליקציית בתשובה. אפשר לשלוח אליו צילום מסך כדי לקבל עזרה או להכין פנייה למפתח.',
              textAlign: TextAlign.center,
              textDirection: TextDirection.rtl,
            ),
          ),
        Expanded(
          child: Center(
            child: LayoutBuilder(builder: (context, constraints) {
              final width = math.min(constraints.maxWidth - 24, 1100.0);
              final height = math.min(constraints.maxHeight - 24, width * .62);
              return RepaintBoundary(
                key: _outputKey,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: GestureDetector(
                    onTapDown: (details) {
                      if (_tool != _EditTool.blur) return;
                      final point = details.localPosition;
                      setState(() => _blurPoints
                          .add(Offset(point.dx / width, point.dy / height)));
                    },
                    onPanStart: (details) {
                      if (_tool == _EditTool.mark) {
                        setState(() => _strokes.add([details.localPosition]));
                      } else if (_tool == _EditTool.crop) {
                        final point = details.localPosition;
                        final distances = <String, double>{
                          'left': point.dx,
                          'right': width - point.dx,
                          'top': point.dy,
                          'bottom': height - point.dy,
                        };
                        _activeCropEdge = distances.entries
                            .reduce((a, b) => a.value <= b.value ? a : b)
                            .key;
                      }
                    },
                    onPanUpdate: (details) {
                      if (_tool == _EditTool.mark && _strokes.isNotEmpty) {
                        setState(
                            () => _strokes.last.add(details.localPosition));
                      } else if (_tool == _EditTool.crop) {
                        setState(() {
                          switch (_activeCropEdge) {
                            case 'left':
                              _left = (_left + details.delta.dx / width)
                                  .clamp(0, math.max(0, .8 - _right))
                                  .toDouble();
                              break;
                            case 'right':
                              _right = (_right - details.delta.dx / width)
                                  .clamp(0, math.max(0, .8 - _left))
                                  .toDouble();
                              break;
                            case 'top':
                              _top = (_top + details.delta.dy / height)
                                  .clamp(0, math.max(0, .8 - _bottom))
                                  .toDouble();
                              break;
                            case 'bottom':
                              _bottom = (_bottom - details.delta.dy / height)
                                  .clamp(0, math.max(0, .8 - _top))
                                  .toDouble();
                              break;
                          }
                        });
                      }
                    },
                    onPanEnd: (_) => _activeCropEdge = null,
                    child: Stack(fit: StackFit.expand, children: [
                      ClipRect(
                        child: OverflowBox(
                          minWidth: width / visibleWidth,
                          maxWidth: width / visibleWidth,
                          minHeight: height / visibleHeight,
                          maxHeight: height / visibleHeight,
                          alignment: Alignment(
                            (_left - _right) / visibleWidth,
                            (_top - _bottom) / visibleHeight,
                          ),
                          child: Image.memory(widget.bytes, fit: BoxFit.fill),
                        ),
                      ),
                      ..._blurPoints.map((point) => Positioned(
                            left: point.dx * width - 35,
                            top: point.dy * height - 35,
                            width: 70,
                            height: 70,
                            child: ClipOval(
                              child: BackdropFilter(
                                filter:
                                    ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                                child: Container(
                                    color: Colors.white.withValues(alpha: .05)),
                              ),
                            ),
                          )),
                      CustomPaint(painter: _ScreenshotStrokePainter(_strokes)),
                      ..._texts.indexed.map((entry) => Positioned(
                            top: 22.0 + entry.$1 * 38,
                            left: 24,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              color: Colors.white.withValues(alpha: .82),
                              child: Text(entry.$2,
                                  style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.red)),
                            ),
                          )),
                    ]),
                  ),
                ),
              );
            }),
          ),
        ),
        if (compact)
          SafeArea(
            top: false,
            child: Material(
              elevation: 8,
              color: Theme.of(context).colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 7),
                child: Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : _sendToIsrael,
                      icon: const Icon(Icons.support_agent),
                      label: const Text('תמיכה'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _working ? null : () => _finish(true),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('שמור'),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _working
                          ? null
                          : () => _finish(false,
                              chooseTargets: widget.sendsToIsrael),
                      icon: const Icon(Icons.send),
                      label: const Text('שלח'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

class _ScreenshotStrokePainter extends CustomPainter {
  final List<List<Offset>> strokes;
  const _ScreenshotStrokePainter(this.strokes);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..strokeWidth = 5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final point in stroke.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScreenshotStrokePainter oldDelegate) => true;
}
