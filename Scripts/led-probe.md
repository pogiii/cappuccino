# LED-only lock-screen probe

This standalone experiment tests whether a Mac's **built-in Caps Lock LED** can
stay lit while locked **without enabling logical Caps Lock**. It does not change
Cappuccino, filter or record keyboard input, prevent sleep, or install anything.
External keyboards and macOS versions before 26 are outside this probe's scope.

## Integrated app versus this probe

Cappuccino now has a separate LED adapter and lifecycle controller using this
mechanism. Its integration still needs the [app acceptance checklist](../readme.md#hands-on-acceptance-test)
on the target hardware; the confirmed probe result does not prove the complete
keyboard/menu/lock workflow.

The app has no probe expiration and uses **eight recovery writes per rolling ten
seconds**, rather than this script's eight attempts over the entire test.
It monitors at 250 ms only while maintaining On, reads before rewriting, and
keeps sleep prevention active if LED control fails. Keyboard suspension does not
stop its independent LED monitor. The app's **Retry Connections** action retries
LED issues separately from keyboard availability.

Quit the app before running the probe or its restore command. Both affect the
same hardware-global override and must not run as competing owners.

## Before testing

- Quit Cappuccino and other keyboard-LED utilities so they cannot fight over the
  light. Run only one probe at a time.
- Turn actual Caps Lock off. The probe checks its global modifier flag and
  refuses a test if it is on; it never writes the logical Caps Lock state.
- This uses **private, unsupported** IOKit functionality: the passive
  `IOHIDEventSystemClientCreateWithType` constructor and the `HIDCapsLockLED`
  service property. Availability and a successful write are not guarantees that
  the physical LED responds or remains lit while locked.
- No elevated privileges or new privacy grants should be necessary for the
  passive path. Do not use `sudo` or change permissions to force a failed probe.

## Read-only inspection

From the repository root:

```sh
swift Scripts/led-probe.swift inspect
```

This discovers only services positively identified as built-in keyboards and
prints the reported LED state, plus a read-only logical Caps Lock snapshot.
The property's getter reports `On`/`Off`, **not** the requested override mode:
`Off` does not mean a competing forced-off override is present, and an `Auto`
restoration need not read back as `Auto`.
`<not exposed>` is diagnostic, not a conclusive compatibility result: a
subsequent write may still be accepted. No LED writes occur in inspection mode.
The probe cannot determine ownership; quitting other LED tools is essential.

## Physical test

```sh
swift Scripts/led-probe.swift test 60
```

The probe requests `On` **once**, watches lock/unlock notifications, then requests
system-managed `Auto` after 60 seconds. There is no periodic reassertion that
could hide a lock-screen reset. Durations from 1 through 300 whole seconds are
accepted; omission defaults to 60 seconds.

1. Confirm the physical LED turns on. An `accepted=true` message alone is not a
   pass.
2. In a disposable TextEdit document, type `abc` and Shift+`abc`. Confirm the
   result is `abc` and `ABC` even though the light is on.
3. Lock with Control+Command+Q. Check that the LED remains on, including if the
   display turns off. Do not press Caps Lock during the experiment; it still
   controls normal native Caps Lock because this is not a key-remapping test.
4. Unlock normally and check the light again. Check the printed logical Caps
   Lock snapshots and lock/unlock events. These are diagnostics, not proof of
   physical LED state or password safety. If the login screen warns that Caps
   Lock is on, check the native state before entering sensitive text.
5. Wait for expiry, or use Control+C in the terminal. Confirm the LED returns to
   normal system-managed behavior and normal Caps Lock still works afterward.

The probe itself does not keep the Mac awake. A sleeping/suspended process
cannot run its cleanup timer until it resumes. Lock is supported as a scenario
to test, not an already-verified guarantee.

## Recovery-mode lock-screen test

The first physical test on macOS 26.6.2 confirmed independent LED control, but
the one-time `On` request did **not** survive locking. Unified logs showed
`com.apple.hiservices-xpcservice` writing `Auto`, which turned the LED off while
logical Caps Lock remained off. This is a competing writer, not evidence that
the initial LED write was rejected.

After quitting Cappuccino and other LED tools and turning actual Caps Lock off:

```sh
swift Scripts/led-probe.swift test 60 --recover
```

Repeat the physical checks above. In particular, wait on the lock screen to see
whether the LED returns **before unlocking**, not only afterward.

- The original one-write mode remains the default. `--recover` is opt-in and
  only valid for `test`.
- Recovery reads the reported LED state every 250 ms. When every state is known
  and at least one built-in keyboard reports `Off`, it requests `On` again.
  Healthy `On` states do not cause repeated writes.
- There are at most **8 recovery attempts**, in addition to the initial `On`
  request. If a further reset needs a ninth attempt, the test stops with an
  error and attempts `Auto` cleanup instead of fighting macOS indefinitely.
- An unreadable state or rejected write also ends the test with cleanup.
- Recovery runs in the test loop, not in asynchronous LED-writing callbacks.
  Polling ends before cleanup, so no recovery attempt can turn the light back
  on after `Auto`.
- There can still be a visible dark interval during a transition. The 250 ms
  polling interval is not a scheduling or uninterrupted-illumination guarantee.
- This only writes the LED property. It never enables logical Caps Lock,
  installs an input filter, or attempts to bypass Secure Input.

Look for `LED recovery attempt N/8` in the output. A successful API write still
needs a visual check: if the light stays off, flickers repeatedly, or reaches the
retry limit, recovery-mode lock-screen support is **not** established.

## Cleanup and recovery

Timeout, Control+C (`SIGINT`), `SIGTERM`, and terminal hangup (`SIGHUP`) attempt
`Auto` restoration.
A rejected or partially accepted initial `On` request also triggers an `Auto`
attempt on every selected service. Cleanup rejection is reported as an error.
Catchable signals return the conventional `128 + signal` exit status after
cleanup.

**SIGKILL, a crash, or power loss cannot guarantee restoration.** If the light
gets stuck, stop other LED tools and run:

```sh
swift Scripts/led-probe.swift restore
```

This explicitly requests system-managed `Auto`, not a forced LED-off state.
Always visually check recovery; a successful API result is not physical proof.

## Software checks without touching the LED

```sh
mkdir -p build
swiftc -warnings-as-errors Scripts/led-probe.swift -o build/led-probe
python3 Scripts/test-led-probe.py build/led-probe
```

The tests use `--dry-run` only. They cover argument validation, read-only
inspection, bounded test duration, timeout cleanup, `SIGINT`/`SIGTERM`/`SIGHUP` cleanup,
the standalone recovery command, recovery after simulated competing resets,
healthy-state no-ops, and retry-limit exhaustion. They do not prove hardware
compatibility.

To see recovery without touching the physical LED:

```sh
swift Scripts/led-probe.swift test 2 --recover --dry-run --simulate-resets 2
```

`--simulate-resets N` accepts 1...20 and is only valid for dry-run tests. The
simulated backend reports `Off` after a competing reset independently of
recovery polling, so the original one-write mode can be compared with recovery.
Simulation never opens a HID client, writes a real LED, or posts system
lock/unlock notifications.

## Report the result

Record the Mac model, macOS version, whether each physical check passed, and the
probe output. Do not include passwords or other sensitive input.

Only integrate an independent LED adapter into Cappuccino after the light
stays on across lock/unlock, ordinary typing is unaffected, and cleanup works.
Failure of this experimental route must never cancel an existing keep-awake
request or fall back to enabling native Caps Lock on the lock screen.

## Background

- [pi-caps-blink's LED caveat](https://github.com/bstncartwright/pi-caps-blink#caps-lock-led-caveat)
  describes the private `On`/`Off`/`Auto` override.
- [Blinkenlights' macOS Tahoe compatibility notes](https://github.com/shubhxms/pi-blinkenlights#macos-tahoe-compatibility)
  explain why direct HID LED element writes can report success without changing
  a built-in keyboard's light on newer macOS.
- [Apple's keyboard filter source](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm)
  distinguishes the LED override setting, reported LED state, and logical
  Caps Lock state. The LED property's getter does not expose override ownership.
