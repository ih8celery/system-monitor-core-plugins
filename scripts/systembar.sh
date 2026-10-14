# Sourced by the other scripts: where SystemBar is, and how to build a tab against it.
#
# SYSTEMBAR_APP is the app whose SDK the tabs build against and which loads them (default: the
# installed one). SYSTEMBAR_REPO is SystemBar's source folder, used only for build-plugin.sh
# when the app is too old to carry its own copy.

app="${SYSTEMBAR_APP:-$HOME/Applications/SystemBar.app}"
systembar_repo="${SYSTEMBAR_REPO:-$HOME/proj/swift-ui-system-monitor}"
sdk="$app/Contents/Resources/SDK"
libs="$app/Contents/Frameworks"

# Every tab in this repo, and the ones installed when none are named. Power and Dev are kept and
# tested but not installed by default.
ALL_TABS=(Power Dev Memory Disk Network CPU)
DEFAULT_TABS=(Memory Disk Network CPU)

die() {
  echo "$1" >&2
  exit 1
}

require_app() {
  [[ -f "$sdk/SystemBarKit.swiftinterface" ]] ||
    die "No SystemBar SDK at $sdk; install SystemBar or set SYSTEMBAR_APP."
}

build_plugin_script() {
  if [[ -x "$app/Contents/Resources/build-plugin.sh" ]]; then
    echo "$app/Contents/Resources/build-plugin.sh"
  elif [[ -x "$systembar_repo/build-plugin.sh" ]]; then
    echo "$systembar_repo/build-plugin.sh"
  else
    die "No build-plugin.sh in $app or $systembar_repo; set SYSTEMBAR_REPO to SystemBar's source folder."
  fi
}

# Usage: check_tab_names <name>...  Refuses a name that is not one of this repo's tabs.
check_tab_names() {
  local name
  for name in "$@"; do
    (( ${ALL_TABS[(Ie)$name]} )) || die "No tab called $name here; the tabs are: ${ALL_TABS[*]}"
  done
}
