import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Widget locationMapEmbed(Uri url) {
  if (defaultTargetPlatform == TargetPlatform.android &&
      url.scheme == 'https' &&
      url.host == 'www.google.com' &&
      url.port == 443 &&
      url.userInfo.isEmpty &&
      !url.hasFragment &&
      url.path == '/maps' &&
      url.queryParameters['output'] == 'embed' &&
      (url.queryParameters['q']?.trim().isNotEmpty ?? false) &&
      (url.queryParameters['q']?.length ?? 0) <= 500 &&
      url.queryParameters.keys
          .every((key) => const {'q', 'output', 'hl'}.contains(key))) {
    // The card owns gestures and opens the navigation chooser on every tap.
    return ExcludeSemantics(
      child: IgnorePointer(
        child: AndroidView(
          key: ValueKey(url.toString()),
          viewType: 'com.betshuva.app/location-map',
          creationParams: {'url': url.toString()},
          creationParamsCodec: const StandardMessageCodec(),
          layoutDirection: TextDirection.rtl,
        ),
      ),
    );
  }
  return const ColoredBox(
      color: Color(0xFFEAF5FD), child: Center(child: Icon(Icons.map_outlined)));
}
