# Custom keyboard → controller mapping for macOS Controller Emulation

Date: 2026-10-01
Repos: PlayCover (settings UI), PlayTools (in-game apply, live reload, overlay)

## Goal

macOS "Game Control → Controller Emulation" turns keyboard + mouse into a virtual gamepad for iOS
apps, but its key layout is fixed and leaves several gamepad inputs unreachable (Options, Home,
L3, R3). Users must be able to:

1. Edit the key layout per app inside PlayCover's app settings (before launching the game).
2. Have the game pick up changes immediately, including while it is running.
3. Show an in-game cheat sheet of the current layout (3 styles), with adjustable opacity,
   toggled by a hotkey.

Out of scope: changing mouse behaviour (click = R2, mouse/trackpad = right stick, Esc = reveal
pointer stay Apple's), building our own virtual controller, apps where Controller Emulation is off.

## Background (verified by spike)

- Emulation runs in-process: class `GCKeyboardAndMouseEmulatedController` (subclass of
  `GCController`, private framework `GameControllerUI`, iOSSupport). Enabled by the app pref
  `GCEnableKeyboardMouseController`.
- At startup Apple calls `-[GCKeyboardAndMouseEmulatedController remapControlsWith:]` with an
  `NSDictionary`:
  - `Buttons`: `{ <HID keyboard usage (NSNumber)> : <event input index (NSNumber)> }`
  - `Config`: mouse/keyboard tuning values
  - `LeftThumbstickSensitivity`: curve array
- Event input index → name (`-nameForEventInput:`): 0 DpadUp, 1 DpadDown, 2 DpadLeft,
  3 DpadRight, 4 ButtonA, 5 ButtonB, 6 ButtonX, 7 ButtonY, 8 LeftShoulder, 9 RightShoulder,
  10–13 LeftThumbstick Up/Down/Left/Right, 14–17 RightThumbstick Up/Down/Left/Right,
  18 LeftTrigger, 19 RightTrigger, 20 LeftThumbstickButton, 21 RightThumbstickButton,
  22 ButtonHome, 23 ButtonMenu, 24 ButtonOptions.
- Apple default `Buttons` (HID → index): arrows 82/81/80/79 → 0/1/2/3; Space 44 → 4;
  F 9, H 11 → 5; Q 20, U 24 → 6; E 8, O 18 → 7; Tab 43, Y 28 → 8; R 21, P 19 → 9;
  W 26, I 12 → 10; S 22, K 14 → 11; A 4, J 13 → 12; D 7, L 15 → 13; LShift 225, N 17 → 18;
  `-` 45, `` ` `` 53 → 23.
- Passing a dictionary whose `Buttons` keys are NSString breaks every key (lookups are by
  NSNumber). Keys and values must be NSNumber. With NSNumber keys an override works in-game,
  including new inputs (verified: Z→L3, X→R3, C→Options, V→Home).
- The game sandbox allows full access to `~/Library/Containers/io.playcover.PlayCover`.

## Data: one file per app

`~/Library/Containers/io.playcover.PlayCover/EmulatedController/<bundleId>.plist`

```
Enabled   Bool                      false → PlayTools passes Apple's dictionary through untouched
Buttons   Dict<String, Int>         "<HID usage>" : <event input index>  (plist keys are strings)
Overlay   Dict
  Style    String                   "list" | "keyboard" | "gamepad"
  Opacity  Real                     0.2 … 1.0
```

- One key maps to exactly one input (dictionary key = HID usage); one input may have several keys.
- `Config` / `LeftThumbstickSensitivity` are never stored: PlayTools keeps Apple's values.
- No file, or `Enabled = false` → Apple behaviour unchanged (backward compatible).
- Separate file (not `AppSettingsData`): PlayTools' mirror `AppSettingsData` uses synthesized
  `Decodable`, so adding fields there risks version-skew fallbacks; a separate file also gives the
  watcher one small target.

## PlayCover: "Controller" settings tab

New file `PlayCover/Views/Settings/EmulatedControllerView.swift` (AppSettingsView.swift is
already over the lint limit), added as a tab in `AppSettingsView`'s `TabView`; model + file I/O in
`PlayCover/Utils/EmulatedControllerMapping.swift` following `Keymapping.keymappingDir`'s pattern.

- Toggle "Custom key layout" → `Enabled`.
- Note: works only when the game's Game Control → Controller Emulation is On.
- Scrollable list of the 25 inputs, grouped: Face (A B X Y), D-pad, Shoulders & triggers
  (L1 R1 L2 R2), Left stick (↑ ↓ ← → , L3), Right stick (↑ ↓ ← → , R3), System (Menu Options
  Home). Each row: input name, key chips (× removes), "+" to record.
- Recording: local `NSEvent` keyDown/flagsChanged monitor captures the next key; virtual key code →
  HID usage via a virtual→HID table added to PlayCover's `KeyCodeNames.swift` (copied from
  PlayTools' `mapNSEventVirtualCodeToGCKeyCodeRawValue`). Rejected: Esc (41, Apple's pointer
  key), Left/Right Command (227/231, reserved for menu shortcuts). A key already used elsewhere
  moves to the new input (row shows a brief "moved from X" hint).
- Fixed rows shown read-only: R2 also = mouse click, right stick also = mouse, Esc = show pointer.
- Buttons: "Reset to Apple default", "Add suggested extras" (Z→L3, X→R3, C→Options, V→Home).
  First enable seeds Apple default + suggested extras.
- Overlay section: style picker (List / Keyboard / Gamepad), opacity slider (20–100 %), hint
  "Toggle in game with ⌘/".
- Every change writes the file atomically (live reload picks it up).
- All strings via `Localizable.strings` keys in all 21 locales (English text in non-English files,
  same as recent features).

## PlayTools: apply + live reload

New Swift file `PlayTools/Controls/EmulatedController/EmulatedControllerRemap.swift` + a small ObjC
hook in `NSObject+Swizzle.m`.

- Hook `-[GCKeyboardAndMouseEmulatedController remapControlsWith:]` (verify method exists with
  encoding `v24@0:8@16`, else skip and log). Install lazily and idempotently: at `+load` (if the
  class exists), on `GCControllerDidConnectNotification`, and once more via the existing delayed
  block — GameControllerUI may load after `+load`.
- In the hook: remember Apple's incoming dictionary (`appleDefaults`), then call the original with
  `merged(appleDefaults, file)`:
  - file missing / unreadable / `Enabled == false` → `appleDefaults` unchanged.
  - else → copy of `appleDefaults` with `Buttons` replaced by the file's `Buttons`, keys and
    values converted to NSNumber; invalid entries (non-numeric, index outside 0…24) dropped and
    logged.
- Live reload: `DispatchSource` vnode watcher on the `EmulatedController` directory (PlayCover's
  atomic writes replace the file, so watch the directory). On change (debounced ~200 ms) re-read
  the file and, on every controller in `GCController.controllers()` that is a
  `GCKeyboardAndMouseEmulatedController`, set ivar `_mapping` to the merged dictionary
  (`object_setIvarWithStrongDefault`, after checking the ivar exists with type `@`) and call
  `-setupButtons`, which only does `_buttons = _mapping[@"Buttons"]`. Do NOT call
  `remapControlsWith:` again: it also creates a new timer queue and starts new left-stick /
  mouse-idle timers, so a second call would leave the old timers running. Then refresh the overlay.
- Late install: if the hook is installed after Apple's startup call (missed it), read the
  controller's current `_mapping` ivar as `appleDefaults` and apply via the live-reload path.
- Unchanged: `disableBuiltinKeyboard` hooks (emulation still works with them on — verified).

## PlayTools: overlay

`PlayTools/Controls/EmulatedController/Overlay/` — one model + three views.

- Model: list of `(input, [keyNames])` built from the merged `Buttons` (HID → display name via
  `KeyCodeNames.keyCodes`), plus the fixed mouse/Esc rows. With `Enabled = false` the overlay
  shows Apple's active layout; `Overlay` settings apply regardless of `Enabled`.
- Container: full-screen passive `UIView` on `screen.keyWindow.rootViewController.view`
  (`isUserInteractionEnabled = false`, brought to front), same approach as `DebugController`.
  `alpha = Opacity`. Hidden at launch.
- Styles:
  - List: compact two-column panel, top-right corner ("Space → A").
  - Keyboard: miniature keyboard, bottom-centre, mapped keys tinted and labelled with the input.
  - Gamepad: controller outline, bottom-centre, each input labelled with its key(s).
- Hotkey ⌘/ via a new `UIKeyCommand` in `MenuController` ("Toggle controller key overlay"),
  localized in `Playtools.strings` (21 locales). Works with keymapping off.
- Prerequisite fix: `MenuController.keymappingMenu()` zips 4 parallel arrays that are out of
  sync (9 icons/selectors vs 8 titles/key commands), so ⌘D, ⌘., ⌘[ and ⌘] trigger the wrong
  actions. Rebuild that group from a single array of entries before appending the new command.

## Error handling

- Hook/class/encoding mismatch (future macOS) → log once, leave Apple behaviour; never crash.
- Bad file → ignore file, log, keep Apple defaults; PlayCover rewrites a valid file on next edit.
- Watcher failure → log; mapping still applies at next launch.

## Testing

No unit-test targets exist in either repo. Pure logic (merge/convert in PlayTools, key move /
reset in PlayCover) gets a small `assert`-based self-check function run in DEBUG builds. Manual
verification in Aniimo after each phase: default layout unchanged with feature off; custom keys
work; edits apply live; overlay styles/opacity/hotkey; old ⌘ shortcuts now trigger the right
actions.

## Phases (each ends with a build the user can try)

1. Data file + PlayCover tab (mapping, toggle, reset/extras) + PlayTools hook, merge, live reload.
   Remove the gc-probe spike code.
2. Menu array fix + ⌘/ hotkey + overlay container + List style + overlay settings.
3. Keyboard style.
4. Gamepad style.
