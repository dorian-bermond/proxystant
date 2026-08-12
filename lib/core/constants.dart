const Duration kScryfallMinDelay = Duration(milliseconds: 100);
const int kScryfallMaxRetries = 5;

const Map<String, String> kScryfallHeaders = {
  'Accept': 'application/json',
  'User-Agent': 'MTGArtworkPicker/1.0 (Flutter; dorian.bermond@thot-it.com)',
};

const Duration kMagicVilleDelay = Duration(milliseconds: 150);
const int kMagicVilleMaxRetries = 5;

/// Frame value meaning "print the artwork raw, with no template".
///
/// Stored in `cards.frame` (and the project layout/type defaults) like any
/// template name, so it exports into its own `No Frame/<layout>/` folder. It is
/// deliberately distinct from a null frame, which means "nothing chosen yet" and
/// still inherits the project default — that difference is what lets the export
/// readiness report keep warning about the latter without nagging about a
/// deliberate raw print.
///
/// Not a member of [templateRegistry]: it has no preview asset and no layouts,
/// and nothing looks templates up by the stored frame value.
const String kNoFrame = 'No Frame';
