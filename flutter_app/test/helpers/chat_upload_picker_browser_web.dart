// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:js' as js;

/// Supplies a selected browser File at the real DOM picker boundary.
class ChatUploadPickerBrowser {
  late js.JsObject _picker;

  void install(String name, List<int> bytes) {
    js.context.callMethod('eval', [
      r'''
      (() => {
        const prototype = HTMLInputElement.prototype;
        const originalClick = prototype.click;
        let selectedName, selectedBytes, selections = 0;
        prototype.click = function(...args) {
          if (this.type !== 'file' || !this.accept.includes('.mp4'))
            return originalClick.apply(this, args);
          const transfer = new DataTransfer();
          transfer.items.add(new File([new Uint8Array(selectedBytes)], selectedName,
            {type: 'video/mp4', lastModified: 1791467372000}));
          Object.defineProperty(this, 'files', {configurable: true, value: transfer.files});
          selections++;
          queueMicrotask(() => this.dispatchEvent(new Event('change')));
        };
        window.chatUploadPickerTest = {
          select: (name, bytes) => {selectedName = name; selectedBytes = JSON.parse(bytes);},
          selections: () => selections,
          restore: () => {prototype.click = originalClick; delete window.chatUploadPickerTest;}
        };
      })();
    '''
    ]);
    _picker = js.context['chatUploadPickerTest'] as js.JsObject;
    _picker.callMethod('select', [name, jsonEncode(bytes)]);
  }

  int get selections => (_picker.callMethod('selections') as num).toInt();
  void dispose() => _picker.callMethod('restore');
}
