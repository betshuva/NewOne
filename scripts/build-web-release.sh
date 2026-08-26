#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${FLUTTER_BIN:-flutter}"
web_base="/betshuva-app/"
build_dir="$repo_root/flutter_app/build/web"

cd "$repo_root/flutter_app"
"$flutter_bin" pub get
"$flutter_bin" build web --release --no-wasm-dry-run --base-href "$web_base"

grep -Fq "<base href=\"$web_base\">" "$build_dir/index.html" || {
  echo "ERROR: Flutter web build has an incorrect base href" >&2
  exit 1
}

for required in index.html flutter_bootstrap.js main.dart.js flutter_service_worker.js; do
  test -s "$build_dir/$required" || {
    echo "ERROR: missing web build artifact: $required" >&2
    exit 1
  }
done

cd "$repo_root"
cp -a "$build_dir/assets/." assets/
cp -a "$build_dir/canvaskit/." canvaskit/
cp -a "$build_dir/icons/." icons/
cp "$build_dir/index.html" \
   "$build_dir/flutter.js" \
   "$build_dir/flutter_bootstrap.js" \
   "$build_dir/flutter_service_worker.js" \
   "$build_dir/main.dart.js" \
   "$build_dir/manifest.json" \
   .
cp flutter_app/web/firebase-messaging-sw.js .

grep -Fq "<base href=\"$web_base\">" index.html || {
  echo "ERROR: deployed index.html lost the required base href" >&2
  exit 1
}
grep -Fq 'main.dart.js' flutter_bootstrap.js || {
  echo "ERROR: deployed bootstrap does not load main.dart.js" >&2
  exit 1
}

echo "Web release built and synchronized for $web_base"
