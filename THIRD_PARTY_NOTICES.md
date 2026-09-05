# Third-Party Notices

These are licence terms, not credits. The thank-you list lives in `README.md`;
this file exists because some of the code below arrived under conditions that
travel with it.

crafty as a whole is distributed under the **GNU General Public License v3.0**
(see `LICENSE`), because it contains code derived from Floos, which is itself
GPLv3 because it derives from XIUI.

## xitools

`crafty.lua`'s core synth-tracking logic (packet parsing for starting and
finishing a synth, skill-up tracking, the recipe search/browse UI) started as
a line-for-line port of the `crafty` tool inside **xitools** by lin, along
with `utils/packets.lua`, `utils/ffxi.lua`, and the recipe data in `data/`
(`recipesByIngredients.lua`, `recipesBySkill.lua`, themselves generated from
an AirSkyBoat SQL export - see the comment at the top of that file).

xitools does not carry an explicit license file. It is used here with
attribution, consistent with how it circulates in the Ashita addon community.
If you are the author and want different terms applied, please open an issue.

## Floos / XIUI

crafty's window theming (`libs/theme.lua`, copied) and font loading
(`libs/fonts.lua`, adapted) are derived from **Floos**, a sibling Ashita
addon, which adapted its own theming and font-loading approach from
[XIUI](https://github.com/tirem/XIUI) by the XIUI contributors.

- **License:** GNU General Public License v3.0
- **Components used:** the DarkGold / OceanBlue / Plain / GreenGold colour
  palettes and `apply_style`/`pop_style` config styling (`libs/theme.lua`),
  and the bundled-font-name loading approach with its `SetWindowFontScale` /
  `PushFontSize` / `PushFont` fallback chain (`libs/fonts.lua`).
- **Changes from Floos:** `libs/fonts.lua` was rewritten to load faces from
  the user's own `%WINDIR%\Fonts` (with an optional override in
  `crafty/assets/fonts/`) instead of a bundled/downloaded copy; the rest of
  its structure is unchanged.

crafty is a separate addon and is not affiliated with or endorsed by the
Floos or XIUI projects.

## Fonts

No font files are bundled with crafty. The named fonts in `/crafty config` →
Font (Tahoma, Tahoma Bold, Segoe UI, Consolas, Verdana) are Microsoft Windows
fonts loaded directly from the user's own `C:\Windows\Fonts` at runtime -
never copied, redistributed, or downloaded. "Agave (Default)" is Ashita's
built-in ImGui font and needs no files at all. See
`assets/fonts/README.txt` for how to substitute your own `.ttf`.

## Original to crafty

`libs/economy.lua` (price tracking, profit/cost projection, the chat and
gil-delta price learners, recipe output overrides) is original to this addon.
Its price-list file format (`name:gil` lines) and merge behaviour follow the
shape of Floos's `item_index`, but the implementation is new.
