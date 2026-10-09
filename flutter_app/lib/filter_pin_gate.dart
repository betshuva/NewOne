import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

final _pinChanges = StreamController<String>.broadcast(sync: true);

/// PIN access is checked by the server; this widget also disables draft editing.
class FilterPinGate extends StatefulWidget {
  final String api, token;
  final Widget child;
  const FilterPinGate(
      {super.key, required this.api, required this.token, required this.child});
  @override
  State<FilterPinGate> createState() => _FilterPinGateState();
}

class _FilterPinGateState extends State<FilterPinGate>
    with WidgetsBindingObserver {
  bool _loading = true, _configured = false, _unlocked = false, _busy = false;
  String? _error;
  Timer? _timer;
  StreamSubscription<String>? _changes;
  int _request = 0;
  String? _fetchingToken;
  bool _entered = false;
  String _scope = _newScope();
  static String _newScope() => List.generate(16,
          (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
  void _leave(String token, String scope) {
    if (token.isEmpty) return;
    unawaited(http
        .post(Uri.parse('${widget.api}/filter-pin/leave'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
              'X-Filter-Pin-Scope': scope
            },
            body: '{}')
        .timeout(const Duration(seconds: 20))
        .then<void>((_) {}, onError: (Object _) {}));
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _changes = _pinChanges.stream.listen((token) {
      if (token == widget.token) _load();
    });
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
    _load();
  }

  @override
  void didUpdateWidget(covariant FilterPinGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.token != widget.token) {
      _leave(oldWidget.token, _scope);
      _scope = _newScope();
      _entered = false;
      _loading = true;
      _unlocked = false;
      _load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  @override
  void dispose() {
    _leave(widget.token, _scope);
    ++_request;
    _timer?.cancel();
    _changes?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<Map<String, dynamic>> _call(String? action,
      [Map<String, dynamic>? body]) async {
    final uri = Uri.parse(
        '${widget.api}/filter-pin${action == null ? '' : '/$action'}');
    final headers = {
      'Authorization': 'Bearer ${widget.token}',
      'Content-Type': 'application/json',
      'X-Filter-Pin-Scope': _scope
    };
    final r = await (action == null
            ? http.get(uri, headers: headers)
            : http.post(uri, headers: headers, body: jsonEncode(body ?? {})))
        .timeout(const Duration(seconds: 20));
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 200)
      throw Exception(data['error'] ?? 'לא ניתן לבצע את הפעולה כעת');
    return data;
  }

  Future<void> _load() async {
    if (widget.token.isEmpty) {
      if (mounted)
        setState(() {
          _loading = false;
          _unlocked = true;
        });
      return;
    }
    if (_fetchingToken == widget.token) return;
    final token = widget.token;
    _fetchingToken = token;
    final request = ++_request;
    try {
      if (!_entered) {
        await _call('enter');
        if (!mounted || request != _request) return;
        _entered = true;
      }
      final data = await _call(null);
      if (data['configured'] is! bool || data['unlocked'] is! bool)
        throw Exception('לא ניתן לבדוק את נעילת הסינון כעת');
      if (mounted && request == _request)
        setState(() {
          _configured = data['configured'];
          _unlocked = data['unlocked'];
          _loading = false;
          _error = null;
        });
    } catch (_) {
      if (mounted && request == _request)
        setState(() {
          _loading = false;
          _unlocked = false;
          _error = 'לא ניתן לבדוק את הנעילה. לחצו כדי לנסות שוב';
        });
    } finally {
      if (_fetchingToken == token) _fetchingToken = null;
    }
  }

  Future<String?> _pad(String title,
          {bool forgot = false,
          bool disable = false,
          int minimum = 4,
          int maximum = 8}) =>
      showDialog<String>(
          context: context,
          builder: (_) => FilterPinPad(
              title: title,
              forgot: forgot,
              disable: disable,
              minimum: minimum,
              maximum: maximum));
  Future<void> _toggle() async {
    if (_busy || _loading) return;
    if (_error != null) {
      await _load();
      return;
    }
    final token = widget.token;
    setState(() => _busy = true);
    try {
      final pin = await _pad(
          _configured
              ? (_unlocked ? 'נעילת הגדרות הסינון' : 'פתיחת הגדרות הסינון')
              : 'בחרו קוד לסינון (4–8 ספרות)',
          forgot: _configured,
          disable: _configured);
      if (pin == null || !mounted || token != widget.token) return;
      if (pin.startsWith('disable:')) {
        await _call('disable', {'pin': pin.substring(8)});
      } else if (pin == 'recover') {
        await _call('recover');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'קישור לבחירת קוד חדש נשלח לאימייל המאומת שהוגדר עם הקוד')));
        return;
      } else if (!_configured) {
        final confirm = await _pad('הזינו שוב את הקוד');
        if (confirm == null || !mounted) return;
        if (!mounted || token != widget.token) return;
        await _call('setup', {'pin': pin, 'confirmPin': confirm});
      } else {
        await _call(_unlocked ? 'lock' : 'unlock', {'pin': pin});
      }
      if (mounted && token == widget.token) {
        if (pin == 'recover' ||
            !_configured ||
            _unlocked && !pin.startsWith('disable:')) _entered = false;
        _pinChanges.add(token);
        await _load();
      }
    } catch (e) {
      if (mounted && token == widget.token)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', ''))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.token.isNotEmpty)
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Row(children: [
                    IconButton(
                        key: const ValueKey('filter-pin-lock'),
                        color: _unlocked
                            ? (_configured
                                ? Colors.green.shade700
                                : Colors.orange.shade800)
                            : Colors.red.shade700,
                        tooltip: _unlocked
                            ? 'נעילת הגדרות הסינון'
                            : 'פתיחת הגדרות הסינון',
                        onPressed: _loading || _busy ? null : _toggle,
                        icon: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Icon(_unlocked
                                ? Icons.lock_open_outlined
                                : Icons.lock_outline)),
                    Expanded(
                        child: Text(
                            _error ??
                                (_loading
                                    ? 'בודק נעילת הגדרות…'
                                    : _unlocked
                                        ? (_configured
                                            ? 'ההגדרות פתוחות לעריכה עד היציאה מהמסך'
                                            : 'ההגדרות פתוחות • מומלץ לנעול באמצעות קוד')
                                        : 'ההגדרות נעולות'),
                            style: TextStyle(
                                fontSize: 12,
                                color: _loading
                                    ? null
                                    : _unlocked
                                        ? (_configured
                                            ? Colors.green.shade700
                                            : Colors.orange.shade800)
                                        : Colors.red.shade700))),
                  ])),
            FocusScope(
                canRequestFocus: _unlocked && !_loading,
                child: AbsorbPointer(
                    absorbing: !_unlocked || _loading, child: widget.child)),
          ]);
}

class FilterPinPad extends StatefulWidget {
  final String title;
  final bool forgot, disable;
  final int minimum, maximum;
  const FilterPinPad(
      {super.key,
      required this.title,
      this.forgot = false,
      this.disable = false,
      this.minimum = 4,
      this.maximum = 8});
  @override
  State<FilterPinPad> createState() => _FilterPinPadState();
}

class _FilterPinPadState extends State<FilterPinPad> {
  String _value = '';
  void _press(String key) {
    if (key == 'cancel') {
      Navigator.pop(context);
      return;
    }
    if (key == 'ok') {
      if (_value.length >= widget.minimum) Navigator.pop(context, _value);
      return;
    }
    setState(() {
      if (key == 'delete') {
        if (_value.isNotEmpty) _value = _value.substring(0, _value.length - 1);
      } else if (_value.length < widget.maximum) {
        _value += key;
      }
    });
  }

  Future<void> _confirmDisable() async {
    final code = _value;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
                constraints: const BoxConstraints(maxWidth: 320),
                title: const Text('האם אתם בטוחים?'),
                content: const Text(
                    'פעולה זו מסירה את הנעילה מכל מסכי הסינון. הסינון עצמו ממשיך לפעול.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('השארת הנעילה')),
                  FilledButton(
                      key: const ValueKey('filter-pin-confirm-disable'),
                      style: FilledButton.styleFrom(
                          backgroundColor: Colors.red.shade700,
                          foregroundColor: Colors.white),
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('כן, ביטול הנעילה')),
                ])));
    if (confirmed == true && mounted) Navigator.pop(context, 'disable:$code');
  }

  @override
  Widget build(BuildContext context) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        constraints: const BoxConstraints(maxWidth: 320),
        insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        title: Text(widget.title, textAlign: TextAlign.center),
        content: SingleChildScrollView(
            child: Focus(
                autofocus: true,
                onKeyEvent: (_, e) {
                  if (e is! KeyDownEvent) return KeyEventResult.ignored;
                  if (e.logicalKey == LogicalKeyboardKey.backspace) {
                    _press('delete');
                    return KeyEventResult.handled;
                  }
                  if (e.logicalKey == LogicalKeyboardKey.enter) {
                    _press('ok');
                    return KeyEventResult.handled;
                  }
                  if (e.character != null &&
                      RegExp(r'^\d$').hasMatch(e.character!)) {
                    _press(e.character!);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(
                          widget.maximum,
                          (i) => Padding(
                              padding: const EdgeInsets.all(3),
                              child: Icon(
                                  i < _value.length
                                      ? Icons.circle
                                      : Icons.circle_outlined,
                                  size: 16)))),
                  const SizedBox(height: 16),
                  for (final row in [
                    ['1', '2', '3'],
                    ['4', '5', '6'],
                    ['7', '8', '9'],
                    ['delete', '0', 'cancel']
                  ])
                    Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          for (final key in row)
                            Expanded(
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: OutlinedButton(
                                      key: ValueKey('filter-pin-key-$key'),
                                      style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 16)),
                                      onPressed: () => _press(key),
                                      child: key == 'delete'
                                          ? const Icon(Icons.backspace_outlined)
                                          : key == 'cancel'
                                              ? const Icon(Icons.close)
                                              : Text(key,
                                                  style: const TextStyle(
                                                      fontSize: 24)),
                                    ))),
                        ])),
                  SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                          onPressed: _value.length >= widget.minimum
                              ? () => _press('ok')
                              : null,
                          child: const Text('אישור'))),
                  if (widget.disable)
                    TextButton(
                        key: const ValueKey('filter-pin-disable'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red.shade700),
                        onPressed: _value.length >= widget.minimum
                            ? _confirmDisable
                            : null,
                        child: const Text('ביטול נעילת קוד')),
                  if (widget.forgot)
                    TextButton(
                        onPressed: () => Navigator.pop(context, 'recover'),
                        child: const Text('שכחתי קוד')),
                ]))),
      ));
}
