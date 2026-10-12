import 'package:flutter/material.dart';

const _primary = Color(0xFF1B6DA8);
const _border = Color(0xFFD5E4EF);

/// The form alone scrolls; actions remain above the keyboard and safe area.
class ListingEditorLayout extends StatelessWidget {
  const ListingEditorLayout({
    super.key,
    required this.child,
    required this.onSave,
    required this.saveLabel,
    required this.status,
    this.onSaveDraft,
    this.saving = false,
    this.savingDraft = false,
    this.draftEnabled = true,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final VoidCallback? onSave, onSaveDraft;
  final String saveLabel, status;
  final bool saving, savingDraft, draftEnabled;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Align(
        alignment: alignment,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Theme(
            data: theme.copyWith(
              inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                filled: true,
                fillColor: Colors.white,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _border)),
                focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: _primary, width: 1.5)),
              ),
            ),
            child: Material(
              color: const Color(0xFFF7FAFC),
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const ValueKey('listing-form-scroll'),
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
                      child: child,
                    ),
                  ),
                  Material(
                    color: Colors.white,
                    elevation: 8,
                    child: SafeArea(
                      top: false,
                      child: Container(
                        decoration: const BoxDecoration(
                            border: Border(top: BorderSide(color: _border))),
                        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(status,
                                maxLines: 2,
                                style: const TextStyle(
                                    fontSize: 12, color: Color(0xFF526A7D))),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                if (onSaveDraft != null) ...[
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      key: const ValueKey('listing-save-draft'),
                                      style: OutlinedButton.styleFrom(
                                          foregroundColor: _primary,
                                          minimumSize: const Size(0, 48),
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 8),
                                          shape: shape),
                                      onPressed: draftEnabled &&
                                              !saving &&
                                              !savingDraft
                                          ? onSaveDraft
                                          : null,
                                      icon: savingDraft
                                          ? const SizedBox.square(
                                              dimension: 18,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2))
                                          : const Icon(Icons.save_outlined,
                                              size: 20),
                                      label: const Text('שמור טיוטה'),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                ],
                                Expanded(
                                  child: FilledButton.icon(
                                    key: ValueKey(onSaveDraft == null
                                        ? 'listing-save-changes'
                                        : 'listing-publish'),
                                    style: FilledButton.styleFrom(
                                        backgroundColor: _primary,
                                        minimumSize: const Size(0, 48),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8),
                                        shape: shape),
                                    onPressed:
                                        saving || savingDraft ? null : onSave,
                                    icon: saving
                                        ? const SizedBox.square(
                                            dimension: 18,
                                            child: CircularProgressIndicator(
                                                color: Colors.white,
                                                strokeWidth: 2))
                                        : Icon(
                                            onSaveDraft == null
                                                ? Icons.check
                                                : Icons.publish_outlined,
                                            size: 20),
                                    label: Text(saveLabel,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.bold)),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ListingEditorSection extends StatelessWidget {
  const ListingEditorSection(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.icon});

  final String title, subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: const Color(0xFFE8F2FA),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: _primary, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF203E55))),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFF526A7D), height: 1.4)),
              ])),
        ]),
      );
}
