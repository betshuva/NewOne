import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:web/web.dart' as web;

Widget locationMapEmbed(Uri url) => HtmlElementView.fromTagName(
      tagName: 'iframe',
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      onElementCreated: (element) {
        final frame = element as web.HTMLIFrameElement;
        frame.src = url.toString();
        frame.title = 'מפת המיקום המשותף';
        frame.loading = 'lazy';
        frame.referrerPolicy = 'no-referrer';
        frame.style
          ..border = '0'
          ..width = '100%'
          ..height = '100%'
          ..pointerEvents = 'none';
      },
    );
