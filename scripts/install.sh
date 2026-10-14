#!/bin/zsh
# Builds tabs, installs them into SystemBar's plugin folder, and lists them in plugins.json by
# path, the way any outside plugin is installed.
#
#   scripts/install.sh install [Name...]     default: Memory Disk Network CPU
#   scripts/install.sh uninstall [Name...]   default: every tab in this repo
#
# Installing also drops plugins.json entries that name one of these tabs as a bundle inside the
# app ({"name": "CPU.bundle"}): SystemBar no longer ships them, so such an entry is only an error
# tab. A path entry already in the list is left as it is, so edits such as "enabled" survive.
#
# SYSTEMBAR_APP, SYSTEMBAR_REPO, SYSTEMBAR_PLUGINS_DIR and SYSTEMBAR_PLUGINS_FILE move what it
# touches (the last two are names SystemBar itself reads). CORE_PLUGINS_PREBUILT takes bundles
# from a folder instead of building them, and CORE_PLUGINS_RELAUNCH replaces the relaunch; the
# tests use both.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/systembar.sh

SYSTEMBAR_LABEL="com.ih8celery.systembar"
plugins_dir="${SYSTEMBAR_PLUGINS_DIR:-$HOME/Library/Application Support/SystemBar/PlugIns}"
plugins_file="${SYSTEMBAR_PLUGINS_FILE:-$HOME/Library/Application Support/SystemBar/plugins.json}"

# A bundle's path as plugins.json holds it: ~/... under the home folder.
entry_path() {
  local bundle="$plugins_dir/$1.bundle"
  case "$bundle" in
  "$HOME"/*) echo "~/${bundle#"$HOME"/}" ;;
  *) echo "$bundle" ;;
  esac
}

check_plugins_file() {
  jq -e '.plugins | type == "array"' "$plugins_file" > /dev/null 2>&1 ||
    die "$plugins_file is not a plugins list this script can read; fix it by hand first."
}

# SystemBar writes its default list on first use; ask it to, rather than guess at its content.
ensure_plugins_file() {
  if [[ ! -e "$plugins_file" ]]; then
    SYSTEMBAR_PLUGINS_FILE="$plugins_file" "$app/Contents/MacOS/SystemBar" --list-plugins > /dev/null 2>&1 || true
    [[ -e "$plugins_file" ]] || die "SystemBar did not write $plugins_file; open SystemBar once, then install again."
  fi
  check_plugins_file
}

# Usage: rewrite_plugins_file <jq filter> [jq args...]
rewrite_plugins_file() {
  local filter="$1" tmp="$plugins_file.core-plugins.tmp"
  shift
  if jq "$@" "$filter" "$plugins_file" > "$tmp" && mv -f "$tmp" "$plugins_file"; then
    return 0
  fi
  rm -f "$tmp"
  die "Could not rewrite $plugins_file."
}

# The JSON array of {name, path} for the given tabs, for jq.
tab_list() {
  local name pairs=()
  for name in "$@"; do
    pairs+=("$name" "$(entry_path "$name")")
  done
  jq -n '[$ARGS.positional | _nwise(2) | {name: "\(.[0]).bundle", path: .[1]}]' --args "${pairs[@]}"
}

relaunch() {
  if [[ -n "${CORE_PLUGINS_RELAUNCH:-}" ]]; then
    "$CORE_PLUGINS_RELAUNCH"
    return
  fi
  if launchctl print "gui/$(id -u)/$SYSTEMBAR_LABEL" > /dev/null 2>&1; then
    if launchctl kickstart -k "gui/$(id -u)/$SYSTEMBAR_LABEL"; then
      echo "Relaunched SystemBar."
    else
      echo "The tabs are installed, but SystemBar could not be relaunched; open its window and press Relaunch."
    fi
  else
    echo "Open SystemBar's window and press Relaunch to load the change."
  fi
}

# Builds the tabs into $1, or copies them there from CORE_PLUGINS_PREBUILT.
stage_tabs() {
  local stage="$1" name script
  shift
  if [[ -n "${CORE_PLUGINS_PREBUILT:-}" ]]; then
    for name in "$@"; do
      [[ -d "$CORE_PLUGINS_PREBUILT/$name.bundle" ]] || die "No $name.bundle in $CORE_PLUGINS_PREBUILT."
      cp -R "$CORE_PLUGINS_PREBUILT/$name.bundle" "$stage/"
    done
    return
  fi
  require_app
  script=$(build_plugin_script)
  for name in "$@"; do
    "$script" "Plugins/$name" "$stage/$name.bundle" "$app" > /dev/null ||
      die "The $name tab did not build; the compiler's output above says why."
  done
}

install_tabs() {
  local stage name
  ensure_plugins_file
  stage=$(mktemp -d)
  trap "rm -rf '$stage'" EXIT
  stage_tabs "$stage" "$@"
  mkdir -p "$plugins_dir"
  for name in "$@"; do
    rm -rf "$plugins_dir/$name.bundle"
    mv -f "$stage/$name.bundle" "$plugins_dir/$name.bundle"
  done
  # A tab's old name entry becomes its path entry in the same place, so the tab order holds;
  # every other name entry for a tab of this repo goes; a tab with no entry yet goes at the end.
  rewrite_plugins_file '
    ($tabs | map({key: .name, value: .path}) | from_entries) as $wanted
    | ($all | map("\(.).bundle")) as $ours
    | def listed($p): any(.[]; .path == $p);
      .plugins |= (
        reduce .[] as $entry ([];
          if ($entry | has("name")) and ($ours | index($entry.name)) != null then
            ($wanted[$entry.name]) as $p
            | if $p != null and (listed($p) | not) then . + [{path: $p}] else . end
          elif ($entry | has("path")) and ([$wanted[]] | index($entry.path)) != null and listed($entry.path) then .
          else . + [$entry] end)
        | reduce $tabs[].path as $p (.; if listed($p) then . else . + [{path: $p}] end))' \
    --argjson tabs "$(tab_list "$@")" --argjson all "$(jq -n '$ARGS.positional' --args "${ALL_TABS[@]}")"
  echo "Installed $* into $plugins_dir."
  relaunch
}

uninstall_tabs() {
  local name
  [[ ! -e "$plugins_file" ]] || check_plugins_file
  for name in "$@"; do
    rm -rf "$plugins_dir/$name.bundle"
  done
  if [[ -e "$plugins_file" ]]; then
    rewrite_plugins_file '($tabs | map(.path)) as $paths | .plugins |= map(select((.path // null) as $p | $paths | index($p) | not))' \
      --argjson tabs "$(tab_list "$@")"
  fi
  echo "Removed $*."
  relaunch
}

action="${1:-}"
(( $# > 0 )) && shift
tabs=("$@")
case "$action" in
install)
  (( ${#tabs[@]} > 0 )) || tabs=("${DEFAULT_TABS[@]}")
  check_tab_names "${tabs[@]}"
  install_tabs "${tabs[@]}"
  ;;
uninstall)
  (( ${#tabs[@]} > 0 )) || tabs=("${ALL_TABS[@]}")
  check_tab_names "${tabs[@]}"
  uninstall_tabs "${tabs[@]}"
  ;;
*)
  echo "usage: scripts/install.sh install|uninstall [Name...]" >&2
  exit 64
  ;;
esac
