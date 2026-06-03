// Minimal reproduction: Flutter web does not write `autocapitalize` on
// its hidden <input class="flt-text-editing"> element, so the platform
// IME (e.g. Chromebook OSK) ignores TextCapitalization.none and
// auto-capitalizes the first letter.
//
// Run: `flutter run -d chrome`. Both fields are configured identically on
// the Dart side (TextCapitalization.none). The only difference is the
// workaround:
//
//   • Field 1 — Flutter default. autocapitalize is never written, so the
//     Chromebook OSK auto-capitalizes the first letter.
//   • Field 2 — workaround applied. We stamp autocapitalize="none" on the
//     hidden editing input when this field is focused, so the OSK starts
//     in lowercase.
//
// Each field reads back the autocapitalize attribute Flutter's editing
// input actually carries, so the difference is visible without DevTools.
// Flutter reuses a single editing input across fields, so we track which
// field is active via its FocusNode and let the DOM focusin handler decide
// whether to stamp.

import 'dart:js_interop';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

enum _Field { none, plain, workaround }

/// Which Flutter field currently holds focus. Set by each field's
/// FocusNode listener before Flutter creates/focuses the platform input.
final _activeField = ValueNotifier<_Field>(_Field.none);

/// Per-field snapshot of the `autocapitalize` attribute on the hidden
/// editing input, captured on focusin.
final _capturedPlain = ValueNotifier<String?>(null);
final _capturedWorkaround = ValueNotifier<String?>(null);

/// Insertion-time observer (stored so it is not garbage-collected).
// ignore: unused_element
web.MutationObserver? _observer;

/// Finds the flt-text-editing input in [el] or its descendants.
web.Element? _editingInput(web.Element el) {
  if ((el.getAttribute('class') ?? '').contains('flt-text-editing')) return el;
  return el.querySelector('.flt-text-editing');
}

void main() {
  if (kIsWeb) {
    // Primary fix for the hide -> reshow case: Flutter recreates its
    // editing element on blur, so on reshow it has no autocapitalize and
    // the OSK reads the missing attribute (caps) before focusin can stamp
    // it. Stamp at DOM-insertion instead — before .focus() and the OSK
    // read — so the fresh element behaves like a persistent native input.
    // _activeField is set by the field's FocusNode listener *before*
    // Flutter inserts the element, so we know which field it belongs to.
    _observer =
        web.MutationObserver(
          (JSArray<web.MutationRecord> records, _) {
            if (_activeField.value != _Field.workaround) return;
            for (final record in records.toDart) {
              final added = record.addedNodes;
              for (var i = 0; i < added.length; i++) {
                final node = added.item(i);
                if (node != null && node.isA<web.Element>()) {
                  _editingInput(
                    node as web.Element,
                  )?.setAttribute('autocapitalize', 'none');
                }
              }
            }
          }.toJS,
        )..observe(
          web.document.documentElement!,
          web.MutationObserverInit(childList: true, subtree: true),
        );

    web.document.addEventListener(
      'focusin',
      (web.Event event) {
        final target = event.target;
        if (target == null) return;
        final el = target as web.Element;
        if (!(el.getAttribute('class') ?? '').contains('flt-text-editing')) {
          return;
        }

        switch (_activeField.value) {
          case _Field.workaround:
            // Fallback stamp (element reuse) + capture.
            el.setAttribute('autocapitalize', 'none');
            _capturedWorkaround.value = el.getAttribute('autocapitalize');
          case _Field.plain:
            _capturedPlain.value = el.getAttribute('autocapitalize');
          case _Field.none:
            break;
        }
      }.toJS,
    );
  }
  runApp(const PocApp());
}

class PocApp extends StatelessWidget {
  const PocApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
    title: 'Flutter web autocapitalize repro',
    home: PocHome(),
  );
}

class PocHome extends StatelessWidget {
  const PocHome({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Flutter web autocapitalize repro')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Both fields use TextCapitalization.none. Tap each one and '
              'compare the autocapitalize attribute (and, on a Chromebook, '
              'whether the on-screen keyboard starts in lowercase).',
            ),
            const SizedBox(height: 24),
            _DemoField(
              field: _Field.plain,
              title: '1. Flutter default (no workaround)',
              captured: _capturedPlain,
            ),
            const SizedBox(height: 24),
            _DemoField(
              field: _Field.workaround,
              title: '2. Workaround applied on focus',
              captured: _capturedWorkaround,
            ),
            const SizedBox(height: 24),
            const _NativeInputSection(),
          ],
        ),
      ),
    );
  }
}

/// A genuine browser `<input autocapitalize="none">` embedded via
/// [HtmlElementView], bypassing Flutter's text-editing machinery
/// entirely. It is the control: if the Chromebook OSK *still* opens with
/// Shift active for this native input, the residual capitalization is a
/// Chrome OS OSK bug, not something Flutter (or our workaround) causes.
class _NativeInputSection extends StatelessWidget {
  const _NativeInputSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        border: Border.all(color: Colors.blue.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '3. Native <input autocapitalize="none"> (control)',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          const Text(
            'Not a Flutter TextField — a raw browser input. If the OSK '
            'still capitalizes here, it is a Chrome OS bug.',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 40,
            child: HtmlElementView.fromTagName(
              tagName: 'input',
              onElementCreated: (Object element) {
                (element as web.HTMLElement)
                  ..setAttribute('type', 'text')
                  ..setAttribute('autocapitalize', 'none')
                  ..setAttribute('autocomplete', 'off')
                  ..setAttribute('placeholder', 'Native input — type here')
                  ..setAttribute(
                    'style',
                    'width:100%;height:40px;font-size:16px;'
                        'box-sizing:border-box;padding:8px;'
                        'border:1px solid #90a4ae;border-radius:4px;',
                  );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A `TextField` (always `TextCapitalization.none`) that marks itself as
/// the active field on focus and shows the resulting `autocapitalize`
/// attribute Flutter's editing input carries.
class _DemoField extends StatefulWidget {
  const _DemoField({
    required this.field,
    required this.title,
    required this.captured,
  });

  final _Field field;
  final String title;
  final ValueNotifier<String?> captured;

  @override
  State<_DemoField> createState() => _DemoFieldState();
}

class _DemoFieldState extends State<_DemoField> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _focusNode
      ..removeListener(_onFocusChange)
      ..dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (_focusNode.hasFocus) {
      _activeField.value = widget.field;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isWorkaround = widget.field == _Field.workaround;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isWorkaround ? Colors.green.shade50 : Colors.amber.shade50,
        border: Border.all(
          color: isWorkaround ? Colors.green.shade300 : Colors.amber.shade300,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            focusNode: _focusNode,
            textCapitalization: TextCapitalization.none,
            decoration: const InputDecoration(labelText: 'Type here'),
          ),
          const SizedBox(height: 12),
          ValueListenableBuilder<String?>(
            valueListenable: widget.captured,
            builder: (context, value, _) {
              if (value == null) {
                return const Text(
                  'autocapitalize = <not captured yet — tap the field>',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 13),
                );
              }
              return Text(
                'autocapitalize = "$value"',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              );
            },
          ),
        ],
      ),
    );
  }
}
