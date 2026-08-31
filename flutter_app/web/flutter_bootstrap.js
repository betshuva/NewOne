{{flutter_js}}
{{flutter_build_config}}

// Never let an old Flutter bundle survive a deployment. The app intentionally
// does not use Flutter's deprecated service worker; Firebase push registers its
// own worker separately from index.html.
for (const build of _flutter.buildConfig.builds) {
  if (build.mainJsPath === 'main.dart.js') {
    build.mainJsPath = `main.dart.js?v=${Date.now()}`;
  }
}

_flutter.loader.load();
