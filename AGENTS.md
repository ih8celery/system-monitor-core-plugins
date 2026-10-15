# Project Instructions for AI Agents

The SystemBar tabs (Power, Dev, Memory, Disk, Network, CPU), moved out of
`~/proj/swift-ui-system-monitor` with their history. Tab work is tracked in this repo's Beads;
work on the app or the SDK is tracked in that repo's Beads, and an issue here that waits on one
there names it in its description.

- `scripts/test.sh` is the check: every tab's tests in one process, every tab loaded by the
  installed app's loader, then the installer against a temporary folder. `SYSTEMBAR_APP` points it
  at another app build.
- Tabs see only the SDK's public interface (`SystemBarKit.swiftinterface` in the app). A test
  writes a feed through `Feed.forTesting`, never `send`, which is the host's.
- `Tests/TestSupport.swift` holds the helpers every tab's tests share; a helper one tab uses
  belongs in that tab's tests.
- A new tab joins `ALL_TABS` in `scripts/systembar.sh` (and `DEFAULT_TABS` if it installs by
  default), `Tests/TestMain.swift`, and the expected lines in `scripts/test.sh`.
- Two names in a tab's `Info.plist` and code must be unique to it across every loaded bundle:
  `CFBundleExecutable` (its module name) and its `@objc(...)` class name.
- Subprocesses go through `HostServices.run`: an explicit executable path and an argument array,
  never a shell.
- The installer never touches the real `plugins.json` in tests: `SYSTEMBAR_PLUGINS_DIR`,
  `SYSTEMBAR_PLUGINS_FILE`, `CORE_PLUGINS_PREBUILT` and `CORE_PLUGINS_RELAUNCH` redirect it.
