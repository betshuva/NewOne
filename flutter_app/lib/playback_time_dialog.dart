import 'package:flutter/material.dart';

Future<Duration?> showPlaybackTimeDialog(BuildContext context,
    {required Duration position, required Duration duration}) async {
  final controller = TextEditingController(text:
      '${position.inMinutes}:${(position.inSeconds % 60).toString().padLeft(2, '0')}');
  String? error;
  final result = await showDialog<Duration>(context: context, builder: (context) =>
    StatefulBuilder(builder: (context, update) => AlertDialog(
      title: const Text('מעבר לזמן'),
      content: TextField(controller: controller, autofocus: true,
        textDirection: TextDirection.ltr, keyboardType: TextInputType.datetime,
        decoration: InputDecoration(labelText: 'דקות:שניות', helperMaxLines: 2,
          helperText: 'לדוגמה 12:30, או 1:05:00 לשעה וחמש דקות', errorText: error)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('ביטול')),
        TextButton(onPressed: () {
          final parts = controller.text.trim().split(':');
          final numbers = parts.map(int.tryParse).toList();
          if (parts.length > 3 || numbers.any((v) => v == null || v < 0) ||
              numbers.skip(1).any((v) => v! >= 60)) {
            update(() => error = 'יש להזין זמן תקין'); return;
          }
          var seconds = 0;
          for (final value in numbers) { seconds = seconds * 60 + value!; }
          if (seconds > duration.inSeconds) {
            update(() => error = 'הזמן חורג מאורך הקובץ'); return;
          }
          Navigator.pop(context, Duration(seconds: seconds));
        }, child: const Text('מעבר')),
      ],
    )));
  // The dialog's exit animation still owns the text field after pop.
  Future<void>.delayed(const Duration(seconds: 1), controller.dispose);
  return result;
}
