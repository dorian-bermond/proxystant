import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_artwork_picker/core/grid_layout.dart';

/// Widths of the window, before the grids' own padding is taken off.
const _phone = 390.0;
const _tablet = 820.0;
const _desktop = 1440.0;

/// Both card grids sit inside `EdgeInsets.all(12)`.
const _cardGridPadding = 12.0 * 2;

/// Marker for the grid's own tiles. A generic widget would also match the ones
/// MaterialApp paints (its full-bleed background box lands at dy 0 and would be
/// mistaken for the first row).
class _Tile extends StatelessWidget {
  const _Tile();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

/// Lays out a grid at [width] and reports how many tiles share the first row.
Future<int> _renderedColumns(
  WidgetTester tester,
  double width, {
  int? columns,
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: cardGridDelegate(columns: columns),
        itemCount: 40,
        itemBuilder: (_, i) => const _Tile(),
      ),
    ),
  );

  // Group the first row by identical vertical offset. Indexed off the finder
  // rather than the widget objects, which are const and so share one identity.
  final finder = find.byType(_Tile);
  final tops = [
    for (var i = 0; i < finder.evaluate().length; i++)
      tester.getTopLeft(finder.at(i)).dy,
  ];
  final firstRowTop = tops.reduce((a, b) => a < b ? a : b);
  return tops.where((dy) => dy == firstRowTop).length;
}

void main() {
  group('gridColumns', () {
    test('a phone keeps the two columns it had before', () {
      expect(gridColumns(_phone - _cardGridPadding), 2);
    });

    test('column count grows with the window', () {
      final phone = gridColumns(_phone - _cardGridPadding);
      final tablet = gridColumns(_tablet - _cardGridPadding);
      final desktop = gridColumns(_desktop - _cardGridPadding);

      expect(tablet, greaterThan(phone));
      expect(desktop, greaterThan(tablet));
    });

    test('tiles never exceed the maximum width', () {
      for (final width in [320.0, _phone, 600.0, _tablet, 1100.0, _desktop]) {
        final columns = gridColumns(width);
        expect(
          tileWidthFor(width, columns),
          lessThanOrEqualTo(kCardTileMaxWidth),
          reason: 'width $width resolved to $columns columns',
        );
      }
    });

    test('degenerate widths do not produce a zero or negative column count', () {
      expect(gridColumns(0), 1);
      expect(gridColumns(-100), 1);
      expect(gridColumns(double.infinity), 1);
      expect(gridColumns(double.nan), 1);
    });

    test('frame thumbnails pack tighter than cards at the same width', () {
      final cards = gridColumns(_phone);
      final frames = gridColumns(
        _phone,
        maxTileWidth: kFrameTileMaxWidth,
        spacing: 8,
        maxColumns: kFrameTileMaxColumns,
      );
      expect(frames, greaterThan(cards));
    });

    test('a frame thumbnail never outgrows a card tile', () {
      for (final width in [_phone, 600.0, _tablet, 1280.0, _desktop, 1920.0]) {
        final frames = gridColumns(
          width - 32,
          maxTileWidth: kFrameTileMaxWidth,
          spacing: 8,
          maxColumns: kFrameTileMaxColumns,
        );
        expect(
          tileWidthFor(width - 32, frames, spacing: 8),
          lessThanOrEqualTo(kCardTileMaxWidth),
          reason: 'at window width $width the cap lets thumbnails grow too far',
        );
      }
    });

    test('maxColumns turns extra width into bigger tiles, not more of them', () {
      final frames = gridColumns(
        _desktop,
        maxTileWidth: kFrameTileMaxWidth,
        spacing: 8,
        maxColumns: kFrameTileMaxColumns,
      );
      expect(frames, kFrameTileMaxColumns);
      // Capped, so each tile is now wider than the uncapped target.
      expect(
        tileWidthFor(_desktop, frames, spacing: 8),
        greaterThan(kFrameTileMaxWidth),
      );
    });
  });

  group('cardGridDelegate', () {
    testWidgets('lays out two columns at phone width', (tester) async {
      expect(await _renderedColumns(tester, _phone), 2);
    });

    testWidgets('lays out more columns as the window widens', (tester) async {
      final phone = await _renderedColumns(tester, _phone);
      final tablet = await _renderedColumns(tester, _tablet);
      final desktop = await _renderedColumns(tester, _desktop);

      expect(tablet, greaterThan(phone));
      expect(desktop, greaterThan(tablet));
    });

    testWidgets('rendered columns match what gridColumns predicts', (
      tester,
    ) async {
      for (final width in [_phone, _tablet, _desktop]) {
        expect(
          await _renderedColumns(tester, width),
          gridColumns(width - _cardGridPadding),
          reason: 'at window width $width',
        );
      }
    });

    testWidgets('a forced count wins over the window width', (tester) async {
      for (final width in [_phone, _tablet, _desktop]) {
        expect(
          await _renderedColumns(tester, width, columns: 5),
          5,
          reason: 'at window width $width',
        );
      }
    });

    testWidgets('a forced count of 1 is honoured', (tester) async {
      expect(await _renderedColumns(tester, _desktop, columns: 1), 1);
    });
  });

  group('forced columns', () {
    test('overrides the width and the maxColumns cap', () {
      expect(gridColumns(_phone, columns: 6), 6);
      expect(
        gridColumns(
          _desktop,
          maxTileWidth: kFrameTileMaxWidth,
          maxColumns: kFrameTileMaxColumns,
          columns: 3,
        ),
        3,
      );
    });

    test('a nonsensical count falls back to width-driven sizing', () {
      expect(gridColumns(_phone - _cardGridPadding, columns: 0), 2);
      expect(gridColumns(_phone - _cardGridPadding, columns: -3), 2);
    });
  });

  group('GridColumnsSettings', () {
    const portrait = Orientation.portrait;
    const landscape = Orientation.landscape;

    test('auto means no forced count in either orientation', () {
      expect(GridColumnsSettings.auto.columnsFor(portrait), isNull);
      expect(GridColumnsSettings.auto.columnsFor(landscape), isNull);
    });

    test('one value applies to both orientations by default', () {
      const s = GridColumnsSettings(columns: 4);
      expect(s.columnsFor(portrait), 4);
      expect(s.columnsFor(landscape), 4);
    });

    test('the landscape value is used only when the override is on', () {
      const off = GridColumnsSettings(columns: 3, landscapeColumns: 7);
      expect(off.columnsFor(landscape), 3);

      const on = GridColumnsSettings(
        columns: 3,
        landscapeOverride: true,
        landscapeColumns: 7,
      );
      expect(on.columnsFor(portrait), 3);
      expect(on.columnsFor(landscape), 7);
    });

    test('landscape can be Auto while portrait is forced', () {
      const s = GridColumnsSettings(columns: 3, landscapeOverride: true);
      expect(s.columnsFor(portrait), 3);
      expect(s.columnsFor(landscape), isNull);
    });

    test('copyWith can clear a value back to Auto', () {
      const s = GridColumnsSettings(columns: 4, landscapeColumns: 6);
      expect(s.copyWith(clearColumns: true).columns, isNull);
      expect(
        s.copyWith(clearLandscapeColumns: true).landscapeColumns,
        isNull,
      );
      // A plain copyWith keeps what was already there.
      expect(s.copyWith(landscapeOverride: true).columns, 4);
    });
  });
}
