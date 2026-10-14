import 'package:flutter/material.dart';
import 'chat_design_settings.dart';

Future<T?> showDesignCardDetails<T>(
    BuildContext context, WidgetBuilder builder) {
  if (ChatDesignStore.shared.value
          .choice('cardDetailsPresentation', 'dialog') ==
      'sheet') {
    return showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .85),
        builder: (context) => SingleChildScrollView(child: builder(context)));
  }
  return showDialog<T>(context: context, builder: builder);
}

VoidCallback? designCardLongPress(VoidCallback details, VoidCallback? menu) =>
    switch (
        ChatDesignStore.shared.value.choice('cardLongPressAction', 'menu')) {
      'details' => details,
      'none' => () {},
      _ => menu,
    };

class RemoteCardNotice extends StatelessWidget {
  const RemoteCardNotice(
      {super.key,
      required this.title,
      required this.details,
      required this.icon,
      required this.compactSetting,
      this.fileName});
  final String title, details, compactSetting;
  final String? fileName;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final design = ChatDesignStore.shared.value;
    void open() => showDesignCardDetails<void>(
        context,
        (dialogContext) => Directionality(
            textDirection: TextDirection.rtl,
            child: AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(
                    child: Text([
                  if (fileName?.isNotEmpty == true) fileName!,
                  details
                ].join('\n'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('סגור'))
                ])));
    return Tooltip(
        message: fileName ?? title,
        child: InkWell(
            onTap: design.choice('cardTapAction', 'details') == 'details'
                ? open
                : null,
            onLongPress: designCardLongPress(open, null),
            child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: design.flag(compactSetting)
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        textDirection: TextDirection.rtl,
                        children: [
                            Icon(icon, size: 18),
                            const SizedBox(width: 6),
                            Flexible(
                                child: Text(title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: design.number(
                                            'noticeFontSize', 12))))
                          ])
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                            Text(title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            if (fileName?.isNotEmpty == true) Text(fileName!),
                            Text(details)
                          ]))));
  }
}
