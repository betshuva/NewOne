#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
flutter_dir="${FLUTTER_APP_DIR:-$project_dir/flutter_app}"
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
for entry_file in index.html flutter_bootstrap.js home.html home.css home.js entry-route.js; do
  sed -i "s/__BETSHUVA_BUILD_ID__/$build_id/g" "$build_dir/$entry_file"
done
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
  "$build_dir/home.html" \
  "$build_dir/home.css" \
  "$build_dir/home.js" \
  "$build_dir/entry-route.js" \
  .
cp -a \
  "$flutter_dir/web/firebase-messaging-sw.js" \
  "$flutter_dir/web/manifest.json" \
  .
rm -f flutter_service_worker.js
node - "$build_id" <<'NODE'
const fs = require('node:fs');
const version = JSON.parse(fs.readFileSync('version.json', 'utf8'));
version.web_build_id = process.argv[2];
fs.writeFileSync('version.json.next', JSON.stringify(version, null, 2) + '\n');
fs.renameSync('version.json.next', 'version.json');
NODE
printf '%s' "$build_id" > .last_build_id.next
mv .last_build_id.next .last_build_id

echo "Web deployment completed: https://betshuva.com/betshuva-app/"
