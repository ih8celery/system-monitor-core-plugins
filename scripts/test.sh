#!/bin/zsh
# Every tab's tests in one process, then every tab built and loaded by SystemBar's real loader,
# then the installer against a temporary plugins folder. Needs Xcode's swiftc and SystemBar.app.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/systembar.sh
require_app

# 1. Each tab's sources and tests, plus the shared helpers, compiled the way build-plugin.sh
#    compiles a tab: the target and language mode the SDK records, its public interface only.
flags=$(grep -m1 '^// swift-module-flags:' "$sdk/SystemBarKit.swiftinterface" || true)
target=$(sed -nE 's/.* -target ([^ ]+).*/\1/p' <<< "$flags")
swift_version=$(sed -nE 's/.* -swift-version ([^ ]+).*/\1/p' <<< "$flags")
[[ -n "$target" && -n "$swift_version" ]] ||
  die "Could not read -target and -swift-version from $sdk/SystemBarKit.swiftinterface"

mkdir -p build
swiftc \
  -D TESTING \
  -parse-as-library -module-name CorePluginTests \
  -swift-version "$swift_version" -target "$target" \
  -module-cache-path build/module-cache \
  -I "$sdk" -L "$libs" -lSystemBarKit \
  -Xlinker -rpath -Xlinker "$libs" \
  -framework SwiftUI -framework AppKit \
  -o build/CorePluginTests \
  $(find Plugins -path '*/Sources/*.swift' -o -path '*/Tests/*.swift' | sort) \
  Tests/*.swift
build/CorePluginTests

# 2. Every tab as a bundle, loaded by the app's own loader from a temporary list. The Disk line
#    pins its background interval, which the host reports.
rm -rf build/PlugIns
scripts/build.sh > /dev/null
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jq -n --arg dir "$PWD/build/PlugIns" '{plugins: [$ARGS.positional[] | {path: "\($dir)/\(.).bundle"}]}' \
  --args "${ALL_TABS[@]}" > "$tmp/plugins.json"
b="$PWD/build/PlugIns"
expected="ok power Power $b/Power.bundle
ok dev Dev $b/Dev.bundle
ok memory Memory $b/Memory.bundle background every 10s
ok disk Disk $b/Disk.bundle background every 900s
ok network Network $b/Network.bundle
ok cpu CPU $b/CPU.bundle"
actual=$(SYSTEMBAR_PLUGINS_FILE="$tmp/plugins.json" SYSTEMBAR_PLUGIN_DATA_ROOT="$tmp/plugin-data" \
  "$app/Contents/MacOS/SystemBar" --list-plugins) || die "Load check failed: SystemBar --list-plugins exited $?"
if [[ "$actual" != "$expected" ]]; then
  echo "Load check failed. Expected:" >&2
  echo "$expected" >&2
  echo "Got:" >&2
  echo "$actual" >&2
  exit 1
fi
echo "Load check passed: every tab builds against the app's SDK and loads through its loader"

# 3. The installer, against a temporary folder and list.
SYSTEMBAR_APP="$app" scripts/test-install.sh "$PWD/build/PlugIns"
