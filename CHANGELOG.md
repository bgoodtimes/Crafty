# Changelog

All notable changes to crafty are recorded here.

## [2.1.0] - 2026-09-05

### Added
- Ingredients (and crystals) that are themselves a recipe result now open
  inline instead of being a dead end - drill straight into that item's own
  recipe, chained as deep as the data goes, with a cycle/depth guard.

## [2.0.0] - 2026-09-04

First public release. crafty started as a standalone port of the `crafty`
tool from the [xitools](../xitools) suite and grew into its own addon with a
themed UI and a full profit-tracking layer.

### Added
- DarkGold window theme (with OceanBlue, Plain, and GreenGold alternatives),
  adapted from Floos / XIUI.
- Editable crafting skill levels, inline on the main window and in config.
- **Profit tracking**: a shared master price list (`config/addons/crafty/prices.txt`,
  used by every character, not per-character), with a per-item grid editor,
  a bulk text editor, and file import/export.
- Automatic price learning from the chat log - AH and bazaar purchase/sale
  lines (price read from the line) and NPC shop buy/sell lines (price read
  from the resulting gil change, since those lines carry no amount).
- Per-recipe cost, break-even, margin, and "use it all" batch-profit
  projections, all decoupled so cost shows even without a sell price.
- **True cost**: per-unit cost computed from your own synth history, correctly
  handling recipes with variable yields (e.g. a Beeswax synth that can return
  2, 4, 6, or 8) by dividing total gil spent by total units actually produced.
- **Recipe output overrides**: fix synth results Horizon changed from retail
  (different yield, sometimes a different item), applied everywhere - the
  recipe list, the cost projection, and the live synth log - with
  import/export for sharing a set of fixes.
- **Favorites**: pin up to 15 recipes for one-click access instead of
  searching every time.
- **Session gil tracking**: gil P/L since login and since your first synth
  (with gil/hr), reset automatically on a character switch so one alt's gil
  never bleeds into another's numbers.
- Appearance controls: font family (loaded from the system's own fonts, none
  bundled) and text-size slider, plus background opacity / corner rounding /
  border thickness sliders layered on top of any theme.
- Diagnostics: `/crafty prices`, `/crafty pricetest`, `/crafty pricelog`.

### Fixed along the way
- Chat-line parsing now survives colour/format codes and the various phrasings
  Horizon actually sends (`"You buy the 12 wind crystals..."`,
  `"You buy 3 bone arrows from the shop."`, `"You sell a dragon mask to the
  shop."`).
- Settings now autosave reliably (a debounced save replaced a focus-based
  save that could silently skip).
- Prices no longer duplicate per character - they moved out of the
  per-character settings file into the shared master list, migrating each
  character's old local prices in once.

## [1.0.0]

Initial standalone port of xitools' `crafty` tool: crafting skill tracking,
synth history, and the recipe browser/search, unchanged from xitools apart
from packaging it as its own addon.
