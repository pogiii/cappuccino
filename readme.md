# Cappuccino

A tiny native macOS menu-bar **prototype**: Caps Lock's LED is the stay-awake
switch. On keeps the Mac and display awake (like `caffeinate -i -d`); off restores
normal idle sleep. The app filters the Caps Lock modifier out of keyboard events
so ordinary typing should remain normal. Shift still works.

**Hardware/typing validation is required before relying on it.** In particular,
the native Caps Lock state still exists internally. This is an event-filtering
prototype, not a system-wide Caps Lock replacement.

## Build and run

Requires Xcode 26+ (selected with `xcode-select`) to build the app and compile
its Icon Composer asset. The built app runs on macOS 13+.
There are no third-party dependencies.

```sh
sh Scripts/build-app.sh
open build/Cappuccino.app
```

An outlined cup in the menu bar means normal sleep, a filled cup means awake,
and an exclamation mark means the keyboard connection needs attention. There
is no Dock icon or main window.

On first launch:

1. Open the menu and choose **Allow Accessibility…**.
2. Enable Cappuccino in **System Settings → Privacy & Security → Accessibility**.
3. Choose **Retry Keyboard Connection** in its menu. If that fails, quit and
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
- Caps Lock or **Keep Mac Awake** in the menu controls the same state and LED.
- Switching off or quitting releases both power assertions. Quitting turns
  Caps Lock off, then restores its normal keyboard behavior.
- System sleep or an inactive login session stops the feature. Waking or
  returning to the session reconnects in the off state.
- **Closing the lid, explicitly choosing Sleep, and locking the screen are
  not prevented.** This is idle-sleep prevention, not a security bypass.
- The prototype targets a MacBook's built-in keyboard. External keyboards,
  remapping tools, and alternate input methods have not been validated.
- **Secure Input bypasses event taps** (password fields, some terminal modes).
  Cappuccino polls for it every 200 ms and stops the feature, turns Caps Lock
  off, and releases sleep prevention. Leave Secure Input and choose Retry.
  This is not an instantaneous guarantee: there can be a brief transition
  before detection. Do not rely on the filter in password fields.
- Software that directly queries the global Caps Lock state can still see it
  on. A stricter replacement would need a lower-level key/LED implementation.
- If macOS interrupts the input filter or permission is revoked, the app
  stops instead of silently leaving stay-awake mode running.
- Force-killing/crashing the app releases power assertions through macOS, but
  may leave native Caps Lock on. Press Caps Lock to turn it off. No persistent
  remappings or system preferences are written.
- Keeping the display awake consumes battery. There is no auto-off timer.

The input filter only removes the Caps Lock modifier. It does not record,
store, transmit, or lowercase typed text. No network requests or subprocesses
are used by the app.

## Structure

```text
Sources/Cappuccino/
  App/                         # Composition and app/session lifecycle
  Features/StayAwake/
    Model/                     # State, behavior, dependency protocols
    UI/                        # AppKit menu and presentation
    Platform/                  # Core Graphics / IOKit implementations
Tests/CappuccinoTests/Features/StayAwake/
```

The model has no AppKit, Core Graphics, or IOKit imports. UI forwards actions
and renders state; platform adapters implement model protocols. Everything
runs on the main run loop. One module keeps the feature together; folder
boundaries are conventions, not separate Swift module access restrictions.

## Checks

```sh
swift test
sh Scripts/build-app.sh
```

Tests cover state transitions, cleanup, failures, duplicate events, event-flag
filtering, and real IOKit assertion acquisition/release. They do **not** grant
Accessibility permission, tap your live keyboard, or prove LED/typing behavior.

### Hands-on acceptance test

1. Launch and grant permission. Confirm the LED starts off.
2. In TextEdit, press Caps Lock. Confirm the LED and filled cup are on.
3. Type `abc`, then hold Shift and type `ABC`. Verify case and shortcuts still
   work. Repeat with your usual apps and keyboard layout.
4. Run `pmset -g assertions`. With mode on, Cappuccino should own
   `PreventUserIdleSystemSleep` and `PreventUserIdleDisplaySleep`.
5. Switch off using the menu. Confirm the LED goes off and those assertions
   disappear. Repeat using the key; hold it to check it does not rapidly toggle.
6. With mode on, quit. Confirm assertions disappear and Caps Lock works
   normally again.
7. Check a Secure Input field and sleep/wake: mode should stop, not claim to
   remain active. Retry after leaving Secure Input. Check Caps Lock is off
   before entering any sensitive text.

If normal typing becomes uppercase, the LED disagrees with the menu, or the
filter interferes with another app, **quit Cappuccino** and report the macOS
version, keyboard layout, and app involved. The LED/input strategy needs that
hardware feedback before this can be considered a finished utility.
