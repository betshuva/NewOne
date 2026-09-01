#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flutter_dir="$project_dir/flutter_app"
flutter_bin="${FLUTTER_BIN:-/home/yaniv/flutter-sdks/flutter-3.47.1/bin/flutter}"
build_dir="$flutter_dir/build/web"

export PATH="/home/yaniv/.local/bin:$PATH"

if [[ ! -x "$flutter_bin" ]]; then
  echo "Flutter was not found at $flutter_bin" >&2
  exit 1
fi

cd "$flutter_dir"
"$flutter_bin" build web --release --no-pub --no-wasm-dry-run --base-href "/betshuva-app/"

# One stable cache key per deployment lets browsers reuse parsed/compiled
# JavaScript across reloads while still invalidating every new release.
build_id="$(date -u +%Y%m%d%H%M%S)"
sed -i -E \
  "s/(flutter_bootstrap\.js\?v=)(__BETSHUVA_BUILD_ID__|[0-9]+)/\1$build_id/g" \
  "$build_dir/index.html"
sed -i -E \
  "s/(main\.dart\.js\?v=)(__BETSHUVA_BUILD_ID__|[0-9]+)/\1$build_id/g" \
  "$build_dir/flutter_bootstrap.js"

cd "$project_dir"
rm -rf assets canvaskit icons
cp -a "$build_dir/assets" "$build_dir/canvaskit" "$build_dir/icons" .
cp -a \
  "$build_dir/flutter.js" \
  "$build_dir/index.html" \
  "$build_dir/flutter_bootstrap.js" \
  "$build_dir/main.dart.js" \
  .
cp -a \
  "$flutter_dir/web/firebase-messaging-sw.js" \
  "$flutter_dir/web/manifest.json" \
  .
rm -f flutter_service_worker.js
printf '%s' "$build_id" > .last_build_id

echo "Web deployment completed: https://betshuva.com/betshuva-app/"
