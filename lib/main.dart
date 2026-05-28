// Minimal reproduction: Flutter web ignores TextCapitalization and the
// autocomplete/spellcheck side of `enableSuggestions` when rendering its
// hidden <input class="flt-text-editing"> element.
//
// Run: `flutter run -d chrome`. Tap a field — captured DOM attributes
// from Flutter's hidden editing input appear in the live read-out panel.
//
// Expected: autocapitalize="none", autocomplete="off", spellcheck="false".
// Actual:   autocapitalize is missing, autocomplete="on", spellcheck unset.

import 'dart:js_interop';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

final _captured = ValueNotifier<Map<String, String?>>(const {});

void main() {
  if (kIsWeb) {
    web.document.addEventListener(
      'focusin',
      (web.Event event) {
        final target = event.target;
        if (target == null) return;
        // Match Flutter's hidden editing element by class.
        final el = target as web.Element;
        final className = el.getAttribute('class') ?? '';
        if (!className.contains('flt-text-editing')) return;
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
      body: Padding(
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
