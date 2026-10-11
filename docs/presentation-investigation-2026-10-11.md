# Native Start Dismissal And Command Palette Placement

Local development work for **1.0.4-dev**, based on `e9513a1` / `v1.0.3-dev`.
This report records the pre-publication investigation. See the
[1.0.4-dev release notes](releases/1.0.4-dev.md) for the published scope.
The mod remains one C++ source file.

## Environment And Scope

- Windows 11 build 26340.9616, x64.
- `StartMenu.dll` 2609.14000.0.0, from `MicrosoftWindows.Client.Core_cw5n1h2txyewy`.
- Matching Microsoft public PDB identity: `EC1E6A4D9DFF4FD7A671CBCD1DF6D73F1`.
- Command Palette package `Microsoft.CommandPalette` 0.12.12601.0.
- Actual placement checks: 3440-pixel-wide primary monitor, 96 DPI, palette HWND size 1024 x 768.
- The original `WindhawkToolchain` directory and the existing Git stashes were left untouched.

## Finding The Correct Dismissal Layer

The process loads both the older `StartDocked.dll` and the newer `StartMenu.dll`.
The old Explorer presenter path is not a reliable proxy for the current Start
panel's composition animation. Matching symbols and disassembly of the newer
module exposed a native pair:

```text
winrt::StartMenu::implementation::Animations::AnimationProvider::CreateDismissAnimation()
winrt::StartMenu::implementation::Animations::AnimationProvider::CreateDismissNoAnimation()
```

Both return `winrt::Windows::UI::Composition::ScalarKeyFrameAnimation`.
The inspected callers choose between those factories during dismissal. In this
x64 binary, RCX is the provider object, RDX is caller-owned return storage, and
the returned storage address is returned in RAX. The no-animation variant sets
the final value directly with a 1 ms composition duration. It is not a literal
zero-duration synchronous hide.

The detour uses the identical native ABI and calls the no-animation factory only
when the toggle is enabled and shared `launchInProgress` is set. Otherwise it
calls the original function. Windows retains its normal completion callbacks,
visibility transitions and state machine. No raw PDB offsets, private object
layout offsets, HWND hiding, global animation setting changes or Explorer
presenter calls are used in the implementation.

Both symbols are optional. If the native alternative is missing, the original
animated path remains usable. This is deliberately build-dependent rather than
a claim of universal support. The initialization log reports whether the pair
was found; the runtime log records `selecting native CreateDismissNoAnimation`.

### Hook Lifecycle

The existing module watcher could register hooks after initialization without
explicitly applying them. It now starts in `Wh_ModAfterInit` and calls
`Wh_ApplyHookOperations` only after a newly resolved set. SearchUx and twinui are
attempted independently, so one unloaded DLL cannot starve the other. The
watcher is stopped and joined in `Wh_ModBeforeUninit`, not only after hooks have
already been removed. These boundaries follow the installed Windhawk API header
and [Windhawk's callback documentation](https://github.com/ramensoftware/windhawk/wiki/Creating-a-new-mod#mod-callback-functions).

## Frame-Level Verification

Tests used a disposable input sink, synthetic text that is never executed,
semantic UI Automation coordinates for the search click, and exact text
readback from Command Palette. The clipboard was not modified. The user agreed
not to interact during the retained recordings.

An initial run affected by user interaction was discarded. Full virtual-desktop
recordings also proved unsuitable: despite nominal 60 fps metadata, decoding
showed roughly five distinct frames per second. They are not used as animation
evidence.

The retained recordings instead capture an unobscured 128 x 960 strip at the
left edge of Start. `analyze-start-dismiss.py` correlates a high-contrast border
template vertically and reads actual presentation timestamps from FFmpeg
`showinfo`, rather than assuming a fixed frame rate. It writes the observations
and a contact sheet. A matching animated control is required: absence of detected
motion alone is not sufficient proof. With `--expect`, insufficient stable
tracking, absent disappearance or gaps over 50 ms near the transition fail the
check instead of being reported as success.

| Recording | Confident moving frames | Maximum tracked downward offset | Transition frame gap | Result |
| --- | ---: | ---: | ---: | --- |
| `dismiss-strip-native`, toggle off | 7 | 646 px | 33 ms | Visible downward slide, about 200 ms |
| `dismiss-strip-instant`, typing, toggle on | 0 | 0 px | 17 ms | Stationary at 3.470 s, absent at 3.487 s |
| `dismiss-strip-instant-click`, click without typing | 0 | 0 px | 34 ms | Stationary at 3.733 s, absent at 3.767 s |
| `dismiss-strip-cold-instant`, after host restart | 0 | 0 px | 33 ms | Stationary at 3.533 s, absent at 3.550 s |

The control and enabled contact sheets were visually inspected. The click clip
has a 116 ms gap elsewhere in the recording, but not at dismissal; the table
uses the measured transition interval. The cold-host log confirms that the new
Start process actually called the native no-animation detour.

Only `StartMenuExperienceHost.exe` was deliberately restarted. Explorer kept its
original PID and start time. This is not a full Windows reboot test.

Local evidence stays under ignored `build/dismiss-*/`: `capture.mkv`,
`runtime.txt`, `analysis.json` and `contact-sheet.png`. Raw desktop captures and
DBWIN logs are not committed because they can contain unrelated private data.

## Placement Implementation And Verification

The setting selects native placement, one of nine grid positions, custom
percentages, or horizontal alignment with Start. Monitor selection supports the
PowerToys-selected monitor, the source window, the mouse pointer and the primary
monitor. Margins are scaled to the palette's DPI and coordinates are constrained
to the monitor work area, excluding taskbars.

Follow Start captures the visible `SearchBoxToggleButton` rectangle before
summoning the launcher, on the launch worker with UIA connection/transaction
timeouts. It never performs this lookup in the low-level keyboard callback.
The fullscreen Start HWND and phone companion are not used as an alignment
anchor. With no visible semantic anchor, the mode leaves the palette unchanged.

After input readiness, only a visible, uncloaked foreground
`Microsoft.CmdPal.UI.exe` / `WinUIDesktopWin32WindowClass` is eligible for the
asynchronous `SetWindowPos`. No activation, resize, topmost or z-order change is
requested. A later DPI change can cause at most two additional corrections
within 200 ms while the transaction is alive. There is no perpetual positioning
loop. Native/default positioning adds neither the lookup nor the move.

| Actual preset | Observed top-left | Text readback |
| --- | --- | --- |
| Top left | 16, 16 | Exact |
| Top right | 2400, 16 | Exact |
| Center | 1208, 336 | Exact |
| Bottom right | 2400, 656 | Exact |
| Custom 50% / 25% | 1208, 176 | Exact |
| Follow Start horizontally | 1051, 336 | Exact |

For Follow Start, the semantic search rectangle was `(1195,531)-(1931,567)`;
its center is x=1563. The 1024-pixel-wide palette was correctly placed at
1563 - 512 = 1051. Those coordinates are test observations, not constants in
the mod. The placement harness uses the default 16 DIP margin and 50/25 custom
percentages; change its expectations if testing other values.

The pure geometry tests include all nine grid presets, percent clamping,
negative monitor origins, 200% DPI margins, missing Start, edge clamping,
oversized windows and invalid work areas: **21/21 assertions passed**.

## Regression Results And Limits

- Full desktop suite: **11/11 cases passed**, including Win, Ctrl+Esc and the
  taskbar Start button without redirection, two semantic search clicks without
  typing, Win+S, rapid text, mixed case, digits and accented queries.
- No query text leaked into the disposable previous-window sink in those cases.
- A previous attempt could not focus its test sink and returned `BLOCKED` before
  sending input. It was not counted as a mod pass; the full suite was rerun.
- After restarting Start's host, Start-only, typing, search click and the
  no-animation recording passed again.
- Focused-input observations in the retained runs were about 219-266 ms. Query
  completion includes the time taken to generate the test text. Removing the
  slide does not mean zero activation or input-readiness latency.
- Actual mixed-DPI monitor transfers, all monitor-selector modes, other Windows
  builds, and different PowerToys window/card layouts remain unverified. The
  placement feature moves the whole HWND, not a version-specific internal card.
- The new toggle does not disable all animations system-wide. Outside a launch
  transaction, the original dismissal factory is used.
- On older builds without `StartMenu.dll`, the optional watcher still polls for
  the module; that case was not available for runtime testing here.

The desktop recordings/suite used `1.0.4-dev_630563.dll`. Final review then added
the before-unload watcher join and removed watcher short-circuiting between the
Explorer DLLs. Those lifecycle-only edits were compiled and installed separately;
the desktop suite was not rerun after the user was told the PC was free. Final
source SHA-256: `17BB912DDB81A38461744EE5883BE06AECC9F7903F43391AEEDFF2EAEC7A1BD8`.

Final installation readback: `1.0.4-dev_190534.dll` is loaded in Explorer,
SearchHost and StartMenuExperienceHost, under a single mod registry entry.
`instantStartDismiss=1`, `commandPalettePosition=default`, and both mod logging
and engine logging are off. These observations were recorded before publication.

## Reproducing Tests

Run only on an idle desktop with the user's agreement. These commands operate
real windows; they are not headless unit tests. FFmpeg and Python with NumPy and
Pillow are needed for recordings/analysis. The native harness needs MinGW g++.

```powershell
.\tests\run-runtime-regression.ps1
g++ -std=c++17 -O2 -static -DUNICODE -D_UNICODE tests/palette-placement.cpp -luser32 -o build/palette-placement.exe
.\build\palette-placement.exe

.\tests\set-presentation-test-settings.ps1 -Position topRight
.\build\runtime-regression.exe position-topRight
.\tests\set-presentation-test-settings.ps1 -Restore
```

The settings helper saves its first position/dismissal values in
`build/presentation-settings-backup.json`; `-Restore` restores that snapshot.
Check the snapshot before reusing an old testing directory. It elevates through
UAC if needed. Other launcher settings are not changed.

For animation comparisons, open Start to establish an unobscured recording
region, then close it before the harness runs. Coordinates below belong to the
tested desktop and **must be adapted** for another monitor arrangement. The
recorder builds no binaries; first run the regression script above.

```powershell
.\tests\set-presentation-test-settings.ps1 -Instant 0
.\tests\record-start-dismiss.ps1 -Label control -Left 1130 -Top 430 -Width 128 -Height 960
.\tests\set-presentation-test-settings.ps1 -Instant 1
.\tests\record-start-dismiss.ps1 -Label enabled -Left 1130 -Top 430 -Width 128 -Height 960
python tests/analyze-start-dismiss.py build/dismiss-control/capture.mkv --strip 25 0 48 960 --template-y 70 --expect slide
python tests/analyze-start-dismiss.py build/dismiss-enabled/capture.mkv --strip 25 0 48 960 --template-y 70 --expect instant
.\tests\set-presentation-test-settings.ps1 -Restore
```

Use `-Mode animation-click` for the no-typing click path. Adjust `--reference`
and `--end` if the Start opening or test timing differs. Do not accept an
unobscured-strip result as proof if the animated control cannot track the panel.
