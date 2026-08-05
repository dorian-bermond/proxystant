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

/// Grid delegate for card-shaped tiles, sized by width rather than a fixed
/// column count. Works for both [GridView] and [SliverGrid].
SliverGridDelegate cardGridDelegate({
  double maxTileWidth = kCardTileMaxWidth,
  double childAspectRatio = 0.75,
  double spacing = kGridSpacing,
}) {
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
/// shrinking tiles indefinitely.
int gridColumns(
  double availableWidth, {
  double maxTileWidth = kCardTileMaxWidth,
  double spacing = kGridSpacing,
  int? maxColumns,
}) {
  if (availableWidth <= 0 || !availableWidth.isFinite) return 1;
  final fit = (availableWidth / (maxTileWidth + spacing)).ceil();
  final columns = fit < 1 ? 1 : fit;
  if (maxColumns != null && columns > maxColumns) return maxColumns;
  return columns;
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
