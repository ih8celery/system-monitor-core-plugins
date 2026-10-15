# SystemBar core plugins

The tabs that used to ship inside [SystemBar](https://github.com/ih8celery/swift-ui-system-monitor): Memory, Disk, Network
and CPU, plus Power and Dev, which are kept and tested but not installed by default. Each is an
ordinary SystemBar plugin, built against the SDK inside the installed app and installed into
SystemBar's plugin folder like any other.

## The tabs

| Tab | What it shows |
|---|---|
| **CPU** | Total load, process count, a 90-second history graph, the GPU's device, renderer and tiler utilisation with its own graph, 1, 5 and 15-minute load averages and uptime, and the top processes by CPU with their memory; it can send a notification when CPU stays high or the Mac turns hot |
| **Memory** | Used and available the way Activity Monitor counts them, the kernel's pressure level, the wired/active/inactive/compressed/free/other breakdown (it adds up to the machine's memory), swap and, while it is moving, how much was swapped in and out in the last minute, a graph of the last 15 minutes of memory used coloured by pressure (filled in the background, so it is full when you open the tab), optional notifications for rising pressure and heavy swapping (see Memory notifications below), how much memory the GPU holds (how busy it is lives on the CPU tab), and top processes by memory |
| **Disk** | Free and used space per volume, Time Machine local snapshots, a map of which folders hold the space, and what grew or shrank over the last day or week, measured by scans that run in the background and saved between launches, every number stamped with its age, and a read/write speed graph of the internal disk for the last two minutes (the tab reads the counters itself, in process, every second while it shows and every 5 s while hidden, so the graph is already full when you open it). The headline is free space as Finder shows it (`volumeAvailableCapacityForImportantUsageKey`, which counts purgeable space as available), with "of which X purgeable" underneath; the capacity bar splits Used, Purgeable and Free, and the folder map below it still counts purgeable space as used, because it is on the disk |
| **Network** | Live up/down bandwidth with the totals received and sent since the Mac started up, the Wi-Fi signal with a good/fair/poor verdict (hidden when Wi-Fi is off or not joined to a network), latency to the router and to the internet with failed pings marked in red, which processes are talking and where to, and an on-demand speed test |
| **Power** (not installed by default) | Battery and power source, the sleep assertions keeping your Mac awake with their likely causes, a graph of the Mac's power draw over the last hour or day (filled in the background and saved between launches, with gaps where the Mac slept or SystemBar was closed), and optional notifications for a low battery and for a charger that is not charging (see Power notifications below) |
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

## Memory notifications

The Memory tab posts a macOS notification when memory pressure rises into Warning or Critical (each fires once on the rise, and again only after pressure has dropped to Normal), and when swapping holds at or above a rate for a whole stretch of minutes (every sample-to-sample rate at or above it, up to a tenth of the window allowed to be quiet, so a single burst or a gap such as sleep does not count; once, and again only after it has lapsed). SystemBar keeps one notification per rule per hour. Both rules are on by default; set these in the tab's `settings` in `plugins.json`:

| Key | Meaning | Default |
|---|---|---|
| `notifyPressure` | `false` turns off the Warning and Critical notifications | `true` |
| `notifySwap` | `false` turns off the heavy-swapping notification | `true` |
| `swapMegabytesPerMinute` | Data swapped in plus out, in MB per minute (1024-based), that swapping must hold for the whole window to count as heavy; 1 to 1000000 | `100` |
| `swapMinutes` | How long swapping must hold at that rate, in minutes, 1 to 60 | `5` |

A value of the wrong kind or outside its range keeps the default and is named in SystemBar's log.

## Network notifications

The Network tab posts a macOS notification when the internet stops answering its pings for several rounds in a row (once per outage, and again only after a ping has answered), and when the internet ping averages above a limit for a stretch of minutes (once, and again only after the average has dropped back). The pings run every 5 seconds with the window closed, so both rules work while it is. A round with no IPv4 route at all (an IPv6-only network, or no network) is not an outage and never counts. Nor does a run carry across a sleep: failures before the Mac slept and after it woke are not "in a row". SystemBar keeps one notification per rule per hour. Both rules are on by default; set these in the tab's `settings` in `plugins.json`:

| Key | Meaning | Default |
|---|---|---|
| `notifyUnreachable` | `false` turns off the internet-unreachable notification | `true` |
| `unreachablePings` | Failed pings in a row, 5 seconds apart, that count as unreachable; a whole number from 1 to 720 | `3` |
| `notifySlowInternet` | `false` turns off the slow-internet notification | `true` |
| `slowInternetMilliseconds` | The average internet ping, in ms, above which the connection counts as slow; 1 to 10000 | `200` |
| `slowInternetMinutes` | How long that average must hold, in minutes, 1 to 60 | `5` |

A value of the wrong kind or outside its range keeps the default, is named under the tab's latency graph, and is written to SystemBar's log.

## Power notifications

The Power tab posts a macOS notification when the battery drops below a level while the Mac runs on it (once on crossing below, and again only after the battery has climbed 5 points above the level or the charger has been plugged in), and when the Mac is plugged in but not charging while the battery is more than 5 points under the charge limit (100% when no limit is set) for 2 minutes (once, and again only after it charges, is unplugged or reaches that point). The not-charging wait never counts the 90 seconds after the charger comes or goes, while the battery's figures catch up, and a gap such as sleep restarts it, so the brief pauses macOS makes do not fire it; the notification gives the battery driver's `NotChargingReason` when it is not zero. Both rules read the battery driver every 10 seconds with the window closed, so they work while it is. A Mac with no battery never gets either. SystemBar keeps one notification per rule per hour. Both rules are on by default; set these in the tab's `settings` in `plugins.json`:

| Key | Meaning | Default |
|---|---|---|
| `notifyBatteryLow` | `false` turns off the battery-low notification | `true` |
| `batteryLowPercent` | The battery level, in percent, below which it counts as low; a whole number from 1 to 99 | `20` |
| `notifyNotCharging` | `false` turns off the plugged-in-but-not-charging notification | `true` |

A value of the wrong kind or outside its range keeps the default, is named at the foot of the tab, and is written to SystemBar's log.

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
| `/usr/sbin/ioreg` | How much system memory the GPU driver (`AGXAccelerator`) is using and has set aside, for the Memory tab's GPU memory figures; the GPU's device, renderer and tiler utilisation, for the CPU tab's GPU line; the battery driver (`AppleSmartBattery`) for the Power tab's charge state, battery health, cycles, temperature, time remaining and power draw | Every 30s for the Memory tab; every 1s while the CPU tab is showing; every 60s while the Power tab is showing, and the battery driver alone every 10s while it is hidden |
| `/usr/bin/pmset` | Battery state and sleep assertions; thermal and performance warnings; the thermal speed limit | Every 60s for the Power and Dev tabs; every 10s while the CPU tab is showing |
| `/usr/bin/nettop` | Per-process network throughput | Every 30s |
| `/usr/sbin/lsof` | Active TCP connections; listening ports for the Dev tab; working directories of running build/test/bundler processes, to name the project each belongs to | Every 30–60s |
| `/usr/bin/tmutil` | Count of Time Machine local snapshots | Every 30s |
| `/usr/bin/du` | Folder sizes for the Disk tab's map: one level under home, `~/Library`, `/Applications`, `/opt` and `/Library` every 3 hours; under the developer folders (`~/Library/Application Support`, `Containers`, `Group Containers`, `Developer/Xcode`, `~/.cache`, `~/.ollama`, `~/.android`, `~/proj`) and each simulator device every 6 hours | One `du` per folder, on those cadences while the Mac is awake, or all at once on the Disk tab's rescan button |
| `/usr/bin/xcrun` | `simctl list devices -j`, to name each simulator device folder and say when it last booted | Once per simulator scan, every 6 hours |
| `/usr/bin/networkQuality` | Speed test | **Only when you press the button** |

Six things worth calling out:

- **The Dev tab guesses which project a process belongs to, and says so when it cannot.** It reads absolute paths out of a process's command line and walks up to the nearest enclosing `.git` directory, treating that repository as the project. Only paths inside your home directory count, and repositories in hidden directories are ignored, so a tool that installs itself into Git — Homebrew does — cannot pose as a project of yours. Per-project CPU, memory and disk I/O come from two `proc_pid_rusage` reads a second apart across only the processes that matched a category. Anything that cannot be measured that way says "not measurable" rather than showing a zero. When the arguments name nothing — real Swift builds pass relative source paths — one `lsof` call asks for the working directories of the handful of processes actually running, capped at 64 per sample, and the repository they run in names them. Xcode builds are never given a CPU figure at all: the compile jobs are replaced between reads and a finished process's CPU time is gone with it, while the build driver that does survive spends its time waiting on children at a fraction of a percent. A build therefore shows as work being done, with no number attached, and the whole-machine CPU figure at the top of the tab is what reflects its cost.

- **The disk scan reads folder sizes only, and remembers them.** It runs three plans: an overview of the top-level folders every 3 hours, the developer folders every 6 hours, and each iOS simulator device every 6 hours, each folder by its own `du` with a 5-minute cap and each plan capped at 15 minutes, so one huge or unreadable tree costs only its own row. It reads sizes, never file contents, and never deletes anything; the tab has no cleanup hints, only a map of where the space is and what changed. Sizes are saved in `~/Library/Application Support/SystemBar/PluginData/disk/disk-ledger.json`, every sample for two days and then one a day for thirty, so the popover shows the last scan at once with the age of every number, and the Movers list compares today with a day or a week ago. The plans run while the window is closed: the host calls the Disk tab every 15 minutes while it is hidden, waits two minutes after the Mac or its screen wakes, and the tab runs whatever is due. (The activity graph's 5-second read is the tab's own timer, outside that schedule: it has no wake settle and is not in `--list-plugins`. It is one in-process registry read, so it costs next to nothing.) A plan that measured nothing waits its full cadence before trying again, rather than retrying on every call. `"backgroundScans": false` in the tab's settings stops only the scan step of the hidden calls (the low-space warning below still runs); scans still run while the tab shows, and on its rescan button. Because `~/Library/Containers` and `~/Library/Group Containers` are on the list, macOS may ask for Files and Folders permission the first time. A folder it refuses is never recorded as empty: a `du` that fails leaves that folder's earlier size in place, and a root that cannot be listed at all keeps its folders' earlier sizes rather than marking them freed. The footer keeps the last scan's summary when something was not measured.
- **The CPU tab can notify you, and only when something crosses a line.** Two rules, both on by default, both off with `false`: CPU averaging at or above `"cpuAlertPercent"` (1 to 100, default 90) over the last `"cpuAlertMinutes"` (1 to 120, default 5), set with `"cpuAlert"`; and the thermal state reaching serious or critical, set with `"thermalAlert"`. The CPU rule uses the average over the whole window, so a real build with a second or two of dips between jobs still counts and a short burst in an idle window does not, and it needs readings covering the whole window before it can fire. Each rule fires once when its condition is first met and stays quiet while it holds; the CPU average has to fall below the threshold before that rule can fire again, and a Mac that is already hot when the tab loads has not crossed anything. The thermal rule listens for macOS's thermal-change event, so it needs no command and works with the window closed. The CPU rule reads the host's 1-second feed, which today runs only while the window is open, so that rule works only then (a pause in the readings, such as closing the window, restarts its window) until SystemBar's feed runs in the background (SystemBar's H4). A value that is not a number in range (or not true/false) keeps its default and is named in the log. The host also limits how often a notification is shown: one per rule per hour, and five per tab per hour.
- **The Disk tab can warn you when free space runs low.** It compares the free space Finder shows for the startup volume (purgeable space included) with `"lowSpaceGB"` in the tab's settings in `plugins.json`: a number of GB (10⁹ bytes), 10 when absent, and `0` turns the warning off. Anything else keeps 10 and says so in the tab's footer. It sends one notification when free space drops below the limit, not one per reading while it stays there, and it arms again only after free space climbs back above the limit by 10% of it (at least 1 GB), so a disk hovering at the limit does not warn every hour, and tells you if the Mac is already below the limit when SystemBar starts. SystemBar itself shows at most one notification per rule per hour. It checks every 30 s while the tab shows and every 15 min while it is hidden, whatever `"backgroundScans"` says.
- **The Network tab pings two addresses every 5 seconds, even with the window closed.** One ICMP echo goes to your router (the default gateway, read from the routing table) and one to a public address, `1.1.1.1` (Cloudflare) unless `"pingAddress"` in the tab's settings names another IPv4 address; anything else, and any address no host could answer from (0.x, loopback 127.x, multicast, broadcast), is reported and the default kept. The pings are sent from inside the tab over an ICMP datagram socket, so no `ping` subprocess and no root. A ping carries no data about you, but the public address sees one packet from your connection every 5 seconds. Both lines and the failures are on the tab's latency graph: the router answering while the internet does not points at your provider, and both failing points at the Wi-Fi or local network. When the Mac has no IPv4 route to the internet at all (an IPv6-only network, or no network), the kernel refuses the ping at once and the tab says so rather than reporting an outage. With no router found but the internet reachable, as under some full-tunnel VPNs, the internet line carries on and the router figure reads "no router"; if the internet then stops answering, the tab and its notification say no router was found rather than that the router failed.
- **The speed test, the pings and the Network tab's name lookups are the only things that leave your machine.** Pressing the speed-test button runs Apple's built-in `networkQuality`, which measures throughput against Apple's servers (`mensura.cdn-apple.com`). While the Network tab shows, it also asks your DNS resolver for the name of each internet address the Mac is connected to (a reverse lookup), every 30 seconds for any address it has not already named; a name found is remembered, and a miss is asked again after a minute. Nothing else here sends data anywhere; every other reading is computed locally and stays on your Mac. There is no telemetry, analytics, or crash reporting.

SystemBar runs entirely as your user. It never asks for `sudo` or elevated privileges, and these tabs and the host itself launch every subprocess with an explicit executable path and argument array — never through a shell. A loaded plugin is not held to that rule and can run whatever it likes with your privileges, which is why you should only install plugins you trust.

## How often each tab samples

Each interval lives in that tab's plugin, next to the code that uses it. The Power, Disk, Memory and Network tabs' background intervals are pinned by `scripts/test.sh`, so changing one means changing that check too.

| Tab | Its own sampling | While hidden | Where the number lives |
|---|---|---|---|
| Power | `pmset` and `ioreg` every 60s | `ioreg` alone every 10s, for the Mac's draw and the notification rules; one-minute averages of the last 24 h are saved in `~/Library/Application Support/SystemBar/PluginData/power/power-history.json`, so the draw graph is full on open and after a relaunch | `PowerPlugin.refreshInterval` and `PowerPlugin.hiddenInterval` |
| Dev | `ps`, `lsof`, `pmset` and two usage reads a second apart, every 60s | — | `DevSampling` in `Plugins/Dev/Sources/CapacityModels.swift` |
| Memory | Kernel counters and pressure level every 3s; `ioreg` every 30s, only while the tab shows; a graph point about every 10s | A kernel read every 10s, so the pressure graph is full on open | `MemorySampling` in `Plugins/Memory/Sources/MemoryModels.swift` |
| Disk | Volumes and `tmutil` every 30s; the read/write graph's counters read in process through IOKit (no subprocess) every second; the overview scan every 3 h and the developer and simulator scans every 6 h, each folder one `du` capped at 5 min and each plan at 15 min | A call every 15 min that runs the low-space check and, unless `"backgroundScans": false`, whatever scans are due; the activity graph is the tab's own timer, not the host's call, reading the counters every 5 s so it is full on open | `DiskSampling` in `Plugins/Disk/Sources/DiskModels.swift` |
| Network | Pings to the router and the internet every 5s; the Wi-Fi link every 5s; `nettop` and `lsof` every 30s; `networkQuality` only on the button | The pings, every 5s | `NetworkSampling` in `Plugins/Network/Sources/NetworkModels.swift` |
| CPU | Load averages, uptime, thermal state and `pmset -g therm` every 10s; `ioreg` for the GPU line every 1s while showing; the headline, history, cluster bars and user/system split come from the 1-second feed | — | `CPUSampling` in `Plugins/CPU/Sources/CPUModels.swift` |

The shared feeds' intervals are SystemBar's: `HostSamplers.fastInterval` and `HostSamplers.processInterval`.
