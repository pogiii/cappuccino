<p align="center">
  <img src="Assets/icon-preview.png" alt="Cappuccino app icon" width="160">
</p>

<h1 align="center">Cappuccino</h1>

A tiny native macOS menu-bar **prototype**: Caps Lock toggles stay-awake mode,
and its LED indicates the mode independently. On keeps the Mac and display awake
(like `caffeinate -i -d`); off restores normal idle sleep. The app filters the Caps
Lock modifier out of keyboard events so ordinary typing should remain normal.
Shift still works.

**Hardware/typing validation is required before relying on it.** In particular,
the native Caps Lock state still exists internally. This is an event-filtering
prototype, not a system-wide Caps Lock replacement.

## Build and run

Requires Xcode 26+ (selected with `xcode-select`) to build the app and compile
its Icon Composer asset. The built app runs on macOS 13+.
Independent LED control targets a built-in keyboard on macOS 26+ and uses a
private, unsupported API. Other configurations can still use eligible awake
controls, but show an LED warning instead of enabling native Caps Lock to
simulate LED output. There are no third-party dependencies.

```sh
sh Scripts/build-app.sh
open build/Cappuccino.app
```

An outlined cup in the menu bar means normal sleep, a filled cup means awake,
and an exclamation mark means the keyboard is disconnected while mode is off.
If the keyboard disconnects while mode is on, the cup stays filled and the menu
reports that keyboard control is paused. LED issues are reported separately;
they do not mean sleep prevention has stopped. There is no Dock icon or main window.

On first launch:

1. Open the menu and choose **Allow Accessibility…**.
2. Enable Cappuccino in **System Settings → Privacy & Security → Accessibility**.
3. Choose **Retry Connections** in its menu. If that fails, quit and
   reopen the app.

Run the built `.app`, not `swift run`, so macOS attributes the permission to
Cappuccino rather than your terminal. Local builds are ad-hoc signed; a rebuild
can invalidate the grant. If necessary remove the old Accessibility entry,
add the rebuilt app, and relaunch. You can optionally build with
`SIGNING_IDENTITY="Apple Development: …" sh Scripts/build-app.sh`.

To explore in Xcode, open `Package.swift`. Use the script above to produce the
permission-bearing app bundle.

The editable app icon is `Assets/app.icon`. The build script compiles it into
`Assets.car` and a legacy `app.icns` fallback in the app bundle before signing.

## Behavior and limits

- Startup is always off; awake state is not persisted.
- Caps Lock or **Keep Mac Awake** in the menu toggles the same manual request.
  Native Caps Lock's boolean state is not the source of awake intent: a key
  action after a menu action still toggles mode once.
- Switching off or quitting releases the manual power request, stops LED
  recovery, and requests system-managed LED `Auto`. When connected, keyboard
  cleanup resets native Caps Lock off. While suspended, intentional native
  Caps Lock behavior belongs to the user, not the indicator controller.
- Locking the screen, system sleep, or an inactive login session suspends keyboard
  control without cancelling an active keep-awake request **or LED ownership**.
  The independent LED controller recovers from macOS resetting the light while
  locked. A brief flash/dark interval during a transition is expected.
  Unlocking, waking, or returning reconnects keyboard control when safe without
  resetting mode. Explicit sleep can suspend the app itself until wake.
- **Closing the lid, explicitly choosing Sleep, and locking the screen are
  not prevented.** An active request continues to prevent idle sleep while
  locked, like `caffeinate -i -d`. Explicit sleep/lid behavior is still controlled
  by macOS; this is not a security bypass or closed-lid mode.
- The prototype targets a MacBook's built-in keyboard. External keyboards,
  remapping tools, and alternate input methods have not been validated.
- **Secure Input bypasses event taps** (password fields, some terminal modes).
  Cappuccino polls for it every 200 ms, suspends keyboard control, and turns
  native Caps Lock off once on suspension, but leaves the keep-awake request and
  independent LED control unchanged. The key then has normal native behavior
  while suspended. Reconnection is checked every 500 ms after Secure Input ends,
  while the session is active and unlocked. **Keep Mac Awake** can still switch
  mode off while disconnected without changing intentional native password casing.
  This is not an instantaneous guarantee: there can be a brief transition
  before detection. Do not rely on the filter in password fields.
- Software that directly queries the global Caps Lock state can still see it
  on after physical key input. Separating LED output does not remove this input
  filter limitation. A stricter replacement needs lower-level input handling.
- If macOS interrupts the input filter or permission is revoked, the app
  disconnects keyboard control without cancelling an existing request. The menu
  continues to report awake mode and allows switching it off; keyboard
  reconnection is retried automatically when permission and Secure Input allow.
- Force-killing/crashing the app releases power assertions through macOS, but
  may leave native Caps Lock on or strand a forced LED override. Check native
  Caps Lock before typing. Startup attempts to restore LED Auto before normal
  operation. If needed, quit other LED tools and run
  `swift Scripts/led-probe.swift restore`; visually confirm recovery.
  No persistent key remappings or system preferences are written.
- Keeping the display awake consumes battery. There is no auto-off timer.

### Independent LED control

- `HIDCapsLockLED` on a passive HID client controls the built-in light only.
  LED output never enables the native Caps Lock modifier and does not subscribe
  to keyboard input. This private API may change or report success without
  controlling the physical light; hardware validation remains necessary.
- While maintaining On, the app reads LED state every 250 ms and only rewrites
  On when a selected LED reports Off. There is **no new LED polling while off**.
  Existing keyboard safety/reconnection checks are separate.
- At most eight recovery writes are allowed in a rolling ten-second window.
  Spaced lock cycles can recover indefinitely: there is no eight-lock lifetime
  limit or probe-style expiration. Unknown state, rejected writes, or rate-limit
  exhaustion stop LED recovery and attempt Auto restoration.
- LED failure leaves a successful power request active. The menu shows an
  LED-specific warning and **Retry Connections**, even if the keyboard is healthy.
  Recovery does not silently spin after a failure; retry is explicit.
- Quit other LED utilities and diagnostic probes before using the app. The
  hardware-global override has no ownership credential; competing tools can
  reset it. Auto cleanup returns normal native LED indication, not forced Off.

The input filter only removes the Caps Lock modifier. It does not record,
store, transmit, or lowercase typed text. No network requests or subprocesses
are used by the app.

## Structure

```text
Sources/Cappuccino/
  App/                         # Composition and app/session lifecycle
    UI/                        # AppKit menu and presentation
  Features/
    KeepAwake/
      Model/                   # Request ownership and sleep-prevention protocol
      Platform/                # IOKit power assertions
    Triggers/CapsLock/
      Model/                   # Manual request, keyboard safety, LED lifecycle/protocols
      Platform/                # Core Graphics keyboard and independent IOKit LED output
Tests/CappuccinoTests/Features/
  KeepAwake/
  Triggers/CapsLock/
```

Keep Awake owns sleep prevention; triggers request it. The dependency direction
is `App → Triggers → KeepAwake`, never the reverse. The app constructs concrete
platform adapters; models have no AppKit, Core Graphics, or IOKit imports.
Everything runs on the main run loop. This remains one Swift module; folder
boundaries are conventions, not separate module access restrictions.

### Ownership rules

- `KeepAwakeController` accepts opaque request IDs. The first acquisition starts
  power assertions; the last release stops them. Repeated acquisition/release of
  the same ID is idempotent. A trigger releases only its own ID.
- `CapsLockTrigger` owns one manual request shared by the key and menu toggle.
  It coordinates keyboard safety and an independent `CapsLockLEDController`.
  Its `isOn` state is manual intent, distinct from keyboard availability
  (`isRunning`), LED issues, and Keep Awake's aggregate `isAwake` state.
- Keyboard suspension preserves the manual request and LED monitor.
  Reconnection does not release/reacquire power or restart healthy LED ownership.
  Failed power acquisition never publishes awake success; LED failure never
  rolls back successful power acquisition. Explicit off/stop releases only the
  manual request, not another trigger's request.
- LED monitoring is cancelled/generation-invalidated before Auto cleanup so
  late callbacks cannot reassert On. Failed cleanup is visible and retryable.
  Adapter construction has no HID side effects; startup repair occurs only
  after the app's single-instance guard.
- Power failures are thrown to the caller, never reported as successful awake
  state. Cleanup must succeed before new acquisitions are accepted; failed
  releases retain their request so cleanup can be retried.
- On destruction, a trigger abandons only its own request. Keep Awake retains
  any cleanup failure without retaining the dead owner's ID; a replacement
  trigger's startup retries cleanup before reconnecting the keyboard.
- The app owns presentation and session lifecycle. Currently Caps Lock is the
  only trigger; its manual request drives the LED. Before exposing another
  trigger, aggregate power status must be presented separately from each
  trigger's state and the hardware indicator's meaning must be revisited.

This is a structural foundation, not agent integration. Request IDs are local
ownership handles, not expiring leases or public API credentials. Agent
lifetimes, request metadata, CLI/MCP interfaces, and additional UI are deferred.
There is no trigger registry or plugin framework.

## Checks

```sh
swift test
sh Scripts/build-app.sh
```

Tests cover independent request ownership, trigger state transitions, cleanup,
failures, duplicate events, event-flag filtering, lock/session/sleep notification
handling, and real IOKit assertion acquisition/release and continuity across
keyboard interruption and LED-only failure. Simulated LED services and clocks
cover matching, partial writes, cleanup, recovery rate limits, late callbacks,
off-state inactivity, and distinct menu warnings. They do **not** grant
Accessibility permission, tap your live keyboard, write the physical LED, or
prove integrated hardware/typing behavior.

The standalone LED probe's recovery was manually confirmed on macOS 26.6.2.
The integrated app requires the following hands-on acceptance test; probe success
and unit tests are not substitutes.

### Hands-on acceptance test

1. Launch and grant permission. Confirm the LED starts off.
2. In TextEdit, press Caps Lock. Confirm the LED and filled cup are on.
3. Type `abc`, then hold Shift and type `ABC`. Verify case and shortcuts still
   work. Repeat with your usual apps and keyboard layout.
4. Run `pmset -g assertions`. With mode on, Cappuccino should own
   `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`.
5. Switch off using the menu. Confirm the LED returns to normal and those
   assertions disappear. Switch on by menu, then press the key once: it must
   switch off on the first action, not require a second press. Repeat in both
   directions and hold the key to check it does not rapidly toggle.
6. With mode on, quit. Confirm assertions disappear and Caps Lock works
   normally again.
7. With mode on, lock the screen. The LED may flash, but should recover **while
   still locked**, and both power assertions should remain present
   (`pmset -g assertions` from another session or over SSH). Unlock: mode and
   indicator should remain on. Repeat with mode off; it must stay off.
   Repeat normally spaced cycles beyond eight total and leave mode active well
   beyond 60 seconds to verify there is no probe lifetime limit.
8. Check a Secure Input field: native Caps Lock is reset once on suspension,
   while the independent LED, filled cup, and power assertions remain active.
   The physical key then has normal Caps Lock behavior while suspended; test
   intentional native on/off and reconnection without entering sensitive text
   just to test the filter. The menu can switch awake mode off while keyboard
   control is paused without resetting the user's intentional native state.
9. Explicitly sleep/wake the Mac with mode on: sleep must still work, and waking
   should retain mode and restore the LED once the session is unlocked.

If normal typing becomes uppercase, the LED disagrees with the menu without a
reported indicator warning (beyond the brief transition flash), or the filter
interferes with another app,
**quit Cappuccino** and report the macOS version, keyboard layout, and app
involved. The LED/input strategy needs that hardware feedback before this can
be considered a finished utility.
