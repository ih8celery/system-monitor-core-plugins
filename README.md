# SystemBar core plugins

The tabs that used to ship inside [SystemBar](../swift-ui-system-monitor): Memory, Disk, Network
and CPU, plus Power and Dev, which are kept and tested but not installed by default. Each is an
ordinary SystemBar plugin, built against the SDK inside the installed app and installed into
SystemBar's plugin folder like any other.

## Install

```bash
scripts/install.sh install              # Memory, Disk, Network, CPU
scripts/install.sh install Power Dev    # add tabs left out by default
scripts/install.sh uninstall Power      # remove one; with no names, removes every tab from here
```

Installing builds each tab against `~/Applications/SystemBar.app`, puts it in
`~/Library/Application Support/SystemBar/PlugIns/<Name>.bundle`, lists it in `plugins.json` by
path, and relaunches SystemBar. A path entry already in the list is kept as it is, so turning a
tab off with `"enabled": false` survives a reinstall. An old entry naming one of these tabs as a
bundle inside the app (`{"name": "CPU.bundle"}`) becomes its path entry in the same place, or is
dropped for a tab not being installed, since SystemBar no longer ships any tabs of its own.

Each tab keeps what it saves in `~/Library/Application Support/SystemBar/PluginData/<id>/`, as
before; the move does not touch it.

## Develop

```bash
scripts/test.sh     # every tab's tests, every tab loaded by the app's loader, the installer
scripts/build.sh    # every tab (or the ones named) into build/PlugIns/
```

Both use the installed app. Set `SYSTEMBAR_APP` to test against another build, such as
`../swift-ui-system-monitor/SystemBar.app` while changing the SDK. Building needs SystemBar's
`build-plugin.sh`: the app carries a copy, and an older app falls back to the one in
`SYSTEMBAR_REPO` (default `~/proj/swift-ui-system-monitor`).

`~/Applications/SystemBar.app/Contents/MacOS/SystemBar --preview build/PlugIns/Disk.bundle --png disk.png`
saves a picture of one tab
without installing it.

## Sampling intervals

A tab's intervals live in its plugin: `refreshInterval`, and slower cadences in its
`<Name>Sampling` enum. The Disk tab samples in the background every 900 seconds
(`backgroundInterval`); `scripts/test.sh` pins the line SystemBar reports for it.
