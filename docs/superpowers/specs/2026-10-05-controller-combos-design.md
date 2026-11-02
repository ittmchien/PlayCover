# Controller combos and button icons for Controller Emulation

Date: 2026-10-05
Repos: PlayCover (settings UI + file), PlayTools (in-game apply)
Builds on: `2026-10-01-emulated-controller-mapping-design.md`

## Goal

1. Show the controller glyph of every input in the Controller tab (incl. Home, Menu, Options).
2. Combos: a set of controller inputs (≥1, e.g. L1+R1+X) pressed together by a keyboard key set
   (≥1 key held together, e.g. R, or Shift+W). One combo may have several key sets.
3. Keep the existing "several keys per input" chips unchanged.

## Background (verified by probe on macOS, 2026-10-05)

- `GCKeyboardAndMouseEmulatedController` handles keys in `-updateWithKeyKey:down:` (encoding
  `v28@0:8q16B24`): key = HID usage, looked up in `_buttons` (copied from `_mapping[@"Buttons"]`).
- Extra `Buttons` entries with synthetic usages (`0x10000 + inputIndex → inputIndex`) are accepted by
  `-remapControlsWith:`; calling the original `-updateWithKeyKey:down:` with a synthetic usage presses
  that input (verified L1, R1 together and left stick up). Element `localizedName`s are unchanged.
- Apple's element `sfSymbolsName`s on the emulated controller (source of the icon table below).

## Data: `Combos` in `EmulatedController/<bundleId>.plist`

```
Combos  Array<Dict>             optional; missing = no combos
  Keys    Array<Int>            HID usages held together (≥1, unique, order irrelevant)
  Inputs  Array<Int>            event input indices 0…24 pressed together (≥1, unique)
  Priority String               optional "Combo" | "Keys" | "Both"; missing/unknown = "Combo"
```

- Stored flat: one entry per key set. The UI groups entries with the same input set into one combo.
- A key set appears at most once in the file (a key set belongs to one combo).
- All entries of one combo (same input set) share `Priority`; PlayCover writes it on every entry and a
  newly recorded key set inherits the combo's current mode (a new combo starts as "Combo").
- Combos apply only when `Enabled == true`. Invalid entries (empty, non-int, index outside 0…24,
  usage ≤ 0) are dropped and logged; the rest still apply.
- Backward compatible: no `Combos` → behaviour exactly as before (no new hook path taken).
- "Reset to Apple default" resets `Buttons` only; combos are kept (removed per combo).

## PlayTools: apply

- `merge`: when enabled and at least one valid combo exists, add the 25 synthetic entries
  `NSNumber(0x10000 + i) → NSNumber(i)` to the merged `Buttons`.
- Hook `-[GCKeyboardAndMouseEmulatedController updateWithKeyKey:down:]` (installed next to the remap
  hook, same lazy/idempotent installer, encoding checked, mismatch → log once, Apple behaviour).
- Pure engine (`EmulatedControllerComboEngine`): built from the numeric `Buttons` (real keys only) and
  the valid combos.
  - Keys that are in neither `Buttons` nor any combo → hook calls the original unchanged.
  - Otherwise update `held` (down inserts, up removes; repeats are no-ops) and recompute the desired
    input set:
    1. Active combos: combos whose keys ⊆ `held`, taken by key count descending (ties: file order),
       then by `Priority`:
       - `Combo`: skipped if it shares a key with an already-consumed key; otherwise its keys are consumed.
       - `Keys`: active only if none of its keys has its own `Buttons` entry; consumes nothing.
       - `Both`: always active; consumes nothing (never blocks other combos).
    2. Desired = inputs of active combos ∪ `Buttons[k]` for every held, non-consumed key `k`.
  - Emit `(0x10000 + i, down)` for inputs entering the desired set and `(…, up)` for inputs leaving it;
    the hook calls the original once per event. Example, Shift (own L2) + W (own stick up) → A, hold
    Shift then press W: `Combo` → only A (L2 released, stick never pressed; releasing W presses L2
    again); `Keys` → L2 + stick up, no A; `Both` → L2 + stick up + A.
- No combos in the file → no engine → hook is a straight pass-through.
- Live reload rebuilds the engine when `Buttons` or any combo (keys, inputs, priority) changed; before swapping, it emits `up` for every input the old engine had
  down (no stuck buttons). Held state starts empty after a reload.
- Engine state guarded by a lock (the hook's calling thread is unknown).
- DEBUG `selfCheck()` covers merge synthetic entries, combo parsing and the engine scenarios above.

## PlayCover: icons and labels

Xbox and PlayStation glyphs are shown side by side (no picker). `EmulatedControllerInput.symbolNames`
returns `(xbox, playStation)` (Apple's SF Symbol names). Each name falls back when the symbol is missing
on older macOS (deployment target 12; `*.tilt.*` need 13): stick directions → `l.joystick` /
`r.joystick`, anything else → `gamecontroller`. When both resolve to the same symbol it is rendered once.
One shared icon view (`EmulatedControllerInputIcon`, tooltip = localized label) is used by input rows,
the combo picker and combo rows.

| Input | Xbox | PlayStation |
|---|---|---|
| D-pad ↑ ↓ ← → | `dpad.up.fill` `dpad.down.fill` `dpad.left.fill` `dpad.right.fill` | same |
| A B X Y | `a.circle` `b.circle` `x.circle` `y.circle` | `xmark.circle` `circle.circle` `square.circle` `triangle.circle` |
| L1 R1 | `lb.rectangle.roundedbottom` `rb.rectangle.roundedbottom` | `l1.rectangle.roundedbottom` `r1.rectangle.roundedbottom` |
| L2 R2 | `lt.rectangle.roundedtop` `rt.rectangle.roundedtop` | `l2.rectangle.roundedtop` `r2.rectangle.roundedtop` |
| Left stick ↑ ↓ ← → | `l.joystick.tilt.up` `.down` `.left` `.right` | same |
| Right stick ↑ ↓ ← → | `r.joystick.tilt.up` `.down` `.left` `.right` | same |
| L3 R3 | `l.joystick.down` `r.joystick.press.down` | same |
| Menu (23) | `line.horizontal.3.circle` | `line.horizontal.3.circle` (same glyph → shown once) |
| Options (24) | `rectangle.fill.on.rectangle.fill.circle` | `square.and.arrow.up.circle` |
| Home (22) | `logo.xbox` | `logo.playstation` |

Every input row shows its icons before the label. Input labels use the dual "Xbox / PlayStation" form in
every locale ("A / Cross", "LB / L1", "LT / L2", "LS / L3 (left stick press)", "Menu / Options",
"View / Create", "Xbox / PS"; D-pad and stick directions unchanged), and so do the strings naming those
buttons (mouse click → "RT / R2", suggested extras help).

## PlayCover: Combos section

Placed after the input groups and action buttons, before the fixed rows; disabled when the layout is off.
Views live in `EmulatedControllerComboView.swift`; the combo model and its pure operations in
`EmulatedControllerCombo.swift`.

- "Add combo": inline picker of the 25 inputs as button-style toggles showing the input icons (grouped
  like the tab, tooltip = input label). "Create" is enabled with ≥1 input selected. If a combo with the
  same input set exists, its row starts recording instead of creating a duplicate. A new combo is
  pending (view-model state, not saved) until its first key set is recorded; cancelling recording, or
  starting another recording, drops it.
- Combo row: input icons, key-set chips (`KeyCodeNames.displayName` joined with " + ", modifiers first,
  e.g. "Lshft + W"; × removes that key set), conflict-mode menu, "+" records another key set (click
  again cancels), trash deletes the whole combo after a confirmation alert (a pending combo is just
  cancelled).
- Conflict mode menu (per combo, sets `Priority` on every entry; disabled while the combo is pending):
  "Combo first" / "Keys first" / "Both". Tooltip per option, example Shift = LT, W = stick ↑,
  combo Shift + W = A, holding Shift then W:
  - Combo first → only A.
  - Keys first → LT + stick ↑; the combo works only when none of its keys has its own button.
  - Both → LT + stick ↑ + A.
- Recording a key set: local monitor on keyDown/keyUp/flagsChanged; tracks held keys and the largest set
  held; when all keys are released the largest set is committed. Caps Lock (no release event) counts as
  a tap. Esc and Command are rejected with the existing hints; ⌘-shortcuts pass through; unknown keys
  show the existing "not supported" hint. A key set already used by another combo moves here with a
  "moved from …" hint. Only one row (input or combo) records at a time.
- All new strings localized in every `Localizable.strings` (en + vi translated, others English).

## Presets

- `presets/EmulatedController/<bundleId>.plist` is a folder reference in the PlayCover target, copied to
  `Contents/Resources/EmulatedController/`; any plist dropped in the folder ships with the next build.
  Same format and decoding (lossy Buttons/Combos) as the container file.
- Game install (`Installer.install`, after the wrapped app is signed): when the container has no
  `EmulatedController/<bundleId>.plist` and a bundled preset exists, the preset is saved as-is
  (its `Enabled` kept). An existing file is never overwritten.
- Controller tab, first enable without a file: bundled preset (forced enabled) if one exists, else
  Apple's layout plus the suggested extras.
- "Load preset" (only when a bundled preset exists) and "Import…" (any `.plist`, any file name; applies
  to the open app) sit next to the layout toggle and work while the layout is off. They share one
  destructive confirmation alert. Confirming replaces Buttons and Combos, turns the layout on and keeps
  the current Overlay. An imported file that fails to decode or has no valid buttons
  and no combos only shows a hint under the action buttons; nothing changes. Recording stops first.
- `scripts/controller-presets.sh pull <bundleId>` copies a mapping made in the Controller tab into the
  repo to contribute a preset; `install <bundleId> | <file>.plist` copies into the container (lint,
  `.bak` of a different existing file).
