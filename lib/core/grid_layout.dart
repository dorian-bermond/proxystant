import 'package:flutter/material.dart';

/// Shared sizing for the card-shaped grids: the cards list, a card's artworks,
/// and the frame picker.
///
/// These grids used to hard-code two columns, which fills a phone but stretches
/// each tile to several hundred pixels wide on a desktop window. Instead the
/// tile width is capped and the column count follows the available width, so the
/// same code gives two columns on a phone and as many as fit on a monitor.

/// Cards and artworks are the content being browsed, so their tiles stay large.
///
/// This is a *maximum*: the grid picks the fewest columns whose tiles do not
/// exceed it, so real tiles are somewhat narrower. At 200 a phone still lands on
/// the two columns it had before.
const double kCardTileMaxWidth = 200;

/// Frame previews are thumbnails in a picker rather than the content itself, so
/// they pack tighter — close to the fixed 88px they used to be on a phone.
const double kFrameTileMaxWidth = 100;

/// Past this many columns the previews stop being easier to compare, so extra
/// width goes into bigger thumbnails instead of yet more of them.
///
/// Chosen so a thumbnail never grows past [kCardTileMaxWidth] on a wide monitor:
/// a frame preview outsizing the cards it decorates reads as a mistake.
const int kFrameTileMaxColumns = 10;

/// Gutter between tiles, and the value [gridColumns] assumes when mirroring the
/// grid arithmetic.
const double kGridSpacing = 12;

/// Largest column count offered by the "cards per row" setting. Past this the
/// tiles are too small to tell apart on any window this app runs in.
const int kMaxForcedColumns = 12;

/// User override for how many tiles share a row, with an optional separate
/// value for landscape. A null count means "Auto" — size tiles to the window,
/// which is the behaviour when nothing is set.
@immutable
class GridColumnsSettings {
  final int? columns;
  final bool landscapeOverride;
  final int? landscapeColumns;

  const GridColumnsSettings({
    this.columns,
    this.landscapeOverride = false,
    this.landscapeColumns,
  });

  static const auto = GridColumnsSettings();

  /// The count to force for [orientation], or null to size by width.
  int? columnsFor(Orientation orientation) {
    final forced = landscapeOverride && orientation == Orientation.landscape
        ? landscapeColumns
        : columns;
    if (forced == null || forced < 1) return null;
    return forced;
  }

  GridColumnsSettings copyWith({
    int? columns,
    bool? landscapeOverride,
    int? landscapeColumns,
    bool clearColumns = false,
    bool clearLandscapeColumns = false,
  }) {
    return GridColumnsSettings(
      columns: clearColumns ? null : (columns ?? this.columns),
      landscapeOverride: landscapeOverride ?? this.landscapeOverride,
      landscapeColumns: clearLandscapeColumns
          ? null
          : (landscapeColumns ?? this.landscapeColumns),
    );
  }
}

/// Grid delegate for card-shaped tiles, sized by width rather than a fixed
/// column count. Works for both [GridView] and [SliverGrid].
///
/// Pass [columns] to force that many tiles per row instead — the "cards per
/// row" setting. Tiles then divide the width however narrow that makes them,
/// which is the point of forcing a count.
SliverGridDelegate cardGridDelegate({
  double maxTileWidth = kCardTileMaxWidth,
  double childAspectRatio = 0.75,
  double spacing = kGridSpacing,
  int? columns,
}) {
  if (columns != null && columns >= 1) {
    return SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      childAspectRatio: childAspectRatio,
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
    );
  }
  return SliverGridDelegateWithMaxCrossAxisExtent(
    maxCrossAxisExtent: maxTileWidth,
    childAspectRatio: childAspectRatio,
    crossAxisSpacing: spacing,
    mainAxisSpacing: spacing,
  );
}

/// The column count [cardGridDelegate] resolves to for [availableWidth].
///
/// This mirrors the arithmetic in [SliverGridDelegateWithMaxCrossAxisExtent] so
/// that layouts which are not grids — the frame gallery is a [Wrap], to keep its
/// tiles free to size to their own labels — line up with the real grids instead
/// of drifting by a column.
///
/// [availableWidth] is the space left for tiles, with surrounding padding
/// already subtracted. Pass [maxColumns] to stop a very wide window from
/// shrinking tiles indefinitely, or [columns] to force an exact count (the
/// "cards per row" setting), which overrides both the width and [maxColumns].
int gridColumns(
  double availableWidth, {
  double maxTileWidth = kCardTileMaxWidth,
  double spacing = kGridSpacing,
  int? maxColumns,
  int? columns,
}) {
  if (columns != null && columns >= 1) return columns;
  if (availableWidth <= 0 || !availableWidth.isFinite) return 1;
  final fit = (availableWidth / (maxTileWidth + spacing)).ceil();
  final fitted = fit < 1 ? 1 : fit;
  if (maxColumns != null && fitted > maxColumns) return maxColumns;
  return fitted;
}

/// Width of a single tile once [availableWidth] is divided into [columns] with
/// [spacing] between them.
double tileWidthFor(
  double availableWidth,
  int columns, {
  double spacing = kGridSpacing,
}) {
  if (columns <= 1) return availableWidth;
  final forTiles = availableWidth - spacing * (columns - 1);
  return forTiles <= 0 ? availableWidth : forTiles / columns;
}
