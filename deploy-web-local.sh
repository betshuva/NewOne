#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flutter_dir="$project_dir/flutter_app"
flutter_bin="/home/yaniv/flutter-sdk/bin/flutter"
build_dir="$flutter_dir/build/web"

export PATH="/home/yaniv/.local/bin:$PATH"

if [[ ! -x "$flutter_bin" ]]; then
  echo "Flutter was not found at $flutter_bin" >&2
  exit 1
fi

cd "$flutter_dir"
"$flutter_bin" pub get
"$flutter_bin" build web --release --base-href "/betshuva-app/"

cd "$project_dir"
rm -rf assets canvaskit icons
cp -a "$build_dir/assets" "$build_dir/canvaskit" "$build_dir/icons" .
cp -a \
  "$build_dir/flutter.js" \
  "$build_dir/index.html" \
  "$build_dir/flutter_bootstrap.js" \
  "$build_dir/flutter_service_worker.js" \
  "$build_dir/firebase-messaging-sw.js" \
  "$build_dir/main.dart.js" \
  "$build_dir/manifest.json" \
  .

echo "Web deployment completed: https://betshuva.com/betshuva-app/"
