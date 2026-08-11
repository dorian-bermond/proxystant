/// Translation of template layout keys (as used by the template registry,
/// e.g. `transform_front`, `mdfc_back`) into predicates over the Scryfall
/// layout stored in `cards.layout` plus the card's face index.
///
/// Kept separate from template_registry.dart so the data layer can import it
/// without pulling in the (auto-generated) registry.
library;

enum FaceSide { any, front, back }

class LayoutPredicate {
  /// Scryfall layout values this template key applies to.
  final List<String> scryfallLayouts;
  final FaceSide face;

  /// When true (only for `normal`), also match cards whose layout is NULL or
  /// not covered by any other template key.
  final bool includeUnmappedLayouts;

  const LayoutPredicate(
    this.scryfallLayouts,
    this.face, {
    this.includeUnmappedLayouts = false,
  });
}

/// Union of all Scryfall layouts explicitly mapped by some template key —
/// used by the `normal` catch-all ("layout IS NULL OR layout NOT IN (...)").
const mappedScryfallLayouts = [
  'normal',
  'flip',
  'token',
  'emblem',
  'transform',
  'modal_dfc',
  'saga',
  'leveler',
  'adventure',
  'class',
  'battle',
  'planeswalker',
  'mutate',
  'prototype',
  'split',
];

LayoutPredicate layoutPredicateForTemplateKey(String templateKey) {
  switch (templateKey) {
    case 'normal':
      return const LayoutPredicate(
        ['normal', 'flip'],
        FaceSide.any,
        includeUnmappedLayouts: true,
      );
    case 'token':
      return const LayoutPredicate(['token', 'emblem'], FaceSide.any);
    case 'transform_front':
      return const LayoutPredicate(['transform'], FaceSide.front);
    case 'transform_back':
      return const LayoutPredicate(['transform'], FaceSide.back);
    case 'mdfc_front':
      return const LayoutPredicate(['modal_dfc'], FaceSide.front);
    case 'mdfc_back':
      return const LayoutPredicate(['modal_dfc'], FaceSide.back);
    case 'pw_tf_front':
      return const LayoutPredicate(['transform'], FaceSide.front);
    case 'pw_tf_back':
      return const LayoutPredicate(['transform'], FaceSide.back);
    case 'pw_mdfc_front':
      return const LayoutPredicate(['modal_dfc'], FaceSide.front);
    case 'pw_mdfc_back':
      return const LayoutPredicate(['modal_dfc'], FaceSide.back);
    default:
      // saga / leveler / adventure / class / battle / planeswalker / mutate /
      // prototype / split / ixalan …: template key == scryfall layout (or is
      // an effect-style key that simply won't match any card).
      return LayoutPredicate([templateKey], FaceSide.any);
  }
}
