# Runtime investigation, 2026-10-11

## Environment and scope

- Windows 26H2, build 26340.9616; Windhawk 1.7.3.
- `twinui.pcshell.dll` 10.0.26100.8951; `StartDocked.dll` 10.0.26100.9616.
- Command Palette package 0.12.12601.0, process `Microsoft.CmdPal.UI.exe`.
- Starting revision: `1d0a094`, published mod 1.0.2.
- Development version under investigation: 1.0.3-dev, subsequently packaged as
  a pre-release. See [release notes](releases/1.0.3-dev.md).

The instant-dismiss request remains distinct from an external report of
intermittent unwanted Command Palette activation when opening Start. The mod
version and Windows build for that report remain unknown. Local success does
not invalidate it.

## Reproductions and changes

The published version produced an incorrectly ordered query in a controlled
Win+S test: expected `azertyAbC1234567890`, observed `a4ze5rt6yA7bC812930`.
One earlier run was discarded because the user interacted with the desktop.
Further runs were explicitly confirmed interference-free by the user.

Foreground failures were also reproduced: the protocol call succeeded and the
palette appeared visually, but the previous application retained foreground.
Repeated foreground requests failed. A screenshot and debug logs distinguish
this from failure to launch the process.

Changes retained:

1. Capture admission and final empty-buffer completion use the same shared
   mutex. A worker is present even if the launcher was already foreground.
2. UTF-16 is replayed in contiguous `SendInput` batches without per-character
   sleeps. The arbitrary extra 180 ms delay now defaults to zero.
3. Captured key-downs have their key-ups suppressed too. Own injected events
   are excluded by marker, not by a time window that also loses external input.
4. `VK_PACKET` input from automation/accessibility tools is decoded directly.
   Physical layout/modifier translation continues through `ToUnicodeEx`.
5. The shell is not dismissed with Escape before summon. No `AttachThreadInput`,
   root-window `SetFocus`, or topmost toggling is used for activation.
6. A denied activation may use a masked Alt sequence, only with no modifiers
   held. An intermediate implementation did not check Shift; it was corrected
   because Alt+Shift can change the keyboard layout. Win release is also masked
   for an intercepted Win+S.
7. The target must have a responsive matching window before interception.
   `WM_NULL` has a 40 ms deadline and a 200 ms result cache. A hidden/cloaked
   Command Palette is valid for this preflight, but not for replay readiness.
8. Before replay, Command Palette must be foreground, visible, uncloaked and
   have a focused enabled UIA Edit. UIA calls have bounded timeouts. Other
   launchers retain the foreground/GUI-thread focus check.
9. A failed activation allows native search requests for five seconds across
   all injected processes. The failed query itself is not automatically
   recovered. Shared-memory layout was bumped to v7; launch ownership records
   its host PID so a terminated host can be recovered without taking ownership
   from a still-live worker after an arbitrary time limit.

## Runtime evidence

`tests/runtime-regression.cpp` creates a disposable edit control as the previous
foreground window. It checks launcher focus and exact query equality through
UI Automation, and fails if text reaches the disposable control. It never
sends Enter or changes the clipboard. Results and screenshots stay in ignored
`build/`; screenshots are diagnostic snapshots, not animation measurements.

The original test incorrectly equated foreground SearchHost with native Search
being displayed. On this build, Start is visibly open while SearchHost owns
foreground. Start visibility must instead be checked using its immersive
CoreWindow and DWM cloaking state. `EnumWindows` alone missed that CoreWindow;
`FindWindowEx` is used. UIA enumeration of Start also needed a longer test-only
timeout than focused-element reads.

Final uninterrupted series, after the user explicitly agreed not to touch the
computer: **11/11 passed**.

| Path | Count | Result |
| --- | ---: | --- |
| Win opens Start only | 1 | Pass |
| Ctrl+Esc opens Start only | 1 | Pass |
| Taskbar Start button | 1 | Pass |
| Start search-box click, without subsequent typing | 2 | Pass |
| Start typing, mixed case/digits/accents/long query | 4 | Pass, exact text |
| Win+S followed by fast typing | 2 | Pass, exact text |

No input leaked into the disposable previous window in that series. The
observer first saw focused launcher input in roughly 281-516 ms in its typed
cases. These are UIA observation times, not high-speed video measurements or a
guarantee of native-speed animation. Query completion includes the time spent
typing the query and is not launcher activation latency.

Separately, Command Palette was stopped while `PowerToys.exe` remained running.
Native Win+S and native Start typing both received their full test query.
Command Palette was restarted afterward. Hanging the live launcher, paste,
PowerToys Run, custom launchers, IME/dead-key composition and prolonged everyday
use were not verified by this series.

Evidence: `build/runtime-final-results.json`, `build/runtime-clean-start.log`,
`build/runtime-no-escape.log`, `build/runtime-dismiss.log`. The final series
included the experimental dismissal hook below, but no successful use of that
hook had been observed. Cleanup removes that hook and unused code; the cleaned
source also adds dead-host ownership recovery, and is compiled and installed
separately. That crash-recovery path has not been fault-injection tested. The
11/11 result is not a second full runtime run of the cleaned binary.

## Instant-dismiss investigation

Matching PDB inspection found these `twinui.pcshell.dll` candidates:

| Symbol | RVA |
| --- | --- |
| XamlLauncher::DismissSynchronouslyWithoutTransition | 0x48ba40 |
| XamlLauncher::Dismiss / DismissToLastDesktopApplication (aliases) | 0x260be0 |
| XamlLauncher::Hide | 0x48d460 |
| XamlLauncherState::ShowSearchFromOpenStart | 0x498f88 |

Disassembly of the first two methods accesses the same member at `this+0x160`.
The synchronous method checks an interface method at vtable offset 0x68 and
calls offset 0x48 with reason 7. Ordinary Dismiss calls offset 0x40. These
offsets were used for analysis only, not hard-coded into the mod.

An experimental hook replaced ordinary Dismiss with the resolved synchronous
method only while a redirection transaction was active, on the original caller
thread with its original `this`. Windhawk logs confirmed both symbol resolution
and hook installation. The tested redirects did not produce the diagnostic
indicating use of that synchronous branch. This is not evidence that Start was
hidden without animation. The candidate was removed from the final mod rather
than leaving an unproven private call installed.

`tools/list-shell-symbols.cpp` is retained as a read-only PDB inspection tool.
No successful frame-by-frame animation verification was obtained. Instant
dismissal remains unresolved and is not an implemented feature of this release.

## Reproduction

Run from the repository root on an idle interactive desktop:

```powershell
.\wh.cmd build
.\wh.cmd install -EnableAfterBuild
.\tests\run-runtime-regression.ps1
```

The runner builds the harness with `g++`, checks each case's exit code and writes
`build/runtime-regression-results.json`. It returns nonzero if any case fails.
`-Passes 3` repeats the suite. `-NativeOnly` tests native fallback only after
Command Palette has been stopped manually; it does not terminate the launcher.

`tests/prepare-runtime-tests.ps1` installs a build and enables logs with UAC,
backing up the initial logging/delay values under `build/`. Use
`-RestoreLogging` to restore logging. It deliberately keeps the tested zero
extra delay; other mod settings are untouched.

## Primary references

- [SetForegroundWindow and permission lifetime](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow)
- [LockSetForegroundWindow and Alt unlocking](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-locksetforegroundwindow)
- [Why foreground activation is asynchronous](https://devblogs.microsoft.com/oldnewthing/20161118-00/?p=94745)
- [Why attaching input queues can hang applications](https://devblogs.microsoft.com/oldnewthing/20080801-00/?p=21393/)
- [Command Palette window lifecycle source](https://github.com/microsoft/PowerToys/blob/main/src/modules/cmdpal/Microsoft.CmdPal.UI/MainWindow.xaml.cs)

The upstream PowerToys source helps explain the design; it is not asserted to
match the installed package byte-for-byte. Matching Windows PDBs and runtime
observations are the evidence for this machine.
