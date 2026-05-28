# Web: text field input attributes (`autocapitalize`, `autocomplete`, `spellcheck`) not written to the editing element

> Sections below map 1:1 to the fields in Flutter's `Report a bug` issue
> template. Copy each `##` block into the matching form field on
> github.com when filing.

---

## Steps to reproduce

**Live demo (no setup):** https://bvg-gynzy.github.io/flutter_web_input_attrs_poc/
— open this URL on a Chromebook (with the on-screen keyboard enabled)
to see the bug end-to-end, or on desktop Chrome to verify the
attribute-level mis-configuration via DevTools.

Full source: https://github.com/BvG-Gynzy/flutter_web_input_attrs_poc

Alternatively, follow the inline steps below.

1. Create a Flutter web app with a `TextField` configured to opt out of
   keyboard suggestions and auto-capitalization:

   ```dart
   TextField(
     textCapitalization: TextCapitalization.none,
     autocorrect: false,
     enableSuggestions: false,
   )
   ```

2. Run on Chrome: `flutter run -d chrome`.
3. Focus the text field and inspect the hidden editing element
   `<input class="flt-text-editing">` in DevTools (Elements panel, or
   via `document.activeElement` in the Console with a `focusin`
   listener since clicking in DevTools blurs the field).
4. (Optional, to observe the user-facing symptom) Run on a Chromebook
   with the on-screen keyboard enabled (Settings → Accessibility →
   Keyboard → Enable on-screen keyboard) and observe the OSK behavior
   when typing.

## Expected results

The hidden editing element should have:

```
autocapitalize = "none"
autocorrect    = "off"
autocomplete   = "off"
spellcheck     = "false"
```

On a Chromebook OSK / Gboard:
- The first letter typed is lowercase (no shift engaged).
- No suggestion strip appears above the keys.

## Actual results

On Flutter 3.41.7, the hidden editing element has:

```
autocapitalize = <not set>     ← missing entirely
autocorrect    = "off"         ← respected
autocomplete   = "on"          ← ignored
spellcheck     = <not set>     ← never set
```

On a Chromebook OSK / Gboard:
- The first letter is auto-capitalized despite
  `TextCapitalization.none`.
- The Gboard suggestion strip is visible despite
  `enableSuggestions: false`.

Desktop Chrome with a hardware keyboard shows the same missing/wrong
attributes in DevTools but does not reproduce the visible symptoms,
because `autocapitalize` only affects virtual keyboards per the HTML
spec.

> Related (already closed as "Gboard issue"):
> [flutter/flutter#182535](https://github.com/flutter/flutter/issues/182535).
> This report is broader — it covers `autocapitalize` (not reported
> before as far as I can tell), traces the bug to specific lines in
> the engine source, and proposes a small upstream fix.

### Root cause

All references below are to
`engine/src/flutter/lib/web_ui/lib/src/engine/text_editing/text_editing.dart`
in Flutter 3.41.7 (engine revision `7a53c052bc`).

#### 1. `autocapitalize` — implementation exists, but only iOS and Android strategies call it

`TextCapitalizationConfig.setAutocapitalizeAttribute` in
`text_capitalization.dart:60` correctly maps `TextCapitalization.none`
→ `"off"`, `.sentences` → `"sentences"`, etc. The mapping is fine. The
problem is **who calls it**:

| Line | Strategy | Calls `setAutocapitalizeAttribute`? |
|---|---|---|
| 1312 | `DefaultTextEditingStrategy.initializeTextEditing` (base) | ❌ no |
| 1759 | `IOSTextEditingStrategy.initializeTextEditing` | ✅ yes |
| 1915 | `AndroidTextEditingStrategy.initializeTextEditing` | ✅ yes |
| —   | `GloballyPositionedTextEditingStrategy` (inherits default; default for Chrome OS / Chromebook) | ❌ no |
| —   | `SafariDesktopTextEditingStrategy` | ❌ no |
| —   | `FirefoxTextEditingStrategy` | ❌ no |

`createDefaultTextEditingStrategy` (line 2092) routes by platform:

```dart
if (iOS)          → IOSTextEditingStrategy        // calls it
else if (android) → AndroidTextEditingStrategy    // calls it
else if (webkit)  → SafariDesktopTextEditingStrategy   // does NOT
else if (firefox) → FirefoxTextEditingStrategy         // does NOT
else              → GloballyPositionedTextEditingStrategy   // does NOT
```

#### Why Chromebook lands in the broken bucket — UA detection trace

Chrome OS User Agent (Chrome 137):

```
Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36
```

Walking through `browser_detection.dart`:

- `detectBrowserEngineByVendorAgent` (line 108):
  `navigator.vendor === "Google Inc."` → `BrowserEngine.blink`.
- `detectOperatingSystem` (line 150): `navigator.platform` on Chrome OS
  is `"Linux x86_64"` (the `CrOS` token is in the UA, **not** in
  `navigator.platform`). `userAgent.contains('Android')` is false.
  `platform.startsWith('Linux')` → returns `OperatingSystem.linux`.

Result: `(BrowserEngine.blink, OperatingSystem.linux)` → strategy
selector falls through to `GloballyPositionedTextEditingStrategy`. The
engine treats Chrome OS as plain Linux desktop and assumes no IME
configuration is needed.

#### 2. `autocomplete` — forced to `"on"` when autofill info is present

**`AutofillInfo.applyToDomElement` (line 531/541):**

```dart
element.autocomplete = autofillHint ?? 'on';   // forces "on" with no opt-out
```

**`DefaultTextEditingStrategy.applyConfiguration` (lines 1362–1370):**

```dart
final AutofillInfo? autofill = config.autofill;
if (autofill != null) {
  autofill.applyToDomElement(activeDomElement, focusedElement: true);
} else {
  activeDomElement.setAttribute('autocomplete', 'off');   // only when no autofill
}
```

A standard `TextField` populates `AutofillInfo`, so the first branch
runs and `autocomplete` is forced to `"on"` unless the caller supplies
a specific HTML autocomplete hint. `enableSuggestions: false` is never
consulted on this path.

#### 3. `spellcheck` — never set

A grep for `'spellcheck'` / `spellCheck` across
`web_ui/.../text_editing/` returns zero hits.

#### 4. `enableSuggestions` — sent by the framework, ignored by the engine

The framework serializes `enableSuggestions` into
`TextInputConfiguration.toJson` and dispatches it over the platform
channel, but the web engine never reads it. The only related flag the
engine consumes is `config.autocorrect` (line 1372–1373).

### Proposed fix

Two layers — both small and independent.

**Layer 1 — apply the attributes from the base strategy.** In
`DefaultTextEditingStrategy.applyConfiguration`, after the `autocorrect`
line (1373):

```dart
config.textCapitalization.setAutocapitalizeAttribute(activeDomElement);
if (!config.enableSuggestions) {
  activeDomElement.setAttribute('autocomplete', 'off');
  activeDomElement.setAttribute('spellcheck', 'false');
}
```

Parse `enableSuggestions` in `InputConfiguration.fromFrameworkMessage`
(currently dropped). Delete the now-redundant
`setAutocapitalizeAttribute` calls in the iOS and Android overrides.

**Layer 2 — detect Chrome OS as a virtual-keyboard platform.** In
`detectOperatingSystem` (`browser_detection.dart:150`), Chrome OS can
be identified by `userAgent.contains('CrOS')` before falling into the
`Linux` branch. Either:

- Add `OperatingSystem.chromeOS` and route it through
  `AndroidTextEditingStrategy` in `createDefaultTextEditingStrategy`
  (cleanest, but adds enum surface), or
- Introduce a more general `hasOnScreenKeyboard` predicate (true for
  iOS, Android, Chrome OS) and use it inside the strategy selector.

Layer 1 alone fixes the immediate attribute leak. Layer 2 is needed
for any other IME-related code that branches on `operatingSystem` and
currently makes the wrong call on Chromebook.

## Code sample

A full runnable repository (with `package:web` and a `focusin` listener
that surfaces the attributes back into the UI, so the bug is visible
without DevTools) is available at
https://github.com/BvG-Gynzy/flutter_web_input_attrs_poc. The minimal
inline sample below is sufficient to demonstrate the bug:

<details open><summary>Code sample</summary>

```dart
import 'package:flutter/material.dart';

void main() => runApp(const MaterialApp(home: Page()));

class Page extends StatelessWidget {
  const Page({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: const [
            // Expect autocapitalize="none" on the editing <input>.
            TextField(textCapitalization: TextCapitalization.none),
            SizedBox(height: 16),
            // Expect autocomplete="off" and spellcheck="false" on the
            // editing <input>.
            TextField(autocorrect: false, enableSuggestions: false),
          ],
        ),
      ),
    );
  }
}
```

</details>

## Screenshots or Video

<details open>
<summary>Screenshots / Video demonstration</summary>

[Upload media here — Chromebook OSK with capital first letter and the
suggestion strip is the clearest demonstration.]

</details>

## Logs

<details open><summary>Logs</summary>

```console
[No exception is thrown; the attributes are simply not written.
No log output is produced by this bug.]
```

</details>

## Flutter Doctor output

<details open><summary>Doctor output</summary>

```console
[✓] Flutter (Channel stable, 3.41.7, on macOS 26.4.1 25E253 darwin-arm64, locale en-NL)
    • Flutter version 3.41.7 on channel stable
    • Upstream repository https://github.com/flutter/flutter.git
    • Framework revision cc0734ac71 (6 weeks ago), 2026-04-15 21:21:08 -0700
    • Engine revision 59aa584fdf
    • Dart version 3.11.5
    • DevTools version 2.54.2

[!] Android toolchain - develop for Android devices (Android SDK version 34.0.0)
    ✗ Flutter requires Android SDK 36 and the Android BuildTools 28.0.3
    ! Some Android licenses not accepted.

[✓] Xcode - develop for iOS and macOS (Xcode 26.5)
    • Build 17F42
    • CocoaPods version 1.16.2

[✓] Chrome - develop for the web

[✓] Connected device (2 available)
    • macOS (desktop) • macos  • darwin-arm64   • macOS 26.4.1 25E253 darwin-arm64
    • Chrome (web)    • chrome • web-javascript • Google Chrome 148.0.7778.179

[✓] Network resources
    • All expected network resources are available.
```

Symptoms also reproduce on **Chrome OS** (Chromebook, Chrome 137):

```
Mozilla/5.0 (X11; CrOS x86_64 14541.0.0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36
```

</details>
