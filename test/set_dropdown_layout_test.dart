import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stand-in for the set symbol, so the trailing slot can be found by type.
class _Trailing extends StatelessWidget {
  const _Trailing();

  @override
  Widget build(BuildContext context) => const SizedBox(width: 20, height: 20);
}

const _fieldWidth = 400.0;
const _sets = {'lea': 'Limited Edition Alpha', 'sld': 'Secret Lair Drop'};

/// Mirrors the Set picker in the Print Data tab: an expanded dropdown whose rows
/// put the name on the left and the set symbol hard against the right.
Widget _dropdown({String? value}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: _fieldWidth,
          child: DropdownButtonFormField<String>(
            initialValue: value,
            isExpanded: true,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: _sets.entries
                .map(
                  (e) => DropdownMenuItem(
                    value: e.key,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${e.key.toUpperCase()} — ${e.value}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const _Trailing(),
                      ],
                    ),
                  ),
                )
                .toList(),
            onChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a row with a flexible label lays out without overflowing', (
    tester,
  ) async {
    await tester.pumpWidget(_dropdown(value: 'lea'));
    // Expanded inside a DropdownMenuItem throws if the item is ever handed
    // unbounded width, which is what isExpanded guards against.
    expect(tester.takeException(), isNull);
  });

  testWidgets('the symbol sits against the right edge of the field', (
    tester,
  ) async {
    await tester.pumpWidget(_dropdown(value: 'lea'));

    // Rects are global, so everything is measured against the field's own box
    // rather than against absolute coordinates.
    final field = tester.getRect(
      find.byType(DropdownButtonFormField<String>),
    );
    // The closed field stacks every item at the same offset, so any of them
    // reports the position the selected row occupies.
    final trailing = tester.getRect(find.byType(_Trailing).first);
    final label = tester.getRect(find.text('LEA — Limited Edition Alpha'));

    expect(
      trailing.left,
      greaterThan(label.left),
      reason: 'symbol should follow the name, not precede it',
    );
    expect(
      trailing.right,
      greaterThan(field.left + field.width * 0.8),
      reason: 'symbol should be justified right, not floating mid-row',
    );
    expect(
      trailing.right,
      lessThanOrEqualTo(field.right),
      reason: 'symbol should stay inside the field',
    );
  });

  testWidgets('rows still lay out when the menu is open', (tester) async {
    await tester.pumpWidget(_dropdown(value: 'lea'));

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Both sets are offered, each with its own trailing slot.
    expect(find.text('SLD — Secret Lair Drop'), findsWidgets);
  });

  testWidgets('a long set name ellipsizes instead of pushing the symbol out', (
    tester,
  ) async {
    await tester.pumpWidget(_dropdown(value: 'sld'));

    final field = tester.getRect(
      find.byType(DropdownButtonFormField<String>),
    );
    final trailing = tester.getRect(find.byType(_Trailing).first);

    expect(tester.takeException(), isNull);
    expect(
      trailing.right,
      lessThanOrEqualTo(field.right),
      reason: 'a long name must ellipsize rather than push the symbol out',
    );
  });
}
