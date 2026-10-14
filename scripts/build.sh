#!/bin/zsh
# Builds tabs into build/PlugIns/<Name>.bundle against SystemBar's SDK, the way any plugin is.
#
#   scripts/build.sh [Name...]     every tab when none are named
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/systembar.sh
require_app

tabs=("$@")
(( ${#tabs[@]} > 0 )) || tabs=("${ALL_TABS[@]}")
check_tab_names "${tabs[@]}"
script=$(build_plugin_script)

mkdir -p build/PlugIns
for name in "${tabs[@]}"; do
  "$script" "Plugins/$name" "build/PlugIns/$name.bundle" "$app" > /dev/null
done
echo "Built ${tabs[*]} into $(pwd)/build/PlugIns"
