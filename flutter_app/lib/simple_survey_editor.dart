import 'package:flutter/material.dart';

String surveyCopyTitle(String title) {
  const suffix = ' (עותק)';
  final result = StringBuffer();
  for (final character in title.trim().characters) {
    if (result.length + character.length + suffix.length > 160) break;
    result.write(character);
  }
  return '$result$suffix';
}

class SurveyQuestionDraft {
  SurveyQuestionDraft([Map<String, dynamic>? initial])
      : text = TextEditingController(text: initial?['text']?.toString()),
        allowMultiple = initial?['allowMultiple'] == true,
        options = (initial?['options'] as List? ?? ['', ''])
            .map((value) => TextEditingController(text: value.toString()))
            .toList();

  final TextEditingController text;
  bool allowMultiple;
  final List<TextEditingController> options;
  final Key key = UniqueKey();

  Map<String, dynamic> toJson() => {
        'text': text.text.trim(),
        'options': options.map((option) => option.text.trim()).toList(),
        if (allowMultiple) 'allowMultiple': true,
      };

  void dispose() {
    text.dispose();
    for (final option in options) {
      option.dispose();
    }
  }
}

String? validateSurveyQuestions(List<SurveyQuestionDraft> questions) {
  if (questions.isEmpty || questions.length > 20) {
    return 'יש להוסיף בין שאלה אחת ל־20 שאלות';
  }
  for (var index = 0; index < questions.length; index++) {
    final question = questions[index].toJson();
    final text = question['text'] as String;
    final options = question['options'] as List<String>;
    if (text.isEmpty) return 'יש לכתוב את שאלה ${index + 1}';
    if (text.length > 300) return 'שאלה ${index + 1} ארוכה מדי';
    if (options.length < 2 ||
        options.length > 12 ||
        options.any((option) => option.isEmpty || option.length > 150)) {
      return 'בשאלה ${index + 1} יש למלא לפחות שתי תשובות, עד 150 תווים לתשובה';
    }
    if (options.toSet().length != options.length) {
      return 'התשובות בשאלה ${index + 1} צריכות להיות שונות';
    }
  }
  return null;
}

class SurveyQuestionEditor extends StatelessWidget {
  const SurveyQuestionEditor({
    super.key,
    required this.question,
    required this.index,
    required this.onDuplicate,
    required this.onDelete,
    required this.onChanged,
    this.enabled = true,
  });

  final SurveyQuestionDraft question;
  final int index;
  final VoidCallback? onDuplicate;
  final VoidCallback onDelete, onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Container(
      key: ValueKey('survey-question-$index'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: color.withValues(alpha: .14)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: color.withValues(alpha: .1),
            child: Text('${index + 1}',
                style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 9),
          const Expanded(
              child: Text('שאלה ותשובות',
                  style: TextStyle(fontWeight: FontWeight.w600))),
          IconButton(
            tooltip: 'שכפל שאלה',
            onPressed: enabled ? onDuplicate : null,
            icon: const Icon(Icons.copy_outlined, size: 20),
          ),
          IconButton(
            tooltip: 'מחק שאלה',
            onPressed: enabled ? onDelete : null,
            icon: const Icon(Icons.delete_outline, size: 21),
          ),
        ]),
        const SizedBox(height: 10),
        TextField(
          key: ValueKey('survey-question-text-$index'),
          controller: question.text,
          enabled: enabled,
          textDirection: TextDirection.rtl,
          maxLength: 300,
          minLines: 1,
          maxLines: 3,
          decoration: InputDecoration(
            labelText: 'שאלה ${index + 1}',
            hintText: 'מה תרצו לשאול?',
            counterText: '',
          ),
        ),
        const SizedBox(height: 14),
        for (var option = 0; option < question.options.length; option++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Icon(
                  question.allowMultiple
                      ? Icons.check_box_outline_blank
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: color.withValues(alpha: .5)),
              const SizedBox(width: 9),
              Expanded(
                child: TextField(
                  key: ValueKey('survey-option-$index-$option'),
                  controller: question.options[option],
                  enabled: enabled,
                  textDirection: TextDirection.rtl,
                  maxLength: 150,
                  decoration: InputDecoration(
                    labelText: 'תשובה ${option + 1}',
                    counterText: '',
                    isDense: true,
                  ),
                ),
              ),
              if (question.options.length > 2)
                IconButton(
                  tooltip: 'מחק תשובה',
                  onPressed: !enabled
                      ? null
                      : () {
                          question.options.removeAt(option).dispose();
                          onChanged();
                        },
                  icon: const Icon(Icons.close, size: 18),
                ),
            ]),
          ),
        TextButton.icon(
          onPressed: !enabled || question.options.length >= 12
              ? null
              : () {
                  question.options.add(TextEditingController());
                  onChanged();
                },
          icon: const Icon(Icons.add, size: 18),
          label: const Text('הוסף תשובה'),
        ),
        Material(
          type: MaterialType.transparency,
          child: SwitchListTile.adaptive(
            key: ValueKey('survey-multiple-$index'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('לאפשר מספר בחירות?'),
            value: question.allowMultiple,
            onChanged: !enabled
                ? null
                : (value) {
                    question.allowMultiple = value;
                    onChanged();
                  },
          ),
        ),
      ]),
    );
  }
}

class SurveyLibraryDialog extends StatefulWidget {
  const SurveyLibraryDialog(
      {super.key, required this.forms, required this.onDeleteDraft});
  final List<Map<String, dynamic>> forms;
  final Future<bool> Function(Map<String, dynamic>) onDeleteDraft;

  @override
  State<SurveyLibraryDialog> createState() => _SurveyLibraryDialogState();
}

class _SurveyLibraryDialogState extends State<SurveyLibraryDialog> {
  late final _forms = List<Map<String, dynamic>>.of(widget.forms);
  String _query = '';
  bool _deleting = false;

  @override
  Widget build(BuildContext context) {
    final visible = _forms
        .where((form) => [
              form['title'],
              form['description'],
              for (final q in form['questions'] as List? ?? []) q['text']
            ].join(' ').toLowerCase().contains(_query.trim().toLowerCase()))
        .toList();
    return AlertDialog(
      title: const Text('סקרים שמורים'),
      content: SizedBox(
        width: 480,
        height: MediaQuery.sizeOf(context).height * .5,
        child: Column(children: [
          TextField(
            decoration: const InputDecoration(
                labelText: 'חיפוש בסקרים שמורים',
                prefixIcon: Icon(Icons.search)),
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 12),
          Expanded(
              child: visible.isEmpty
                  ? const Center(
                      child: Text('אין סקרים שמורים שמתאימים לחיפוש'))
                  : ListView(children: [
                      for (final form in visible)
                        ListTile(
                          leading: Icon(form['_surveyDraft'] == true
                              ? Icons.edit_note
                              : Icons.poll_outlined),
                          title: Text(form['title']?.toString() ?? ''),
                          subtitle: Text(form['_surveyDraft'] == true
                              ? 'טיוטה שמורה'
                              : 'סקר שפורסם · פתיחה כעותק'),
                          onTap: _deleting
                              ? null
                              : () => Navigator.pop(context, form),
                          trailing: form['_surveyDraft'] != true
                              ? null
                              : PopupMenuButton<String>(
                                  enabled: !_deleting,
                                  onSelected: (action) async {
                                    if (action == 'delete') {
                                      setState(() => _deleting = true);
                                      final deleted =
                                          await widget.onDeleteDraft(form);
                                      if (!mounted) return;
                                      setState(() {
                                        if (deleted) _forms.remove(form);
                                        _deleting = false;
                                      });
                                    } else {
                                      Navigator.pop(context, {
                                        ...form,
                                        '_duplicate': action == 'duplicate'
                                      });
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'edit',
                                        child: Text('ערוך טיוטה')),
                                    PopupMenuItem(
                                        value: 'duplicate',
                                        child: Text('שכפל טיוטה')),
                                    PopupMenuItem(
                                        value: 'delete',
                                        child: Text('מחק טיוטה')),
                                  ],
                                ),
                        ),
                    ])),
        ]),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('סגור'))
      ],
    );
  }
}
