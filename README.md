# crafty

A standalone port of the `crafty` tool from the **xitools** suite by lin, for
[Ashita v4](https://www.ashitaxi.com/) on Final Fantasy XI / HorizonXI.

`crafty` is a crafting skill tracker and recipe list:
- tracks your crafting skill levels as you gain skillups (it reads them from
  synth result packets, so it learns as you craft)
- logs a history of your synths with result quality, skillups, and lost materials
- lets you search the full recipe list and shows, per recipe, whether you meet
  the skill / key item requirements and how many of each ingredient you hold

## install
Drop the `crafty` folder into `Game/addons/` and load it:

```
/addon load crafty
```

Add `/addon load crafty` to your `scripts/default.txt` to load it on boot.

## usage
- `/crafty` (or `/craft`) — toggle the main window
- `/crafty config` — toggle the settings window
- `/crafty clear` (or `/crafty cl`) — clear the synth history
- `/crafty gil` — reset the session gil P/L baseline to right now
- `/crafty prices` — print how many price lines are loaded and parsed
- `/crafty pricetest <a purchase/sale line>` — dry-run the chat price learner
  against a line you paste, and print what it parsed (item, qty, gil, match)
- `/crafty pricelog` — toggle. Appends every incoming chat line to
  `config/addons/crafty/textlog.txt` (file only, no chat spam). Use it to see
  the exact wording/route of a purchase line that isn't being captured.

### editing skill levels
The tracker learns your levels from skill-up packets, but you can set them by hand
two ways:
- on the main window, click **edit** next to the *Crafting Skills* header to turn
  the read-out into eight input boxes; click **done** to go back
- in `/crafty config` → *Crafting skills*, one labelled box per craft

Edits are clamped to 0–200. All settings (skills, overrides, favorites, toggles)
autosave about a second after you stop editing, and again on unload.

## profit tracking
Prices are a **shared master list** — `config/addons/crafty/prices.txt` — used
by every character, not saved per-character. Price Imperial Cermet once on any
alt and every other character already has it. (Before this, prices lived inside
each character's own settings and had to be re-entered per alt; the first time
each character loads after this change, whatever prices it had built up locally
are folded into the shared list once, then its local copy is cleared.) The file
sits next to the per-character settings folders, so it's easy to find and back
up on its own.

`/crafty config` → **Prices** lets you enter what materials and products are
worth. Three ways in:
- **per item** — a grid of every item any synth has touched (crystal,
  ingredients, product, losses); type the gil you buy/sell each for
- **full list** — a `item name:gil` text box, one per line
- **import / export** — read/write a `name:gil` file (bare filename resolves
  under `config/addons/crafty/`) for merging in a market-scrape file or keeping
  a backup; the shared list itself is `prices.txt` in that same folder
- **learn from chat** (on by default, toggle in the same panel) — watches the
  game log for trade lines and prices from them:
  - `You bought 12 pieces of willow lumber for 500 gil.` (AH — price is in the line)
  - `You buy an oak log from Someone for 3000 gil.` (bazaar — price is in the line)
  - `You buy 3 bone arrows from the shop.` (NPC — **no price in the line**, so it
    reads the amount from your gil change over the next moment)
  - `You sell a dragon mask to the shop.` (NPC sell — same, gil-change based)
  - `You sold ... for ... gil.` (AH sell — prices your **products**)

  It strips the leading `the`/`a`/`an` and stack count, divides by the count, and
  updates that item's price. Crystals are always recognised; other items must be
  ones you've crafted with (or nameable by the resource DB). It prints what it
  learned — `[crafty] bought bone arrow = 100g (npc, 300g total)` — and says once
  per phrase when it can't match something. Test wording with `/crafty pricetest`.

Each ingredient line in a recipe shows its entered price (or `(no price)`), and
the projection shows a partial `cost so far` with a count of how many inputs
still need a price — so you can tell exactly what's missing instead of a blanket
"set prices". `/crafty prices` prints how many price lines are loaded.

## session gil
Under the skill readout on the main window: your **start** gil, your gil **now**,
and the difference (green/red). No time or rate — just a running session total.

Read straight from inventory gil, so it counts every source — drops, vendors,
AH, bazaar, quests. The start value is taken a couple of seconds after you're
loaded in (so a zone-in transient never becomes the baseline) and resets on a
character change or a logout/login. `/crafty gil` or the **reset** button
re-baselines it to now.

With prices entered:
- the **Craft History** table gains a **Profit** column (green/red per synth); a
  synth priced with a missing value shows `?`
- a summary line above it: net gil, priced/total count, gil/hr (from synth
  timestamps), HQ %, success %
### recipe output overrides
Horizon changes some synth results from retail (different yield, sometimes a
different item). Expand a recipe in **Recipe List**, click **edit** on the
`output:` line, set the real yield (and optionally a different result item by
name), and **save**. The override is stored per character in
`config/addons/crafty/` and layered on top of the bundled recipe data — the big
`data/*.lua` files are never rewritten. It applies everywhere: the list label,
the cost/profit projection, and the live synth log. **reset to default** on the
recipe, or the list in `/crafty config` → *Recipe output overrides*, removes it.
That panel also has **Import / Export** to a plain-text file (bare filename
resolves under `config/addons/crafty/`) for sharing a set of Horizon fixes.

### projections
- each recipe in **Recipe List** shows:
  - **makeable now** — how many synths your current inventory can do (crystal +
    ingredients, duplicates counted), read live from the item tracker, plus a
    rough total time to churn through them all (`~22s` per synth)
  - **cost + break-even/ea** as soon as the crystal and ingredient prices are
    known — the result price is *not* required for this. Next to it, a
    **save to price list** button writes that per-unit crafted cost in as the
    result item's price — handy for an intermediate synth (e.g. Imperial Cermet)
    you make only to feed another recipe.
  - **make all N: cost** — total material cost to use up your inventory
  - once the result price is also set: **sell / margin per synth**, and
    **use it all** total profit if you craft every synth your inventory allows
  - **edit price** button on the sell line — set the result item's per-unit
    price right there, no need to open config (works on the "set the result
    price for margin" line too, before any price is entered)

Cost model: a success costs crystal + all ingredients; a failure costs crystal +
only the materials in the `lost` list (the rest come back). Revenue is the
product price × count, keyed by the item actually produced (so HQ items that are
a different item id are valued correctly).

## drill-down ingredients
Any ingredient (or crystal) that is itself a recipe result is shown as an
expandable line, not a dead end - open it to see that item's own recipe right
there, nested inline, with its own skill checks, prices, cost, and favourite
toggle. Chain as deep as the data goes (e.g. an item made from a component
that's made from another component). If an item has more than one recipe, each
is listed as its own expandable "recipe N" entry to choose from. Guarded
against a cyclic or absurdly deep chain (5 levels, or a loop back to a recipe
already open above it), which real recipe data should never hit.

## favorites
Expand any recipe (in **Recipe List** or **Favorites**) and click
**add to favorites** / **remove from favorites**. Favorited recipes get their own
**Favorites** header at the top of the main window — click one to open it with
the full skill/ingredient/cost/profit view, no searching. Up to 15, saved per
character.

## appearance
The UI uses the DarkGold palette and window styling from **Floos**, a sibling
Ashita addon (itself adapted from [XIUI](https://github.com/tirem/XIUI)).
Four themes are selectable in `/crafty config` → Appearance:
DarkGold (default), OceanBlue, Plain, and GreenGold. Skill-requirement checks,
ingredient counts, and synth results are colour-coded (green met / red missing).

Two more panels tune the *feel* on top of whichever theme is active:
- **Font** — a family picker (Tahoma Bold, Tahoma, Segoe UI, Consolas, Verdana,
  or Ashita's built-in **Agave** which needs no files) and a **Text Size**
  slider (75%–200%). The named fonts load straight from `C:\Windows\Fonts`, so
  nothing is bundled or downloaded; drop a same-named `.ttf` in
  `crafty/assets/fonts/` to use your own copy instead. If a face fails to load
  it falls back to the default font and prints once to say so.
- **Panel style** — background opacity, corner rounding, and border thickness
  sliders, plus a **reset to defaults** button. These apply on top of any theme,
  independent of which one is selected.

## license
crafty is distributed under the **GNU General Public License v3.0** - see
[LICENSE](LICENSE). That is inherited, not chosen: `libs/theme.lua` and
`libs/fonts.lua` are derived from Floos, which is GPLv3 because it derives
from XIUI. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for exactly
which files came from where.

## credit
- Crafting logic, packet parsing, and recipe data from xitools by lin
  (`crafty.lua`, `utils/packets.lua`, `utils/ffxi.lua`, `data/`).
- Theme palettes and config styling from Floos / XIUI (`libs/theme.lua`).
- Font loading (`libs/fonts.lua`) is adapted from Floos' `libs/fonts.lua`,
  pointed at the system font folder instead of bundled files.
- `libs/economy.lua` (profit tracking) is original to this addon; its price-list
  format and file merge follow Floos' `item_index`.

See [CHANGELOG.md](CHANGELOG.md) for version history.
