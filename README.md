# SystemBar core plugins

The tabs that used to ship inside [SystemBar](https://github.com/ih8celery/swift-ui-system-monitor): Memory, Disk, Network
and CPU, plus Power and Dev, which are kept and tested but not installed by default. Each is an
ordinary SystemBar plugin, built against the SDK inside the installed app and installed into
SystemBar's plugin folder like any other.

## The tabs

| Tab | What it shows |
|---|---|
| **CPU** | Total load, process count, a 90-second history graph, and the top processes by CPU with their memory |
| **Memory** | Used and available the way Activity Monitor counts them, the kernel's pressure level, the wired/active/inactive/compressed/free/other breakdown (it adds up to the machine's memory), swap and, while it is moving, how much was swapped in and out in the last minute, a graph of the last 15 minutes of memory used coloured by pressure (filled in the background, so it is full when you open the tab), how busy the GPU is and how much memory it holds, and top processes by memory |
| **Disk** | Free and used space per volume, Time Machine local snapshots, a map of which folders hold the space, and what grew or shrank over the last day or week, measured by scans that run in the background and saved between launches, every number stamped with its age, and a read/write speed graph of the internal disk for the last two minutes (drawn only while the tab is open). The headline is free space as Finder shows it (`volumeAvailableCapacityForImportantUsageKey`, which counts purgeable space as available), with "of which X purgeable" underneath; the capacity bar splits Used, Purgeable and Free, and the folder map below it still counts purgeable space as used, because it is on the disk |
| **Network** | Live up/down bandwidth, the Wi-Fi signal with a good/fair/poor verdict (hidden on Ethernet), latency to the router and to the internet with failed pings marked in red, which processes are talking and where to, and an on-demand speed test |
| **Power** (not installed by default) | Battery and power source, and the sleep assertions keeping your Mac awake with their likely causes |
| **Dev** (not installed by default) | How much capacity the machine has left, and which projects are using it: one row per project with the kind of expensive work it is running (builds, simulators, test runs, bundlers, automation) and its measured CPU, memory and disk I/O, plus listening ports grouped by the project serving them |

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
bundle inside the app (`{"name": "CPU.bundle"}`) becomes its path entry in the same place, keeping
its `enabled` and `settings`, or is dropped (and named in the output) for a tab not being installed,
since SystemBar no longer ships any tabs of its own. A `plugins.json` that is a symlink stays one.

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

## What the tabs read from your system

It's a system monitor, so it looks at your processes, disks, and network connections. Here is the complete list of what it runs and why — worth reading before you trust any tool like this.

Alongside direct kernel calls (`host_statistics`, `sysctl`, and friends) for CPU, memory, and interface counters, SystemBar shells out to these stock macOS utilities. Every command below starts only while the tab that needs it is showing (a `du` scan or speed test already under way finishes even if you switch away), except where the "While hidden" column of the table further down says a tab keeps sampling with the window closed.

| Command | Used for | How often |
|---|---|---|
| `/bin/ps` | Process list, per-process CPU and memory | Every 10s while the Power, Memory or CPU tab is showing; also every 60s for the Dev tab, with arguments, to work out which project each process belongs to |
| `/usr/sbin/ioreg` | GPU (`AGXAccelerator`) info | Every 30s |
| `/usr/bin/pmset` | Battery state and sleep assertions; thermal and performance warnings; the thermal speed limit | Every 60s for the Power and Dev tabs; every 10s while the CPU tab is showing |
| `/usr/bin/nettop` | Per-process network throughput | Every 30s |
| `/usr/sbin/lsof` | Active TCP connections; listening ports for the Dev tab; working directories of running build/test/bundler processes, to name the project each belongs to | Every 30–60s |
| `/usr/bin/tmutil` | Count of Time Machine local snapshots | Every 30s |
| `/usr/sbin/ioreg` (Disk) | The internal disk's `Bytes (Read)` and `Bytes (Write)` counters from its `IOBlockStorageDriver`, as a plist, for the Disk tab's read/write graph; a mounted disk image or external drive is not counted | Every second, only while the Disk tab is showing |
| `/usr/bin/du` | Folder sizes for the Disk tab's map: one level under home, `~/Library`, `/Applications`, `/opt` and `/Library` every 3 hours; under the developer folders (`~/Library/Application Support`, `Containers`, `Group Containers`, `Developer/Xcode`, `~/.cache`, `~/.ollama`, `~/.android`, `~/proj`) and each simulator device every 6 hours | One `du` per folder, on those cadences while the Mac is awake, or all at once on the Disk tab's rescan button |
| `/usr/bin/xcrun` | `simctl list devices -j`, to name each simulator device folder and say when it last booted | Once per simulator scan, every 6 hours |
| `/usr/bin/networkQuality` | Speed test | **Only when you press the button** |

Four things worth calling out:

- **The Dev tab guesses which project a process belongs to, and says so when it cannot.** It reads absolute paths out of a process's command line and walks up to the nearest enclosing `.git` directory, treating that repository as the project. Only paths inside your home directory count, and repositories in hidden directories are ignored, so a tool that installs itself into Git — Homebrew does — cannot pose as a project of yours. Per-project CPU, memory and disk I/O come from two `proc_pid_rusage` reads a second apart across only the processes that matched a category. Anything that cannot be measured that way says "not measurable" rather than showing a zero. When the arguments name nothing — real Swift builds pass relative source paths — one `lsof` call asks for the working directories of the handful of processes actually running, capped at 64 per sample, and the repository they run in names them. Xcode builds are never given a CPU figure at all: the compile jobs are replaced between reads and a finished process's CPU time is gone with it, while the build driver that does survive spends its time waiting on children at a fraction of a percent. A build therefore shows as work being done, with no number attached, and the whole-machine CPU figure at the top of the tab is what reflects its cost.

- **The disk scan reads folder sizes only, and remembers them.** It runs three plans: an overview of the top-level folders every 3 hours, the developer folders every 6 hours, and each iOS simulator device every 6 hours, each folder by its own `du` with a 5-minute cap and each plan capped at 15 minutes, so one huge or unreadable tree costs only its own row. It reads sizes, never file contents, and never deletes anything; the tab has no cleanup hints, only a map of where the space is and what changed. Sizes are saved in `~/Library/Application Support/SystemBar/PluginData/disk/disk-ledger.json`, every sample for two days and then one a day for thirty, so the popover shows the last scan at once with the age of every number, and the Movers list compares today with a day or a week ago. The plans run while the window is closed: the host calls the Disk tab every 15 minutes while it is hidden, waits two minutes after the Mac or its screen wakes, and the tab runs whatever is due. A plan that measured nothing waits its full cadence before trying again, rather than retrying on every call. `"backgroundScans": false` in the tab's settings stops the hidden calls; scans still run while the tab shows, and on its rescan button. Because `~/Library/Containers` and `~/Library/Group Containers` are on the list, macOS may ask for Files and Folders permission the first time. A folder it refuses is never recorded as empty: a `du` that fails leaves that folder's earlier size in place, and a root that cannot be listed at all keeps its folders' earlier sizes rather than marking them freed. The footer keeps the last scan's summary when something was not measured.
- **The Network tab pings two addresses every 5 seconds, even with the window closed.** One ICMP echo goes to your router (the default gateway, read from the routing table) and one to a public address, `1.1.1.1` (Cloudflare) unless `"pingAddress"` in the tab's settings names another IPv4 address; anything else is reported and the default kept. The pings are sent from inside the tab over an ICMP datagram socket, so no `ping` subprocess and no root. A ping carries no data about you, but the public address sees one packet from your connection every 5 seconds. Both lines and the failures are on the tab's latency graph: the router answering while the internet does not points at your provider, and both failing points at the Wi-Fi or local network. With no IPv4 default route at all (an IPv6-only network, or no network), nothing is pinged and the tab says so rather than reporting an outage.
- **The speed test and the pings are the only things that leave your machine.** Pressing the speed-test button runs Apple's built-in `networkQuality`, which measures throughput against Apple's servers (`mensura.cdn-apple.com`). Nothing else here sends data anywhere; every other reading is computed locally and stays on your Mac. There is no telemetry, analytics, or crash reporting.

SystemBar runs entirely as your user. It never asks for `sudo` or elevated privileges, and these tabs and the host itself launch every subprocess with an explicit executable path and argument array — never through a shell. A loaded plugin is not held to that rule and can run whatever it likes with your privileges, which is why you should only install plugins you trust.

## How often each tab samples

Each interval lives in that tab's plugin, next to the code that uses it. The Disk, Memory and Network tabs' background intervals are pinned by `scripts/test.sh`, so changing one means changing that check too.

| Tab | Its own sampling | While hidden | Where the number lives |
|---|---|---|---|
| Power | `pmset` every 60s | — | `PowerPlugin.refreshInterval` |
| Dev | `ps`, `lsof`, `pmset` and two usage reads a second apart, every 60s | — | `DevSampling` in `Plugins/Dev/Sources/CapacityModels.swift` |
| Memory | Kernel counters and pressure level every 3s; `ioreg` every 30s; a graph point about every 10s | A kernel read every 10s, so the pressure graph is full on open | `MemorySampling` in `Plugins/Memory/Sources/MemoryModels.swift` |
| Disk | Volumes and `tmutil` every 30s; the read/write graph's `ioreg` every second; the overview scan every 3 h and the developer and simulator scans every 6 h, each folder one `du` capped at 5 min and each plan at 15 min | A due check every 15 min, unless `"backgroundScans": false` | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
| Network | Pings to the router and the internet every 5s; the Wi-Fi link every 5s; `nettop` and `lsof` every 30s; `networkQuality` only on the button | The pings, every 5s | `NetworkSampling` in `Plugins/Network/Sources/NetworkModels.swift` |
| CPU | Load average, thermal state and `pmset -g therm` every 10s; the headline, history, cluster bars and user/system split come from the 1-second feed | — | `CPUSampling` in `Plugins/CPU/Sources/CPUModels.swift` |

The shared feeds' intervals are SystemBar's: `HostSamplers.fastInterval` and `HostSamplers.processInterval`.
