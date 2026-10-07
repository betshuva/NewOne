// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:convert';
import 'dart:js' as js;

import 'package:http/http.dart' as http;

/// Runs the app's actual Blob/FileReader and resumable browser upload path.
/// Only its XHR network boundary is replaced, with named completion gates.
class ListingUploadBrowser {
  late js.JsObject _server;

  void install() {
    js.context.callMethod('eval', [
      r'''
      (() => {
        const proto = XMLHttpRequest.prototype;
        const original = {open: proto.open, send: proto.send, header: proto.setRequestHeader};
        const sessions = new Map(), uploads = [], pending = new Map(), completed = new Set(), scanPending = new Set(), failures = new Map(), chunks = [];
        function reply(request, status, body) {
          Object.defineProperty(request, 'status', {configurable: true, value: status});
          Object.defineProperty(request, 'responseText', {configurable: true, value: JSON.stringify(body)});
          queueMicrotask(() => request.dispatchEvent(new ProgressEvent('load')));
        }
        proto.open = function(method, url, ...args) {
          if (url.includes('/api/upload')) this.listingTest = {method, url, headers: {}};
          else return original.open.call(this, method, url, ...args);
        };
        proto.setRequestHeader = function(name, value) {
          if (this.listingTest) this.listingTest.headers[name] = value;
          else original.header.call(this, name, value);
        };
        proto.send = function(data) {
          if (!this.listingTest) return original.send.call(this, data);
          const {method, url, headers} = this.listingTest;
          if (method === 'GET') reply(this, 404, {});
          else if (method === 'POST' && url.endsWith('/upload-sessions')) {
            const meta = JSON.parse(data); sessions.set(meta.id, meta);
            reply(this, 200, {offset: 0, chunkBytes: 1024 * 1024});
          } else if (method === 'PUT') {
            const meta = sessions.get(url.split('/').pop());
            data.arrayBuffer().then(buffer => {
              chunks.push({name: meta.name, bytes: Array.from(new Uint8Array(buffer))});
              reply(this, 200, {offset: Number(headers['Upload-Offset']) + data.size});
            });
          } else if (method === 'POST' && url.endsWith('/upload')) {
            const meta = sessions.get(JSON.parse(data).uploadSessionId);
            uploads.push({method, url, headers, meta});
            const finish = () => {
              const fail = failures.get(meta.name);
              if (fail) {failures.delete(meta.name); reply(this, fail.status, fail.body);}
              else reply(this, 200, {status: scanPending.has(meta.name) ? 'pending' : 'approved', url: 'https://example.test/' + meta.name});
            };
            if (completed.has(meta.name)) finish();
            else pending.set(meta.name, finish);
          } else throw new Error('Unexpected listing upload request');
        };
        window.listingUploadTest = {
          json: () => JSON.stringify(uploads),
          chunksJson: () => JSON.stringify(chunks),
          failOnce: (name, status, body) => failures.set(name, {status, body: JSON.parse(body)}),
          markPending: name => scanPending.add(name),
          complete: name => { completed.add(name); const finish = pending.get(name);
            if (finish) {pending.delete(name); finish();} },
          restore: () => {proto.open = original.open; proto.send = original.send;
            proto.setRequestHeader = original.header; delete window.listingUploadTest;}
        };
      })();
    '''
    ]);
    _server = js.context['listingUploadTest'] as js.JsObject;
  }

  List<Map<String, dynamic>> get records => [
        for (final record
            in jsonDecode(_server.callMethod('json') as String) as List)
          Map<String, dynamic>.from(record as Map),
      ];

  List<Map<String, dynamic>> get chunks => [
        for (final chunk
            in jsonDecode(_server.callMethod('chunksJson') as String) as List)
          Map<String, dynamic>.from(chunk as Map),
      ];

  List<http.Request> get requests {
    return [
      for (final record in records)
        http.Request(
            record['method'] as String, Uri.parse(record['url'] as String))
          ..headers.addAll(Map<String, String>.from(record['headers'] as Map))
          ..body =
              '${(record['meta']['fields'] as Map).entries.map((entry) => 'name="${entry.key}"\r\n\r\n${entry.value}\r\n').join()}'
                  'filename="${record['meta']['name']}"',
    ];
  }

  void complete(String name) => _server.callMethod('complete', [name]);
  void failOnce(String name, int status, Map<String, dynamic> body) =>
      _server.callMethod('failOnce', [name, status, jsonEncode(body)]);
  void markPending(String name) => _server.callMethod('markPending', [name]);
  void dispose() => _server.callMethod('restore');
}
