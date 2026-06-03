Follow-up with additional evidence that narrows the root cause and shows
the proposed fix would also resolve a second, more visible symptom.

## New symptom: hide → reshow re-capitalizes

On a Chromebook (real OSK), beyond the first-focus case:

1. Focus a Flutter `TextField` (`TextCapitalization.none`) — OSK opens lowercase.
2. Tap outside to dismiss the keyboard.
3. Focus the same field again — **the OSK reopens with Shift active and the
   first character is typed in uppercase.**

This recurs on every hide/reshow cycle, and it is the more user-visible
form of the bug (students dismiss and re-open the keyboard constantly).

## A native `<input autocapitalize="none">` does NOT have this problem

Side-by-side on the same Chromebook, same page, via `HtmlElementView`:

- Native `<input autocapitalize="none">`: hide → reshow stays **lowercase**.
- Flutter `TextField`: hide → reshow returns to **caps**.

The only difference is that the native element carries `autocapitalize`
*from creation and persistently*, whereas Flutter's editing element does
not.

## Why no app-side workaround can fix it (and why the engine fix will)

We tried stamping `autocapitalize="none"` on the editing element from app
code via a `focusin` listener and a `MutationObserver`. Diagnostic logging
on reshow shows the decisive ordering:

```
[osk] FOCUSIN; autocap-before=null      // focused element has NO attribute when the OSK reads it
[osk] INSERT input; autocap-before=none // MutationObserver callback (a microtask) fires AFTER focusin
[osk]   stamped; autocap-after=none
```

`focusin` is synchronous and is the earliest hook available to app code,
yet at that moment the focused element's `autocapitalize` is already
`null` — the OSK reads it right then and decides caps. The
`MutationObserver` callback is a microtask and therefore runs even later.
Setting `autocapitalize` on ancestors (`<html>`/`<body>`/parent) to rely
on inheritance also did not help — the OSK reads the focused element's own
attribute.

So Flutter creates and focuses the editing element *without*
`autocapitalize`, and there is no app-side seam before the OSK's
synchronous read at focus. The native-input comparison demonstrates that
if the attribute were present on the element at creation time (i.e. the
fix proposed in the original report — have
`DefaultTextEditingStrategy.applyConfiguration` /
`initializeTextEditing` call `setAutocapitalizeAttribute` so the base
strategy used on Chrome OS writes it), the element would behave exactly
like the native input and **both the first-focus and the hide→reshow
cases would be fixed**.

## Repro

Live (open on a Chromebook with the OSK enabled):
- Flutter (fields 1 = default, 2 = focusin workaround, 3 = native control):
  https://bvg-gynzy.github.io/flutter_web_input_attrs_poc/
- Pure-HTML native matrix (no Flutter):
  https://bvg-gynzy.github.io/flutter_web_input_attrs_poc/osk-native-test.html

Source: https://github.com/BvG-Gynzy/flutter_web_input_attrs_poc

## Note on a separate, OS-level facet

There is also a Chrome OS / Gboard global state bug (a field without
`autocapitalize` engages a sticky caps state that survives a full page
reload and is not reset by `autocapitalize="none"` on a subsequent field).
That one is outside Flutter's control and would need a Gboard fix. The
reshow case above is *not* that — it is reproducibly tied to Flutter
omitting the attribute, as the native-input control proves.
