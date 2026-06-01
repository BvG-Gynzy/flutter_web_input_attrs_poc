// Minimal reproduction: Flutter web does not write `autocapitalize` on
// its hidden <input class="flt-text-editing"> element, so the platform
// IME (e.g. Chromebook OSK) ignores TextCapitalization.none and
// auto-capitalizes the first letter.
//
// Run: `flutter run -d chrome`. Tap a field — captured DOM attributes
// from Flutter's hidden editing input appear in the live read-out panel.
// Use the toggle to apply the workaround and observe the difference both
// in the panel and on a Chromebook OSK.
//
// The workaround stamps autocapitalize="none". A post-frame / focusin
// stamp alone loses a race on the FIRST focus of a field: Flutter creates
// and focuses the input in one sequence and the OSK reads the
// still-missing attribute before the stamp lands (later focuses reuse the
// prior value, so the bug is first-focus-only). To win the race a
// MutationObserver stamps the input the instant Flutter inserts it, before
// .focus() completes.
//
// NOTE: this build uses the MutationObserver ONLY (no focusin fallback),
// to verify whether insertion-time stamping alone fixes the first-focus
// race on the Chromebook OSK.

import 'dart:js_interop';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

final _captured = ValueNotifier<Map<String, String?>>(const {});
final _workaroundEnabled = ValueNotifier<bool>(false);

void _stampIfEditingInput(web.Element el) {
  final target = (el.getAttribute('class') ?? '').contains('flt-text-editing')
      ? el
      : el.querySelector('.flt-text-editing');
  target?.setAttribute('autocapitalize', 'none');
}

/// Retroactively stamps any editing input already in the DOM. Needed only
/// in this PoC: toggling the workaround on does not make Flutter reinsert
/// (or refocus) an element the observer already skipped while it was off.
/// The observer still handles fresh insertions, so the first-focus race is
/// genuinely exercised whenever the toggle is enabled before focusing.
void _stampExistingInputs() {
  final nodes = web.document.querySelectorAll('.flt-text-editing');
  for (var i = 0; i < nodes.length; i++) {
    (nodes.item(i) as web.Element?)?.setAttribute('autocapitalize', 'none');
  }
}

void main() {
  if (kIsWeb) {
    // Primary fix: stamp the editing input the moment Flutter inserts it,
    // before the OSK reads attributes on focus.
    web.MutationObserver(
      (JSArray<web.MutationRecord> records, web.MutationObserver _) {
        if (!_workaroundEnabled.value) return;
        for (final record in records.toDart) {
          final added = record.addedNodes;
          for (var i = 0; i < added.length; i++) {
            final node = added.item(i);
            if (node != null && node.isA<web.Element>()) {
              _stampIfEditingInput(node as web.Element);
            }
          }
        }
      }.toJS,
    ).observe(
      web.document.body!,
      web.MutationObserverInit(childList: true, subtree: true),
    );

    web.document.addEventListener(
      'focusin',
      (web.Event event) {
        final target = event.target;
        if (target == null) return;
        final el = target as web.Element;
        final className = el.getAttribute('class') ?? '';
        if (!className.contains('flt-text-editing')) return;

        // Capture only — the MutationObserver does the stamping at DOM
        // insertion. (Testing insertion-only first; no focusin fallback.)
        _captured.value = {
          'autocapitalize': el.getAttribute('autocapitalize'),
          'autocorrect': el.getAttribute('autocorrect'),
          'autocomplete': el.getAttribute('autocomplete'),
          'spellcheck': el.getAttribute('spellcheck'),
          'inputmode': el.getAttribute('inputmode'),
        };
      }.toJS,
    );
  }
  runApp(const PocApp());
}

class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'Flutter web input-attribute repro',
    home: PocHome(),
  );
}

class PocHome extends StatelessWidget {
  const PocHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter web input-attribute repro')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: const [
            _Section(
              title: 'TextField with TextCapitalization.none',
              expected: 'autocapitalize="none" on the editing <input>',
              child: TextField(
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(labelText: 'Type here'),
              ),
            ),
            SizedBox(height: 24),
            _Section(
              title:
                  'TextField with autocorrect: false, enableSuggestions: false',
              expected:
                  'autocomplete="off" and spellcheck="false" on the editing <input>',
              child: TextField(
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(labelText: 'Type here'),
              ),
            ),
            SizedBox(height: 32),
            _WorkaroundToggle(),
            SizedBox(height: 16),
            _CapturedAttributesPanel(),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.expected,
    required this.child,
  });

  final String title;
  final String expected;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'Expected: $expected',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _WorkaroundToggle extends StatelessWidget {
  const _WorkaroundToggle();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _workaroundEnabled,
      builder: (context, enabled, _) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: enabled ? Colors.green.shade50 : Colors.amber.shade50,
            border: Border.all(
              color: enabled ? Colors.green.shade300 : Colors.amber.shade300,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Apply workaround on focus',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      enabled
                          ? 'Stamping autocapitalize="none" at DOM insertion '
                                '(MutationObserver only). Refocus a field to '
                                'see the effect.'
                          : 'Off — observing Flutter\'s default behavior.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              Switch(
                value: enabled,
                onChanged: (v) {
                  _workaroundEnabled.value = v;
                  if (v && kIsWeb) _stampExistingInputs();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CapturedAttributesPanel extends StatelessWidget {
  const _CapturedAttributesPanel();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, String?>>(
      valueListenable: _captured,
      builder: (context, attrs, _) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.grey.shade100,
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attributes on Flutter\'s hidden <input> (captured on focusin)',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              if (attrs.isEmpty)
                const Text('Tap a field above to capture.')
              else
                ...attrs.entries.map(
                  (e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${e.key} = ${e.value == null ? "<not set>" : '"${e.value}"'}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
