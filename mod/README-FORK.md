# AutoBattler — movement-only fork of BOTato

Local Brotato mod: **auto-move/dodge during waves only**. Every decision stays
manual (level-up picks, shop buy/reroll/lock/GO, crates/consumables, "next wave",
character/weapon/danger selection). This is structural: the fork installs **no**
shop or upgrade script extensions at all.

- Toggle: **Shift + Space** (persisted in `user://auto-battler-fork.cfg`).
- HUD: `AUTOPILOT: ON/OFF [Shift+Space]` in the top-left corner during runs.
- Verified against the installed Brotato **1.2.0.1** (Godot 3.7.dev, built-in
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

## Strategy upgrade (2.3.0)

The movement policy is still the candidate-action arbiter (score every heading,
pick the least-bad), but v2.3.0 adds four things on top:

- **Ranged standoff** — a kite term prices ending too close to the nearest
  target: the bot holds ~75% of weapon range (wider when hurt) instead of
  walking into contact. Melee/weaponless kits are untouched.
- **Opportunity terms** — quiet-floor tree felling (trees drop a consumable +
  material) and injured-fruit eating (a hurt potato now detours for fruit,
  which was only a tie-breaker before). Full-HP fruit is still left on the
  ground (the game vacuums leftovers at wave end).
- **2-ply lookahead** — after the greedy sweep the best few first moves are
  rolled one decision forward on the same threat model and re-scored
  (beam 4 x 8 headings, gamma 0.6), so "locally safe" moves that walk into a
  pocket can lose to ones that keep the next decision open.
- **Hit-adaptive caution** — losing >=12% of the bar in one decision starts a
  2 s alert that scales threat weights up 25%.

Every item has an exact control arm: `--arb-kite=0`, `--arb-tree=0`,
`--arb-food=0`, `--arb-plan=0`, `--arb-adapt=0`. New knobs:
`--arb-kite`, `--arb-kitehp`, `--arb-plan`, `--arb-beam`, `--arb-gamma`,
`--arb-planthreats`, `--arb-adaptgain`, `--arb-adaptsecs`, `--arb-tree`,
`--arb-food` (also accepted from `user://auto-battler-overrides.json`).

## Planning upgrade (2.5.0)

The 2-ply planner above is still a short-horizon tie-breaker (0.8 s first ply,
gamma-discounted 0.8 s second ply). Field report: "you can see with the naked
eye that it is about to be surrounded, but the bot does not plan ahead", plus
"it never plans a detour for high-value items". v2.5.0 adds a small structural
layer instead of more weight tuning:

- **Pre-emptive breakout** (`--arb-breakout=1`): forecasts the ring 1.8 s
  ahead (pursuers steer at us, bodies widen as the ring shrinks). When the
  largest gap is passable NOW but projected to be gone, the bot commits to a
  pursuit-rollout escape line and runs through the crowd (contact price is
  discounted for the duration; bullets, dashes and telegraphs stay full
  price). Ends when the nearest body is clear (>260 px) or the safety cap
  expires. `=0` is the exact 2.4.0 control arm.
- **Committed item goals** (`--arb-goal=1`): when the neighbourhood is calm,
  pick the best reward by value/ETA (evolution fruits, hurt fruit, trees),
  then keep a pull on it until collected / gone / something closes in. One
  extra "land on the item" candidate fixes the full-speed overshoot that used
  to park the bot half a step short. `--arb-goalw` scales the pull.
- **Walk-on pickup semantics** (`--arb-walk=1`): v2.4 passed DLC evolution
  consumables with a rim, which the arbiter read as a HELD revive zone (paid
  every frame inside the rim) -- the bot parked on the rim and never took the
  item. They are now tagged one-shot walk-on pickups.
- **Wave-end urgency** (`--arb-waveend=1`): meca/mutant fruits are NOT
  vacuumed at the wave horn; their value is scaled up to x4 as the walk time
  approaches the remaining wave time.
- **Pursuit-aware second ply** (`--arb-pursuit=1`): contact/dash threats are
  advanced toward the first-ply end position instead of straight, so a ring
  that closes while we turn is no longer projected as open.

The exact v2.4.0 control arm is all five switches at 0:
`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0`.
Offline closed-loop evidence, all switches and limits are in the repo's
`docs/TECHNICAL.md` §5.7. DLC-aware engage stances from 2.4.0 are unchanged
(`--arb-curse` / `--arb-evolved` / `--arb-evo`).

## Space planning & special targets (2.6.0)

v2.5.0 fixed the closing ring and the item detour, but a second play test still
saw the bot herded into the map edge and ignoring special monsters / drops:

- **Wall-band retreat** (`--arb-breakout`): inside 150 px of a wall with >=4
  bodies within 430 px, run the same wall-aware pursuit rollout back toward
  open floor and commit for 1.5 s. Unlike the ring breakout there is NO contact
  discount -- it is a retreat, not a push through the crowd. A 2 s cooldown
  stops wall ping-pong.
- **Open-floor potential** (`--arb-space`, weight 2.5, reach 380 px): a
  tie-breaker-sized pull toward open floor outside the wall term's 220 px
  reach, so locally-fine steps cannot drift the bot into the band.
- **Bounty approach** (`--arb-bounty`): when nothing is within 300 px and HP
  is above 35%, walk toward a tagged special target (boss/elite, spawner egg,
  cursed/evolved) up to 900 px away until it is inside 0.9x weapon range;
  abort when a body closes to 180 px, HP drops or the target disappears.
  world_view tags target tuples with the special class (3-field tuples are
  kept when bounty=0, the exact 2.5.0 form).
- **Special drops**: item/legendary crates are priced as `max(healing, 5/10)`
  (a crate is an item choice, not a 3 HP fruit); loot aliens move from 4 to 6
  so the goal layer plans the chase. Opt-outs: `--arb-boxes`, `--arb-bounty`.

The exact v2.4.0 control arm is all seven switches at 0:
`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0
--arb-space=0 --arb-bounty=0 --arb-boxes=0` (walk/waveend/box/bounty live in
world_view; the rest in the arbiter). Offline evidence: `docs/TECHNICAL.md`
§5.8 and the 19-check gate in `_research/planning-v250/gate/`.

## Contact-avoidance fix (2.6.1)

Third play-test report: "sometimes, in relatively simple situations, the
character bumps into a monster." Offline closed-loop reproduction (real contact
geometry: enemy Hitbox + player Hurtbox) showed a base cost-model bug, present
in the 2.4/2.6 control arms as well: with one dangerous chaser the bot settles
into a stable orbit ON TOP of the body and takes a contact hit every 0.7 s
until it dies (e.g. a 6-damage pursuer from 380 px: 17 hits, dead at 17.2 s).

- **Crowding terms now track pursuers** (`--arb-roomtrack`): `room` /
  `roomfar` projected a body with its froze velocity; a chaser closer than
  speed*horizon was projected THROUGH and past the player, so running away
  raised the computed crowding while orbiting lowered it. Contact bodies whose
  projection would pass us now project as pursuers that follow and stop at
  touching distance (same cap as the 2nd ply's pursuit forecast). Scoped to
  bodies SLOWER than the player (flight can actually open the gap); faster
  bodies keep the 2.6.0 projection. Only these two projections change:
  enclosure / blast counting / planning keep the old ones, and distant bodies
  are bit-identical.
- **Winding-up dash bodies are priced** (`--arb-windup`): a winding-up charger
  used to be represented only by its future lane (starting at launch), leaving
  its frozen, damaging body free to walk over. A contact threat with
  `T_END = launch` is added for the telegraph window.
- **Contact reach is never under-estimated** (`--arb-hitbox`): the contact price
  used the enemy Hurtbox radius while the game damages with the enemy Hitbox.
  Taking the larger conservative reach fixes the elite/boss under-estimate and
  the DLC non-circle (capsule) case. Plain trash keeps its exact old value.

The exact pre-2.6.1 control arm is all three switches at 0
(`--arb-roomtrack=0 --arb-windup=0 --arb-hitbox=0`); with the v2.5/v2.6
switches it reproduces v2.4.0 frame-for-frame in the gate. Offline evidence:
`docs/TECHNICAL.md` §5.9, `_research/planning-v250/gate/` (19/19 PASS),
`_research/planner-selftest/` (294 checks PASS), and the closed-loop
`_research/collision-bug/` suite.

## Unified opportunity planning (2.7.0)

Fourth play-test report: "special things still don't feel aggressive enough."
v2.6 did have a bounty approach and committed item goals, but offline probes
showed the whole opportunity layer was fenced off by four independent walls:

- **(A) visibility**: world_view only emitted targets inside its ordinary
  target reach (typically 620-680 px), so the 900 px bounty promise could never
  be used;
- **(B) binary safety gates**: a body within 300 px vetoed bounty and one
  within 320 px vetoed goals, independent of direction -- and a real wave
  almost always has a body that close, so the layer was effectively off;
- **(C) pull**: the value/ETA pull was smaller than a body's 10-40 contact
  price and decayed with distance, so a slight detour never won;
- **(D) value**: special targets reused the killability-priced target value,
  so a thick boss/elite could score below a trash mob.

v2.7.0 replaces (B)(C)(D) with one risk-adjusted opportunity planner and fixes
(A) in world_view:

- **Explicit value table** (scaled by `--arb-bounty`): boss/elite 30, spawner
  egg 40, cursed/evolved 18.
- **Route risk** estimated from the SAME threat model: closest approach per
  threat along the straight route, expected damage capped at 200. Commit only
  when `risk <= value*(0.10 + 0.20*agg) + 2*agg`; score =
  `value - risk - 0.5*eta`.
- **Risk dial** (`--arb-agg` 0/1/2): HP floors 0.55/0.35/0.20 and the special
  gather radius 900/1400/1600 px move together with the route-risk allowance.
- **Commitment**: 100 frames; released when inside firing range, the target
  disappears, or HP drops below floor*0.7, then a 15-frame cooldown. The pull
  scales with value (`clamp(10 + 0.6*value, 14, 34)` for targets, x1-2 for
  rewards) and a partial-speed "close-in" candidate stops the bot overshooting
  the firing edge.
- **Fleeing loot aliens**: world_view measures their velocity (6th reward
  field) and values them 8 while opp is on; the arbiter aims with two
  fixed-point interception iterations instead of chasing the tail.

`--arb-opp=0` restores the exact v2.6.1 behaviour: legacy `_update_goal` /
`_update_bounty`, old pulls, no target close-in, and world_view back to the old
target radius / reward tuple form. `--arb-agg` (0 conservative / 1 default /
2 aggressive) is inert when opp=0. The exact v2.4.0 control arm is now **all 13
switches at 0**:

```
--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0
--arb-space=0 --arb-bounty=0 --arb-boxes=0
--arb-roomtrack=0 --arb-windup=0 --arb-hitbox=0 --arb-opp=0 --arb-agg=0
```

(Earlier "exact v2.4.0 control arm" lists in this file are version-scoped; from
2.7.0 onwards `--arb-opp=0` is required as well.) Offline evidence:
`docs/TECHNICAL.md` §5.10 -- self-test 355/0, gate 27/0 including the new
F1/F2/E2b/E2c checks, closed-loop special approach 1.77/1.78 s (v2.6.1 never
gets there), fleeing loot alien caught 11.3 s -> 2.8 s (4.04x). Live A/B still
pending.

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
