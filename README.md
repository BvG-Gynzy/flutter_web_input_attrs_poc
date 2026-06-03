# Flutter web — `TextCapitalization` not applied to the hidden editing input

Minimal reproduction of a Flutter web bug that affects the Chromebook
on-screen keyboard (OSK):

**`TextCapitalization.none` is ignored.** Flutter web does not write any
`autocapitalize` attribute on its hidden `<input class="flt-text-editing">`
element, so the platform IME falls back to its default. On Chromebook OSK
that means the first letter is auto-capitalized regardless of what is
passed on the Dart side, diverging from iOS (where the engine *does* set
the attribute).

> A separate symptom — the Gboard suggestion strip showing even with
> `enableSuggestions: false` — turned out to be a Gboard policy issue, not
> an attribute-level one (Gboard ignores `autocomplete`/`spellcheck`
> regardless of who sets them). Already closed as such in
> [flutter/flutter#182535](https://github.com/flutter/flutter/issues/182535).
> This PoC is scoped to the `autocapitalize` bug only.

## Repro

**Live demo:** https://bvg-gynzy.github.io/flutter_web_input_attrs_poc/
(open from any device — particularly useful for testing on a real
Chromebook OSK).

Or run locally:

```bash
flutter run -d chrome
```

The page has two text fields, **both configured identically on the Dart
side** (`TextCapitalization.none`). The only difference is the workaround:

- **Field 1 — Flutter default.** `autocapitalize` is never written.
- **Field 2 — workaround applied.** A `focusin` listener (registered from
  Dart via `package:web`) stamps `autocapitalize="none"` on the hidden
  editing input when this field is focused.

Each field reads back the `autocapitalize` attribute its editing input
actually carries, so the difference is visible without DevTools.

### Expected

Both fields should report `autocapitalize = "none"`, and on a Chromebook
OSK both should start in lowercase.

### Actual (Flutter 3.41.7)

- Field 1: `autocapitalize = <not set>` → Chromebook OSK auto-capitalizes
  the first letter.
- Field 2: `autocapitalize = "none"` → Chromebook OSK starts lowercase.

On a **Chromebook** with the on-screen keyboard active (Settings →
Accessibility → Keyboard → Enable on-screen keyboard), field 1 engages
the Shift key at the start of typing while field 2 does not.

Desktop Chrome with a hardware keyboard will *show* the attribute
difference in each field's read-out but won't reproduce the visible
symptom — `autocapitalize` only affects virtual keyboards per the HTML
spec.

## Root cause in the Flutter web engine

All references below are to
`engine/src/flutter/lib/web_ui/lib/src/engine/text_editing/text_editing.dart`
in the Flutter SDK at version 3.41.7 (engine revision `7a53c052bc`).

### The implementation exists, but only the iOS and Android strategies call it

`TextCapitalizationConfig.setAutocapitalizeAttribute` in
`text_capitalization.dart:60` correctly maps `TextCapitalization.none` →
`"off"`, `.sentences` → `"sentences"`, etc. The mapping is fine.

The problem is **who calls it**:

| Line | Strategy | Calls `setAutocapitalizeAttribute`? |
|---|---|---|
| 1312 | `DefaultTextEditingStrategy.initializeTextEditing` (base) | ❌ no |
| 1759 | `IOSTextEditingStrategy.initializeTextEditing` | ✅ yes |
| 1915 | `AndroidTextEditingStrategy.initializeTextEditing` | ✅ yes |
| —   | `GloballyPositionedTextEditingStrategy` (inherits default; selected for Chrome OS / Chromebook) | ❌ no |
| —   | `SafariDesktopTextEditingStrategy` | ❌ no |
| —   | `FirefoxTextEditingStrategy` | ❌ no |

`createDefaultTextEditingStrategy` (line 2092) routes by platform:

```dart
if (iOS)          → IOSTextEditingStrategy        // calls it
else if (android) → AndroidTextEditingStrategy    // calls it
else if (webkit)  → SafariDesktopTextEditingStrategy   // does NOT
else if (firefox) → FirefoxTextEditingStrategy         // does NOT
else              → GloballyPositionedTextEditingStrategy  // does NOT  ← Chromebook lands here
```

A Chromebook reports as Blink + Linux/CrOS, falls into the final `else`,
and ends up with `GloballyPositionedTextEditingStrategy` — which never
sets the attribute. That's why each field's read-out shows `autocapitalize`
as `<not set>` on Chromebook (and on every desktop Chrome).

### Why Chromebook lands there — UA detection trace

Real Chrome OS User Agent (Chrome 137):

```
Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36
```

**Browser engine** — `browser_detection.dart:108`
(`detectBrowserEngineByVendorAgent`):

- `navigator.vendor` on Chrome OS = `"Google Inc."` → returns
  `BrowserEngine.blink`.

**Operating system** — `browser_detection.dart:150`
(`detectOperatingSystem`):

- `navigator.platform` on Chrome OS is `"Linux x86_64"` (the `CrOS`
  token only appears in the UA, **not** in `navigator.platform`).
- `platform.startsWith('Mac')` → false
- iPhone / iPad / iPod check → false
- `userAgent.contains('Android')` → **false** (UA has `CrOS`, `Chrome`,
  `Safari`, but no `Android`)
- `platform.startsWith('Linux')` → **true** → returns
  `OperatingSystem.linux`

Result: `(BrowserEngine.blink, OperatingSystem.linux)` → strategy
selector falls through every branch and lands on
`GloballyPositionedTextEditingStrategy`.

**The deeper issue:** Chrome OS is treated as plain Linux desktop. The
engine assumes "Linux ⇒ hardware keyboard, no IME hints needed", which
is wrong for Chromebooks that surface an on-screen keyboard. Even
adding `setAutocapitalizeAttribute` to the base strategy would silently
inherit the same wrong category for other IME-related decisions. A
complete upstream fix should also introduce `OperatingSystem.chromeOS`
(detected via the `CrOS` UA token) — or a more general
`hasOnScreenKeyboard` flag — and route it through the
`AndroidTextEditingStrategy` codepath for IME purposes.

## Proposed upstream fix

Two layers — both small.

**1. Apply the attribute from the base strategy.** In
`DefaultTextEditingStrategy.applyConfiguration`, after the `autocorrect`
line (1373):

```dart
config.textCapitalization.setAutocapitalizeAttribute(activeDomElement);
```

Once the base `applyConfiguration` writes `autocapitalize`, the iOS and
Android-specific overrides become redundant and can be deleted in the
same patch.

**2. Detect Chrome OS as a virtual-keyboard platform.** Add detection
in `detectOperatingSystem` (`browser_detection.dart:150`) — Chrome OS
can be identified by `userAgent.contains('CrOS')` before falling into
the `Linux` branch. Either:

- Add `OperatingSystem.chromeOS` and route it through
  `AndroidTextEditingStrategy` in `createDefaultTextEditingStrategy`
  (cleanest, but enum addition is API surface), or
- Introduce a more general `hasOnScreenKeyboard` predicate (true for
  iOS, Android, Chrome OS) and use it inside the strategy selector.

Layer 1 alone is enough to fix the immediate attribute leak. Layer 2 is
needed for any other IME-related code that branches on
`operatingSystem` to make correct decisions on Chromebook.

## Workaround

Until the engine is fixed, stamp `autocapitalize` from Dart via
`package:web` on focus of the field (what Field 2 demonstrates). This is
purely an HTML-level workaround and does not require patching Flutter
itself.

## Environment

Run `flutter doctor -v` and paste output when filing.
