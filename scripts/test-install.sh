#!/bin/zsh
# Checks scripts/install.sh against a temporary plugins folder and plugins.json, never the real
# ones. Bundles come prebuilt from the folder in $1 (test.sh builds them once), so this only
# checks what the installer copies and how it rewrites plugins.json.
#
#   scripts/test-install.sh <folder of built .bundle>
set -euo pipefail

cd "$(dirname "$0")/.."
prebuilt="${1:?usage: scripts/test-install.sh <folder of built .bundle>}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export SYSTEMBAR_PLUGINS_DIR="$tmp/PlugIns"
export SYSTEMBAR_PLUGINS_FILE="$tmp/plugins.json"
export CORE_PLUGINS_PREBUILT="$prebuilt"
export CORE_PLUGINS_RELAUNCH=true

failures=0
fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# The plugins list as one compact line, for comparing.
plugins() { jq -c '.plugins' "$SYSTEMBAR_PLUGINS_FILE"; }
path_entry() { printf '{"path":"%s"}' "$SYSTEMBAR_PLUGINS_DIR/$1.bundle"; }
installed() { ls "$SYSTEMBAR_PLUGINS_DIR" 2>/dev/null | tr '\n' ' '; }

backup='{"path":"~/Library/Application Support/SystemBar/PlugIns/SystemBackupTab.bundle","settings":{"command":"/x/backup"}}'
four="$(path_entry Memory),$(path_entry Disk),$(path_entry Network),$(path_entry CPU)"

# 1. A file from when SystemBar shipped the tabs: each name entry becomes a path entry in its
#    place, Power and Dev's entries go, and an entry from another project is left alone.
cat > "$SYSTEMBAR_PLUGINS_FILE" <<JSON
{ "plugins": [
  { "name": "Power.bundle" }, { "name": "Dev.bundle" }, { "name": "Memory.bundle" },
  { "name": "Disk.bundle" }, { "name": "Network.bundle" }, { "name": "CPU.bundle" },
  $backup
] }
JSON
scripts/install.sh install > /dev/null
[[ "$(plugins)" == "[$four,$backup]" ]] || fail "migration: got $(plugins)"
[[ "$(installed)" == "CPU.bundle Disk.bundle Memory.bundle Network.bundle " ]] || fail "migration installed: $(installed)"

# 2. Installing again changes nothing.
before=$(plugins)
scripts/install.sh install > /dev/null
[[ "$(plugins)" == "$before" ]] || fail "second install changed the list: $(plugins)"

# 3. An entry the person edited keeps its edits.
jq '.plugins[1].enabled = false' "$SYSTEMBAR_PLUGINS_FILE" > "$tmp/edited" && mv -f "$tmp/edited" "$SYSTEMBAR_PLUGINS_FILE"
edited=$(plugins)
scripts/install.sh install > /dev/null
[[ "$(plugins)" == "$edited" ]] || fail "install overwrote an edited entry: $(plugins)"

# 4. A tab left out by default can be installed by name, and goes at the end.
scripts/install.sh install Power > /dev/null
[[ "$(jq -c '.plugins[-1]' "$SYSTEMBAR_PLUGINS_FILE")" == "$(path_entry Power)" ]] || fail "install Power: $(plugins)"
[[ -d "$SYSTEMBAR_PLUGINS_DIR/Power.bundle" ]] || fail "install Power: no bundle"

# 5. Uninstalling one tab removes only its bundle and entry.
scripts/install.sh uninstall Power > /dev/null
[[ "$(plugins)" == "$edited" ]] || fail "uninstall Power: $(plugins)"
[[ ! -e "$SYSTEMBAR_PLUGINS_DIR/Power.bundle" ]] || fail "uninstall Power left its bundle"

# 6. Uninstalling with no names removes every tab from this repo, and nothing else.
scripts/install.sh uninstall > /dev/null
[[ "$(plugins)" == "[$backup]" ]] || fail "uninstall all: $(plugins)"
[[ -z "$(installed)" ]] || fail "uninstall all left: $(installed)"

# 7. A file that is not a plugins list is refused and left as it was.
echo '{ "plugins": "nope" }' > "$SYSTEMBAR_PLUGINS_FILE"
if scripts/install.sh install > /dev/null 2>&1; then fail "a broken plugins.json was accepted"; fi
[[ "$(cat "$SYSTEMBAR_PLUGINS_FILE")" == '{ "plugins": "nope" }' ]] || fail "a broken plugins.json was rewritten"

# 8. A name that is not one of this repo's tabs is refused before anything changes.
echo '{ "plugins": [] }' > "$SYSTEMBAR_PLUGINS_FILE"
if scripts/install.sh install Clock > /dev/null 2>&1; then fail "an unknown tab name was accepted"; fi
[[ "$(plugins)" == "[]" ]] || fail "an unknown tab name changed the list: $(plugins)"

# 9. With no plugins.json yet, SystemBar writes its own default first, then the tabs are added.
#    Whatever that default holds, none of this repo's tabs end up listed by name.
rm -f "$SYSTEMBAR_PLUGINS_FILE"
scripts/install.sh install > /dev/null
[[ "$(jq -c '[.plugins[] | select(.name)]' "$SYSTEMBAR_PLUGINS_FILE")" == "[]" ]] || fail "fresh file kept name entries: $(plugins)"
[[ "$(jq -c '[.plugins[] | select(.path)]' "$SYSTEMBAR_PLUGINS_FILE")" == "[$four]" ]] || fail "fresh file: $(plugins)"

# 10. A name entry's other keys carry over to its path entry, and a dropped entry is reported.
cat > "$SYSTEMBAR_PLUGINS_FILE" <<JSON
{ "plugins": [ { "name": "CPU.bundle", "enabled": false, "settings": { "a": 1 } }, { "name": "Dev.bundle" } ] }
JSON
out=$(scripts/install.sh install CPU)
[[ "$(plugins)" == "[{\"enabled\":false,\"settings\":{\"a\":1},\"path\":\"$SYSTEMBAR_PLUGINS_DIR/CPU.bundle\"}]" ]] ||
  fail "a name entry's keys were lost: $(plugins)"
[[ "$out" == *"Dev.bundle"* ]] || fail "the dropped Dev entry was not reported: $out"

# 11. A plugins.json that is a symlink stays one, and its target is what changes.
echo '{ "plugins": [] }' > "$tmp/real.json"
ln -sf "$tmp/real.json" "$SYSTEMBAR_PLUGINS_FILE"
scripts/install.sh install CPU > /dev/null
[[ -L "$SYSTEMBAR_PLUGINS_FILE" ]] || fail "plugins.json is no longer a symlink"
[[ "$(jq -c '.plugins' "$tmp/real.json")" == "[$(path_entry CPU)]" ]] || fail "the symlink's target was not rewritten: $(cat "$tmp/real.json")"

if (( failures > 0 )); then
  echo "Installer checks failed: $failures" >&2
  exit 1
fi
echo "Installer checks passed: tabs install by path, migrate old name entries, and uninstall cleanly"
