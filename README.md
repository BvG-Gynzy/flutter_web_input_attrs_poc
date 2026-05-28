# Flutter web — input attributes not applied to hidden editing input

Minimal reproduction of two Flutter web bugs that affect Chromebook / Android
virtual keyboards (Gboard OSK):

1. **`TextCapitalization.none` is ignored.** Flutter web does not write any
   `autocapitalize` attribute on its hidden `<input class="flt-text-editing">`
   element, so the platform IME falls back to its default. On Chromebook OSK
   that means the first letter is auto-capitalized regardless of what we pass
   on the Dart side.
2. **`enableSuggestions: false` is not enough to silence the Gboard
   suggestion strip.** Flutter web sets `autocomplete="on"` on the editing
   input (and leaves `spellcheck` unset), so Gboard still shows predictions.
   Already reported and closed as "not Flutter's problem" in
   [flutter/flutter#182535](https://github.com/flutter/flutter/issues/182535) —
   included here because the same DOM-level workaround handles both.

## Repro

```bash
flutter run -d chrome
```

Tap into either text field. A panel at the bottom of the page reads back
the live attributes on Flutter's hidden `<input class="flt-text-editing">`
element (captured via a `focusin` listener registered from Dart through
`package:web` — no DevTools or paste-in snippet required).

### Expected

```
autocapitalize = "none"
autocorrect    = "off"
autocomplete   = "off"
spellcheck     = "false"
```

### Actual (Flutter 3.41.7)

```
autocapitalize = <not set>     ← missing entirely
autocorrect    = "off"         ← respected
autocomplete   = "on"          ← ignored
spellcheck     = <not set>     ← never set
```

On a **Chromebook** with the on-screen keyboard active (Settings →
Accessibility → Keyboard → Enable on-screen keyboard), the visible
symptoms are:

- Shift key engaged at start of typing → first letter capitalized.
- Suggestion strip with autocomplete predictions visible above the keys.

Desktop Chrome with a hardware keyboard will *show* the missing/wrong
attributes in the panel but won't reproduce the visible symptoms —
`autocapitalize` only affects virtual keyboards per the HTML spec.

## Root cause in the Flutter web engine

All references below are to
`engine/src/flutter/lib/web_ui/lib/src/engine/text_editing/text_editing.dart`
in the Flutter SDK at version 3.41.7 (engine revision `7a53c052bc`).

### 1. `autocapitalize` — implementation exists, but only the iOS and Android strategies call it

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
sets the attribute. That's why the DevTools panel shows `autocapitalize`
as `<not set>` on Chromebook (and on every desktop Chrome).

#### Why Chromebook lands there — UA detection trace

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

### 2. `autocomplete` — hardcoded `"on"` when autofill info is present, no way to opt out

Two locations write `autocomplete`:

**`AutofillInfo.applyToDomElement` (line 531/541):**

```dart
element.autocomplete = autofillHint ?? 'on';   // ← forces "on" with no opt-out
```

**`DefaultTextEditingStrategy.applyConfiguration` (line 1362–1370):**

```dart
final AutofillInfo? autofill = config.autofill;
if (autofill != null) {
  autofill.applyToDomElement(activeDomElement, focusedElement: true);
} else {
  activeDomElement.setAttribute('autocomplete', 'off');   // only when no autofill config
}
```

A Flutter `TextField` populates `AutofillInfo` for nearly every case, so
the first branch runs and the attribute is forced to `"on"` unless the
caller provides a specific HTML autocomplete hint. The Dart-side
`enableSuggestions: false` never reaches this codepath.

### 3. `spellcheck` — never set

A grep for `'spellcheck'` / `spellCheck` across the web engine's
`text_editing/` directory returns **zero hits**. The attribute is simply
not produced.

### 4. `enableSuggestions` — sent by the framework, ignored by the web engine

The framework serializes `enableSuggestions` into
`TextInputConfiguration.toJson` and dispatches it over the platform
channel, but the web engine never reads it. The only related flag the
web engine consumes is `config.autocorrect` (line 1372–1373).

### Summary

| Attribute | Dart-side knob | Web engine behavior | Gap |
|---|---|---|---|
| `autocapitalize` | `TextCapitalization` | Set only in iOS/Android strategies | Missing on Chromebook (and every desktop browser) |
| `autocorrect` | `autocorrect: bool` | Writes `"on"`/`"off"` from `config.autocorrect` | ✅ Works |
| `autocomplete` | `enableSuggestions: bool` (intent) | Hardcoded `"on"` when autofill present | Ignores `enableSuggestions`; no path to "off" |
| `spellcheck` | `enableSuggestions: bool` (intent) | Never set | Not handled |

### Proposed upstream fix

Two layers — both small.

**1. Apply the attributes from the base strategy.** In
`DefaultTextEditingStrategy.applyConfiguration`, after the `autocorrect`
line (1373):

```dart
config.textCapitalization.setAutocapitalizeAttribute(activeDomElement);
if (!config.enableSuggestions) {
  activeDomElement.setAttribute('autocomplete', 'off');
  activeDomElement.setAttribute('spellcheck', 'false');
}
```

Plus: parse `enableSuggestions` from the framework message in
`InputConfiguration.fromFrameworkMessage` (currently dropped on the
floor). Once the base `applyConfiguration` writes `autocapitalize`, the
iOS and Android-specific overrides become redundant and can be deleted
in the same patch.

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

Until the engine is fixed, stamp the attributes from Dart via
`package:web` after a post-frame callback, on every focus of the
field. This is purely an HTML-level workaround and does not require
patching Flutter itself.

## Environment

Run `flutter doctor -v` and paste output when filing.
