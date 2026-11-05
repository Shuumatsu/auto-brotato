# AutoBattler — movement-only fork of BOTato

Local Brotato mod: **auto-move/dodge during waves only**. Every decision stays
manual (level-up picks, shop buy/reroll/lock/GO, crates/consumables, "next wave",
character/weapon/danger selection). This is structural: the fork installs **no**
shop or upgrade script extensions at all.

- Toggle: **Shift + Space** (persisted in `user://auto-battler-fork.cfg`).
- HUD: `AUTOPILOT: ON/OFF [Shift+Space]` in the top-left corner during runs.
- Verified against the installed Brotato **1.1.15.4** (Godot 3.7.dev, built-in
  godot-mod-loader **6.3.0**).

## Files installed

| File | Purpose |
|---|---|
| `mod_main.gd` | installs exactly 2 script extensions |
| `extensions/entities/units/movement_behaviors/player_movement_behavior.gd` | overrides `get_movement()`: arbiter steering when enabled, vanilla input otherwise |
| `extensions/ui/menus/pages/main_menu.gd` | creates the `/root/AutobattlerOptions` singleton (config + hotkey + HUD) |
| `autobattler_options.gd` | config, Shift+Space, HUD, `--arb-*` overrides |
| `steering/arbiter.gd`, `steering/world_view.gd` | BOTato's MIT steering/perception core; `world_view.gd` also contains the build-trait profile inference |

Removed vs upstream BOTato: auto-shop, auto level-up picks, co-op bot slots,
co-op mouse helpers, debug telemetry/canvas, ModOptions dependency, Lovense.

## Adaptive behaviour profile (2.2.0)

Behaviour priors are **inferred from measured build traits** instead of looked up
from the hand-written per-character table: survivability (max HP vs mitigation),
lifesteal / HP regen, whether weapons can fire while moving (`can_attack_while_moving`),
standing/moving bonuses, contact payoffs (explosion on hit), owned structures, and
material-economy effects (gold pickups, food mechanics, trees). The inference emits the same row keys the existing
resolvers already consume (caution, lethality, fire_still, still, pin, engage,
anchor, orbit, ...), so the arbiter itself is unchanged.

Startup modes: `--arb-profile=auto` (default; ignore the table),
`--arb-profile=table` (old hand-written rows), `--arb-profile=merge`
(inferred row wins, table fills keys the inference omits).
`--arb-charprofile=0` still disables all character-specific logic (control arm).

Economy preferences are inferred from mechanics too (pickup-gold damage/reload,
consumable healing/explosion, tree effects, harvesting). Known v1 gaps: rare
build-specific passives may still fall back to generic values; extreme builds
may want `--arb-*` overrides.

## Install (Steam)

The Steam build's ModLoader only loads zips from **subscribed Workshop item
folders** (it does not read `<Brotato>/mods`). Copy this zip next to an
already-installed Workshop mod, then start the game through Steam:

```
~/Library/Application Support/Steam/steamapps/workshop/content/1942280/<item_id>/
```

The repo's `install.sh` does this automatically (`./install.sh`, `--remove`,
`--list`, `--item <id>`). Alternatively upload this zip as your own Workshop
item via the game's `GodotWorkshopUtility.app` for a permanent install.

Non-Steam builds (GOG/Epic): copy the zip into `<Brotato>/mods/`.

## Tuning

`--arb-every=2` (decide every other tick, lower CPU), `--arb-every=0` (adaptive),
`--arb-profile=auto|table|merge` (profile source), `--arb-charprofile=0` (disable all
character logic). Knob names are in
`steering/arbiter.gd` → `apply_overrides()`.

## Credits / license

Steering core and structure from **[BOTato](https://github.com/boardengineer/botato)**
by boardengineer / Pasha, **MIT License** (see `LICENSE-BOTato-MIT.txt`).
This fork only trims, adapts and documents it.
