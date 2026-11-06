extends Reference

# Turns live game state into the plain arrays the arbiter scores.
#
# The split is deliberate: everything that knows about Brotato's node layout
# lives here, and the scorer knows only geometry. That keeps the scorer
# replayable offline against recorded states, which is what weight tuning and
# any later learned scorer both need.

const BODY_RADIUS_FALLBACK = 20.0
const THREAT_RANGE = 620.0       # threats past this cannot reach us inside the horizon
const PICKUP_RANGE = 900.0
const STATIONARY_SPEED_SQ = 100.0

# -- Pillar lifecycle --
#
# From pillar_projectile.tscn's "shoot" animation (length 1.05 s). Its method
# track fires disable_hitbox at 0, enable_hitbox at 0.54, disable_hitbox again
# at 0.68, stop at 1.04. So a pillar is LETHAL FOR 0.14 s out of 1.05 -- 13% of
# its life -- and is a completely harmless telegraph for the 0.54 s before that.
#
# A pillar is a CLOCK, not a wall, and that distinction is the whole gargoyle
# problem. Its State1 attack lays down 25 stationary pillars over a 700 px
# spread; pricing each as live from the instant it appears makes that field read
# as solid, when in fact most of it is passable at any given moment and there is
# a timed corridor straight through. The old model could not see time, so it
# could not see the corridor.
# These are the PILLAR's numbers and they are only a fallback. Stationary
# attacks do not share a clock: a gargoyle pillar is armed 0.54-0.68 of a 1.05 s
# animation, a butcher slash 0.48-0.60 of a 0.70 s one. Hardcoding one type's
# timings mistimes every other -- and it mistimes them in the DANGEROUS
# direction, telling the bot a blade arms later than it does. So the window is
# read off each projectile's own animation and these only apply when that fails.
const AOE_ARM_FALLBACK = 0.54
const AOE_DISARM_FALLBACK = 0.68
const INF_TIME = 1e9             # "does not stop being a threat inside any horizon"
const AOE_RADIUS_MULT = 1.5      # disc widening for a circular telegraph over its hit
                                 # collision. Was 2.2, which -- with the base.length()
                                 # double-count now removed -- modeled a croc ring pillar
                                 # (23 px hit) as ~110 px, closing the 157 px ring into a
                                 # solid wall (Jack croc 0/35). 1.5 opens it; measured
                                 # neutral+ on the pillar beds (butcher 8/8=8/8 via the
                                 # blade path, colossus 6/8->7/8 at 1.0), croc 0->1-2/8.
var aoe_mult = AOE_RADIUS_MULT   # --arb-aoemult
const AOE_RADIUS_MAX = 320.0

# -- Blade decomposition --
#
# A gargoyle pillar is a blob; a butcher's slash is a 273 x 28 px blade that
# sweeps 265 px in the 0.12 s it is armed. Collapsing both into one circle is
# what makes the slash undodgeable: reach = 136.5 + 19 = 155, times
# AOE_RADIUS_MULT, caps at a 320 px disc -- against a hitbox that is 14 px thin
# in the direction the dodge actually happens. Roughly 23x too wide.
#
# Two failures follow, and they compound. The dodge that works (a ~40 px step
# perpendicular to the blade) is not representable at all. And since slashes
# spawn ON the player and arm in 0.48 s, escaping a 320 px disc is impossible at
# ~300 px/s net -- so every candidate direction scores badly, the term goes flat
# across the compass, and it stops discriminating. That is the same saturation
# that made room18 score 0/10.
#
# So an elongated hitbox becomes a LINE of small circles along its long axis.
# The threat model stays circles-only -- the scorer is untouched -- but the thin
# perpendicular gap becomes expressible.
const BLADE_SEGMENTS_MAX = 6     # cap: a 10:1 blade would otherwise cost 10 threats
const BLADE_MARGIN = 1.25        # the blade sweeps ~37 px between physics frames,
                                 # and we only sample it once, so pad a little
const DEFAULT_PROJ_DAMAGE = 6.0
const DEFAULT_CONTACT_DAMAGE = 5.0
const AOE_DAMAGE = 10.0

# Reuse the arbiter's tuple layout.
const KIND_PROJ = 0
const KIND_CONTACT = 1
const KIND_DASH = 2
const KIND_AOE = 3
const KIND_MARK = 4              # spawn-marker keep-out; contact-priced only

const TARGET_EXTRA = 220.0       # targets are collected this far past weapon range,
                                 # matching the arbiter's acquisition band
const KILL_HP_REF = 20.0         # killability falloff floor; see _refresh_kill_ref --
                                 # the live reference is the player's own measured
                                 # DPS, so "killable" means killable BY THIS BUILD
const KILL_TIME = 1.0            # seconds of sustained fire that define "killable":
                                 # a body that dies inside one second of shooting is
                                 # halfway killable at exactly ref = its HP
const KILL_REF_MAX = 600.0       # sanity cap; past this everything reads killable
                                 # anyway and a bad stats read cannot go to infinity
const EXPECTED_EXCHANGES = 2.0   # contacts an unkilled enemy gets before it dies anyway
const EGG_VALUE = 60.0           # a spawner is worth far more dead than its own damage
                                 # suggests: everything it hatches is future damage too

# -- Character profiles --
#
# Generic steering prices every pickup and every position the same way for
# every character; some characters break those assumptions by design and the
# fix belongs HERE, in the layer that knows what a character IS, not in the
# scorer. The scorer stays pure geometry: it is handed a profile dictionary
# of already-resolved numbers and never learns a character's name.
#
# Research behind the table lives in CHARACTER-PROFILES.md next to this file
# (decompiled effect data + wiki + per-character Danger 5 guides). The design
# rule from that research: 63 characters do NOT need 63 behaviours. They need
# six reusable mechanisms, and a character is a row of numbers selecting them.
#
#   gold / gold_phases / gold_mode   what a material on the floor is worth
#   food                             what a consumable on the floor is worth
#   caution / caution_phases         multiplier on every threat weight
#   engage (+engage_hp/engage_pack)  contact seeking; the inverse of kiting
#   anchor (+radius/inner/wave)      a place worth fighting near, or away from
#   still                            "prefer" standing, or "never" stand
#
# Absent character or absent key = baseline, so the table only records real
# deviations and an unlisted character behaves exactly as before. The whole
# layer is ablatable with --arb-charprofile=0, which is the honest control arm
# for every claim any of these rows makes.
#
# First profile, and the worked example for the rest: the Builder.
#
# The Builder converts materials left uncollected at wave end into turret
# stats (RunData.add_bonus_gold -> convert_bonus_gold -> structure_range,
# which is the turret's level/size XP: +1% attack speed and +1 range per 5
# materials, +1 projectile at 30/150/300), takes -75% stat gains from
# normal pickup and -30 pickup range. Gold on the ground is therefore worth
# MORE than gold in the bag -- but not always, and not equally.
#
# The material policy is PHASED, following Cephalopocalypse's Danger 5
# guide ("The GIGATURRET"): waves 1-4 collect EVERYTHING, because economy
# and defensive stats have to come online before the turret matters and a
# starved shop loses the run before the turret can win it; from wave 5
# feed the turret -- leave materials down until it hits its final tier at
# 300 structure_range ("power up the turret by wave 12 so it can kill the
# elite"); once maxed, materials only buy attack speed/range at steep
# diminishing returns, so go back to taking SOME ("not all of them") for
# levels and defense -- priced mildly positive so the bot picks up what it
# passes but never detours hard.
#
# The turret itself only shoots what comes within ITS range, and the only
# thing that reliably drags enemies through that circle is the player
# standing in it ("let the elite explode on our turret", "stay near our
# turret so the bosses die to it"). The anchor hands the arbiter the
# turret's position and range so staying near it is a scored preference,
# not an override. It engages with the feed phase, not before: phase 1 is
# a roaming-collection phase, and a leash would cost every material lying
# outside it.
const GOLD_VALUE = 0.8
# Extra pull toward gold/material drops -- but ONLY when the floor near the player
# is quiet (no live enemy within GOLD_DRAW_QUIET_RADIUS). A flat always-on boost
# tanked survival (WR w18/18/20 -> w9/14/20 at just 1.2x): with many drops down,
# their pickup pulls sum and yank the bot into danger. Gating on "no enemy close"
# keeps the greed for the calm windows between spawn bursts -- which is exactly
# where a human vacuums the free money -- without ever pulling into a fight.
# Applies to the ground-material reward only (not food, not standing income).
const GOLD_PICKUP_DRAW = 1.5
const GOLD_DRAW_QUIET_RADIUS = 280.0  # no live enemy within this = safe to grab greedily
const SWEEP_RADIUS = 420.0       # no enemy inside this = a quiet field, sweep the drops
# -- Scapegoat --
# item_scapegoat spawns a pet that enemies target INSTEAD of the player; when
# it dies, a player standing inside its HealingTriggeringZone (100 px circle,
# 20 px above the body) refills it over revive_duration (3 s) and it rises
# (entities/units/pet/scapegoat/scapegoat.gd). A dead goat is therefore worth
# a walk and a 3-second stand: every hit it would have drawn lands on us
# instead. Priced as a HELD reward -- the arbiter pays REVIVE_VALUE to any
# move that ends inside the zone, so leaving it costs the same each frame.
# --arb-revive=<mult> sweeps it (0 = off).
const REVIVE_VALUE = 30.0        # ~two expected hits; the goat tanks far more than that
const SCAPEGOAT_ZONE = 100.0
const SCAPEGOAT_ZONE_OFFSET = Vector2(0, -20)
var revive_mult = 1.0            # --arb-revive
var _goat_dead = {}              # instance id -> seconds dead (telemetry)
var sweep_override = -1.0        # --arb-sweep: force the row's sweep multiplier
var dash_fix = 1.0               # --arb-dashfix=0: revert the dash speed/duration model
var pickup_radius = 150.0        # the player's ItemAttractArea radius this frame
const BUILDER_ECON_WAVES = 4     # last wave of collect-everything (guide: "wave four or five")
const BUILDER_GOLD_VALUE = -2.0  # feed phase: mild -- shapes paths between equals,
                                 # never outbids a dodge
const BUILDER_GOLD_LATE = 0.4    # maxed turret: take what we pass, skip detours
const BUILDER_TURRET_MAX_LEVEL = 3
const BUILDER_ANCHOR_MIN = 140.0 # leash radius bounds around the turret's own range.
const BUILDER_ANCHOR_MAX = 240.0 # Was 220-420: at a tier-2+ turret (range 640) that
                                 # resolved to 420, and the guide's play is ON the
                                 # turret from mid-game ("playing directly on top of
                                 # the turret"). Sweep via --arb-leash=<radius>.
const BUILDER_ANCHOR_W = 2.5     # row anchor_w: x the global W_ANCHOR (12). The leash
                                 # is linear past the radius, so this is the slope --
                                 # 30 per 300 px strayed, enough to walk back through
                                 # a crowd's room cost, still under any live threat.

# -- Mechanism constants --
#
# Scale note, because it decides whether any of this is safe: the arbiter
# prices a threat at 15-65 after lethality scaling, and the pickup term is
# w_pickup(1.0) * value * closed. So every gold number below is a TIE-BREAKER
# between otherwise-similar candidates and none of them can outbid a dodge.
# Food and engage sit an order higher (up to ~12), matching w_dps at 14 --
# they are allowed to shape a fight, never to walk into a corridor.
const ENGAGE_PACK_RADIUS = 320.0 # "is a pack forming" test for the herders
const FOOD_MAX = 12.0            # cap on the healing one fruit is priced at
const FOOD_BANK_FULL = -0.8      # hoarders price stepping on fruit at full HP as a
                                 # mild COST: the ground is the safest inventory
const FOOD_FULL_SEEK = 6.0       # characters PAID for eating at full HP
const FOOD_BOMB_RADIUS = 220.0   # chef/glutton: a fruit is a grenade, and its value
const FOOD_BOMB_PER = 3.0        # is the enemies standing in its blast, not its heal
const FOOD_BOMB_MAX = 9.0
const FOOD_BOMB_ALONE = -1.5     # detonating on an empty floor wastes the whole pickup

# -- v2.3.0 tactics defaults (the world_view half) --
# A felled tree drops a consumable + material (main.gd _on_neutral_died ->
# spawn_loot), which is free income for EVERY kit whenever the floor is quiet.
# Ordinary kits therefore get a small default living-tree value instead of 0.
# Deliberately below the explicit tree kits (pacifist 5.0, tree-mechanic 6.0)
# and below any live threat: it only bends a path that was already safe.
# --arb-tree scales it; 0 restores "ordinary kits ignore trees" exactly.
const DEFAULT_TREE_VALUE = 3.0
# Hurt fruit is an OPPORTUNITY, not a tie-breaker. At missing HP one fruit is
# worth up to FOOD_MAX * food_mult (30 at the 2.5 default) -- enough to shape a
# fight (the w_dps tie is 14), still under a genuine 15-65 threat once the
# pickup term's distance discount is applied. The cap MUST scale with the
# multiplier: a flat FOOD_MAX cap is <= 12, which the old min(FOOD_MAX,
# missing_hp) already saturates at 12+ missing HP, so the multiplier would be a
# no-op exactly on the damage levels the player-reported bug is about.
# --arb-food=1 reproduces the old value exactly; 0 restores the old unscaled
# formula exactly (control arm).
const FOOD_INJURED_MULT = 2.5
# profile["kite_frac"] when the build carries a RANGED weapon: the share of
# weapon range the arbiter's standoff term should hold. 0.0 for all-melee /
# weaponless kits, so the kite term stays inert for them.
const KITE_FRAC_RANGED = 0.75
const METER_COOLDOWN_MIN = 12.0  # buccaneer: frames of cooldown that make a weapon
                                 # worth spending a pickup to reset
const LOOT_VALUE = 4.0           # a fleeing loot alien, for characters that can catch one
# -- v2.6.0: opportunity values (special targets / special drops) --
# Field report: "it still does not go after special monsters or their drops."
# Two gaps: (1) loot aliens were priced at 4 (a tie-breaker next to a fight)
# and no target tag told the arbiter which bodies are WORTH a committed
# approach (boss/elite, spawner egg, cursed/evolved); (2) item boxes were
# priced only as healing food (heal 3 / heal 100 capped at 12), so at full HP
# a crate was worth nothing to the scorer even though it contains an item.
# --arb-bounty=0 / --arb-boxes=0 restore the exact 2.5.0 values and tuple
# arity (A/B control arms).
const LOOT_BOUNTY_VALUE = 6.0    # loot alien when bounty is on (>= GOAL_MIN_VALUE)
const BOX_VALUE = 5.0            # a normal item crate: one item choice
const LEGENDARY_BOX_VALUE = 10.0 # legendary crate: one legendary item choice
const BIRTH_STEP_COST = 4.0      # avoid_births: a red X priced as a small standing AoE.
                                 # Stepping on one relocates (bull) or cancels (pacifist,
                                 # jack, king) the spawn -- a real cost, never a lethal
                                 # one, so it must lose to every genuine threat

# -- v2.4.0 DLC defaults (the world_view half) --
#
# Cursed enemies (DLC1 Abyssal Terrors) and evolved enemies (DLC2 Primal Dread)
# are ordinary bodies with a boost stacked on top: a curse adds at least +200%
# HP, +50% damage and +75% speed (curse_scene_effect_behavior: hp_boost 200 +
# 2*min(curse,300)); an evolution adds +50..+350% HP, +25..+80% damage and
# +5..+25% speed (evolution_scene_effect_behavior). Killing them is what the
# DLC PAYS for (+33% material value on both, curse-scaling item effects, and
# the evolution-consumable drops), but the generic pricing sees the opposite:
# the bigger HP pool shrinks the killability factor in _kill_value while the
# boosted contact damage grows the threat. That is the reported bug -- the bot
# backs out of exactly the fights the player took the DLC to fight. The default
# stance is therefore ENGAGE: scale the TARGET value so keeping the body inside
# weapon range is worth doing, leaving the threat side untouched. Both knobs
# are signed, so the documented opposite stance ("some cases should avoid
# cursed enemies") is one flag away:
#   v > 0   target value x v                            (engage)
#   v < 0   target value 0, threat damage x (1 + |v|)   (avoid; -1 -> x2)
#   v == 0  no number changes (exact v2.3.0 control arm)
const CURSE_TARGET_MULT = 3.0      # --arb-curse: cursed target value x3
const EVOLVED_TARGET_MULT = 2.5    # --arb-evolved: meca/mutant target value x2.5
#
# Evolution pickups. The four Primal Dread consumables are progression, not
# healing: a meca/mutant fruit is one point of stat_evolution (a permanent camp
# commitment), a mutation fruit opens the wave-end "mutate an item" choice, and
# meca parts are the weapon-evolution currency. None of them can be attracted
# (Player.can_attract_consumable_data excludes the two fruits, and the attract
# area only pulls heal-effect items), so the bot must physically walk over
# them. The old food pricing -- 0 at full HP, NEGATIVE for bank kits -- could
# never justify that walk, which is why they lay on the floor all wave.
const EVO_FRUIT_VALUE = 6.0        # meca/mutant fruit (stat_evolution +-1)
const EVO_MUTATION_VALUE = 9.0     # mutation fruit (wave-end mutate choice)
const EVO_PARTS_VALUE = 6.0        # meca parts (2 parts, weapon evolution currency)
# Reward rim for an evolution pickup. player.tscn's ItemPickupArea is a
# radius-32 circle 24 px above the body, plus the item's own radius (~8-10 px):
# the physical pickup is ~40 px. A rim-0 reward only has the linear approach
# gradient, and that gradient dies AT zero -- the bot parks on the edge of the
# pickup circle and never steps in. So the 4th tuple field (rim) pays the FULL
# value to a move that ENDS inside it, which is the step this pickup actually
# needs; the item leaves _consumables the frame it is taken.
#
# v2.5.0 adds a 5th tuple field, the WALK-ON tag: [pos, value, false, rim, 1.0].
# The old arbiter read "rim > 0" as HELD, i.e. "stay inside this circle and keep
# scoring every frame" (correct for the scapegoat revive zone, wrong here), so
# a v2.4 4-tuple made the bot park ON the rim and never take the item. r[4]=1.0
# says one-shot walk-on pickup; the 4th field keeps its rim-radius meaning.
# --arb-walk=0 drops r[4] (exact v2.4 4-tuple), the A/B control arm.
const EVO_WALK_RIM = 45.0
const EVO_WALK_TAG = 1.0
# v2.5.0 wave-end urgency. meca_fruit / mutant_fruit are the two evolution
# pickups with attracted_at_end_of_wave=false: the attract area NEVER takes them
# (see the EVO_* block above), so a fruit still on the floor when the horn blows
# is lost outright. mutation_fruit / meca_parts ARE vacuumed at the wave end and
# need no hurry. When wave_time_left drops inside the actual walk time
# (eta = dist / speed) plus a margin, scale the value UP so the fruit outbids a
# marginal detour now that there is no "later" left; never discount anything.
# --arb-waveend=0 turns it off exactly (control arm).
const EVO_WAVEEND_MARGIN = 1.5    # seconds of slack on top of the walk time
const EVO_WAVEEND_BOOST = 3.0     # value x(1+3*progress) -> up to x4 at the horn
const EVO_WAVEEND_CAP = 4.0
var curse_mult = CURSE_TARGET_MULT      # --arb-curse
var evolved_mult = EVOLVED_TARGET_MULT  # --arb-evolved
var evo_mult = 1.0                 # --arb-evo: x all three pickup values; 0 = old food-only pricing
var walk_tag = 1.0                 # --arb-walk: 1 = append r[4] walk-on tag; 0 = v2.4 4-tuple
var bounty_tag = 1.0               # --arb-bounty: special-target tag + loot value
var boxes_mult = 1.0               # --arb-boxes: item crate value
var waveend_mult = 1.0             # --arb-waveend: 1 = wave-end fruit urgency; 0 = off

# -- v2.6.1: two contact-model gaps that let the bot walk INTO a body --------
# Field report after 2.6.0: "sometimes in relatively simple situations the
# character collides with monsters". Alongside the arbiter's crowding-projection
# fix (--arb-roomtrack), two world_view-side gaps can price a damaging body at
# zero:
#   windup  -- a charging enemy that is winding up is represented ONLY by its
#              future dash lane (_dash_corridor replaces the walker threat), but
#              the lane starts at launch. During the 0.3-0.5 s telegraph the
#              body is frozen in place, its contact hitbox is live, and the
#              threat list contained NO threat at its position: a probe priced
#              walking through the body at 0.00 vs 17.42 for a plain walker.
#   hitbox  -- the contact price used the enemy's HURTBOX radius while the game
#              deals contact damage with the enemy HITBOX (verified in the
#              decompiled sources + scenes). For normal trash the hurtbox is the
#              bigger circle (over-cautious, safe), but elites/bosses and the
#              DLC2 brachiosaurus (capsule hitbox, 148-212 px real reach vs a
#              41 px model) UNDER-estimate the reach; the brachiosaurus case had
#              a 147 px band where the contact cost was exactly zero.
# Both are conservative-direction fixes: plain trash keeps its exact old radius
# and non-charging enemies keep their exact old tuple, so the all-zero control
# arms are unchanged. --arb-windup=0 / --arb-hitbox=0 are the exact opt-outs.
var windup_priced = 1.0            # --arb-windup: price the frozen wind-up body
var hitbox_scan = 1.0              # --arb-hitbox: never under-estimate contact reach
# Counts refreshed every gather and printed by the once-a-second BOTLOG DLC
# line: a real-game A/B has to prove the bot SAW the DLC content, not only that
# it scored it differently.
var last_cursed_n = 0
var last_evolved_n = 0
var last_evo_ground_n = 0
var _dlc_log_ms = -1000000       # OS.get_ticks_msec of the last BOTLOG DLC line (rate limit)

# -- The table --
#
# Keys, all optional:
#   gold          float   flat material value (baseline GOLD_VALUE)
#   gold_phases   Array   [[max_wave, value], ...]; first match wins
#   gold_mode     String  "builder" | "enemy_gated" | "metered"
#   food          String  "bank" | "full_hp" | "bomb" | "none"
#   caution       float   multiplier on threat weights (>1 keeps more distance)
#   caution_phases Array  [[max_wave, value], ...]
#   caution_per_wave float added per wave elapsed (compounding-danger characters)
#   engage        float   contact-seeking strength (inverse kiting)
#   engage_hp     float   seek contact only while hp_ratio is ABOVE this
#   engage_pack   int     seek contact only once this many enemies are close
#   engage_mode   String  "cluster": price a candidate by bodies inside the
#                         blast at its END position (bull) instead of by
#                         distance to the nearest target
#   engage_boss   bool|"trash"  true: seek contact even with bosses (knight);
#                         "trash": keep farming trash while a boss lives but
#                         never count the boss (bull)
#   engage_end_hp float   in the final end_secs the HP band drops to this
#   caution_below Array   [hp_ratio, caution]: caution used below the ratio
#   dps           float   multiplier on the kill reward (0 for weaponless kits)
#   lethality     float   HP-proportional panic multiplier (default 4); lower it
#                         for a weaponless kit that can't trade a hit, so a low-HP
#                         hit does not read as certain death and spiral into flight
#   loot_value    float   reward for a loot alien (0 if it cannot be caught)
#   tree_value    float   reward for a living tree (pacifist's only kills)
#   stand_income  bool    Streamer: price standing by the game's own not-moving
#                         material tick (3% of held gold per full second, min 1,
#                         cap 25) and charge a move with the tick it throws away
#   stand_w       float   multiplier on that price (default 1)
#   stand_phases  Array   [[wave_upto, mult], ...] like caution_phases
#   stand_below   Array   [hp_ratio, mult]: multiplier used below the ratio --
#                         the x3 stand that matches the human's income also
#                         killed the 33-HP bot twice on w8; hurt, it must move
#   sweep         float   multiplier on material value while no enemy is inside
#                         sweep_radius of the bot: the between-bursts drop walk
#   sweep_radius  float   the quiet test's radius (default SWEEP_RADIUS)
#   avoid_births  float   keep-out radius around enemy spawn markers
#   anchor        String  "builder" | "structures" | "center" | "perimeter"
#                         | "away_structures"
#   anchor_radius float   outer leash: cost for straying past it
#   anchor_inner  float   inner keep-out: cost for being closer than it
#   anchor_wave   int     anchor only engages from this wave on
#   orbit         float   direction pricing outside anchor_radius: outward costs,
#                         inward pays, tangential earns half (perimeter kiting)
#   orbit_from    float   radius the orbit ramp starts at (default anchor_radius)
#   pin           bool    arm the arbiter's pin-escape mode
#   pin_dwell     int     frames at the wall (edge < 150 px) that fire the escape
#                         even while moving; fire_still rows default to 40
#   still         String  "prefer" | "never"
const CHARACTER_PROFILES = {
	# --- Economy: materials are the win condition ---
	"character_saver": {"gold": 2.5, "anchor": "perimeter", "anchor_inner": 460.0,
			"caution_phases": [[6, 1.25], [99, 0.9]]},
	"character_mutant": {"gold": 2.0, "caution": 1.2, "still": "never"},
	"character_demon": {"gold": 2.0, "caution": 1.4, "anchor": "center",
			"anchor_radius": 520.0},
	"character_loud": {"gold": 2.0, "caution": 1.15, "still": "never"},
	"character_baby": {"gold": 2.0, "caution_phases": [[10, 1.5], [99, 0.65]]},
	"character_jack": {"gold": 1.8, "caution": 1.1},
	"character_old": {"gold": 1.8, "caution": 0.7, "anchor": "center",
			"anchor_radius": 420.0},
	"character_fisherman": {"gold": 1.8, "anchor": "perimeter",
			"anchor_inner": 440.0, "anchor_wave": 10},
	"character_apprentice": {"gold": 1.6, "caution": 1.25},
	"character_arms_dealer": {"gold": 1.6, "caution": 0.95},
	"character_hunter": {"gold": 1.5, "caution": 1.5},
	"character_technomage": {"gold": 1.5, "caution": 1.5, "anchor": "structures",
			"anchor_radius": 420.0},
	"character_curious": {"gold": 1.5, "caution": 0.9},
	"character_crazy": {"gold": 1.4, "caution": 0.7, "engage": 6.0, "engage_hp": 0.5},
	"character_entrepreneur": {"gold": 1.2, "anchor": "structures",
			"anchor_radius": 380.0},
	"character_knight": {"gold": 1.2, "caution": 0.5, "engage": 6.0,
			"engage_boss": true},    # the one kit told to stand ON the elite

	# --- Economy inverted: the floor is the better wallet ---
	"character_builder": {"gold_mode": "builder", "anchor": "builder",
			"anchor_w": BUILDER_ANCHOR_W},
	"character_beast_master": {"gold_phases": [[3, -0.6], [99, 0.9]], "caution": 1.2},
	"character_hiker": {"gold": 0.3, "caution": 1.3, "anchor": "perimeter",
			"anchor_inner": 480.0, "still": "never"},
	"character_ranger": {"gold": 0.3, "caution": 1.6},
	"character_wounded": {"gold": 0.4, "caution": 2.0},

	# --- Pickups as a weapon: WHEN you step on it is the whole skill ---
	"character_lucky": {"gold_mode": "enemy_gated", "gold": 1.6, "food": "bank",
			"still": "never"},
	"character_buccaneer": {"gold_mode": "metered", "gold": 2.0, "still": "never"},
	"character_sailor": {"gold": 1.8, "caution": 1.05},
	# engage_hp 0.4, not the human's "hold 50-66%": the bot HEALS by contact
	# (lifesteal 10-23 + spiky shield damages on touch), so fighting deeper
	# sustains where disengaging bleeds. w15 horde + w20 boss n=6: engage_hp
	# 0.66 -> 6/12, 0.4 -> 8/12 (survivors end near full HP), 0.25 -> 8/12.
	# engage_boss "trash": WITHOUT it engage disarms on every boss/elite wave
	# (default rule), so the heal-by-contact Lich spent all of w20 at eng=0,
	# never triggering its spiky-shield/lifesteal heal loop, and died to
	# attrition at 636 dmg though the human tanked 1003 and lived. With it,
	# the Lich keeps farming the boss-wave trash and heals through the fight.
	"character_lich": {"gold": 2.0, "caution": 0.6, "engage": 12.0,
			"engage_hp": 0.4, "engage_boss": "trash"},
	"character_chef": {"food": "bomb"},
	"character_glutton": {"food": "bomb", "anchor": "center", "anchor_radius": 560.0,
			"caution_phases": [[5, 1.4], [99, 1.0]]},
	"character_farmer": {"food": "full_hp", "caution": 1.4},
	"character_druid": {"food": "full_hp"},
	"character_golem": {"food": "none", "caution": 1.5},
	"character_vampire": {"food": "none", "caution": 0.6, "engage": 12.0,
			"engage_hp": 0.6},
	"character_ghost": {"food": "bank", "caution": 0.9},
	"character_chunky": {"food": "bank", "caution": 0.75, "still": "never"},
	"character_ogre": {"food": "bank", "caution_phases": [[8, 1.1], [99, 0.6]],
			"engage": 10.0, "engage_pack": 6},
	"character_vagabond": {"food": "bank", "caution": 0.8, "anchor": "center",
			"anchor_radius": 460.0},

	# --- Contact seekers: damage taken is the resource ---
	# Bull has NO weapons: every damage instance that lands (armor-reduced,
	# not dodged) detonates a 150 px explosion at 300% of melee+ranged+
	# elemental. The guide's loop: kite in circles so the crowd bunches, then
	# dive so ONE hit kills the pile ("if you're going to take a hit, take it
	# in the middle of a big group"); back off and regen when low; elites are
	# survived, never fought, but the trash on an elite wave still gets farmed;
	# stand near spawns but never ON the red X (it relocates the spawn); burst
	# the pile right before the horn. engage_mode cluster prices a candidate by
	# how many bodies its END position puts inside the blast, so the dive
	# lands where the explosion pays. dps 0: with no weapons the kill reward is
	# noise. avoid_births keeps it off the markers it wants to stand beside.
	# engage_hp 0.4 (was 0.6): the w10 death timeline showed the dive disarm
	# at 37/64 and never re-arm -- twenty seconds of kiting at 52-65% HP while
	# the crowd it had stopped thinning grew 22 -> 47 and herded it into a
	# corner. With 16 armor and 21 regen, trash hits for 5; 37 HP is seven
	# hits of buffer, and every dive KILLS the crowd that would spend it.
	# Passivity with a big crowd is the Bull's most dangerous mode.
	# engage_hp 0.25: the w10 band sweep (0.4 / 0.2 / 0.0, all 0/3) showed no
	# survival difference -- retreating below the band converts paid hits
	# into unpaid ones without reducing them, because a 50-crowd cannot be
	# outrun -- while the lower bands earned far more (375 kills / 255 mats
	# at 0.0 vs ~260 / ~180 at 0.4). 0.25 keeps a sliver of regen retreat for
	# the moments a crowd has actually been cleared.
	"character_bull": {"caution": 0.5, "caution_below": [0.25, 1.3],
			"engage": 14.0, "engage_hp": 0.25, "engage_mode": "cluster",
			# engage_pack_seek deliberately 0: hunting stragglers between piles
			# measured WORSE (w10 bed: faster deaths, 187-232 kills vs 245-348)
			# -- the "pack" seconds are the loop that lets the next pile form.
			"engage_pack": 3, "engage_pack_seek": 0.0, "engage_boss": "trash",
			"engage_end_hp": 0.4, "end_secs": 8,
			"dps": 0.0, "avoid_births": 90.0, "fight_room": 220.0,
			# explode_trade: the pile in the blast costs ONE hit, not N -- the
			# first hit detonates and the rest never land (see the arbiter).
			# explosion_ref: the kill reference is the explosion's ACTUAL damage,
			# computed from live stats (a flat 90 admitted 250 HP pursuers on the
			# w11 horde as "killable"; they survive the blast and keep hitting).
			# damage_dive: bodies the blast only hurts no longer veto a dive when
			# the bar is above 50% and the blast's total damage is worth it.
			"explode_trade": true, "explosion_ref": true, "damage_dive": true},
	"character_masochist": {"caution": 0.6, "engage": 12.0, "engage_hp": 0.66,
			"anchor": "center", "anchor_radius": 520.0},
	"character_wildling": {"gold": 1.4, "caution": 0.55, "engage": 8.0,
			"engage_hp": 0.3},
	"character_brawler": {"caution": 0.5, "engage": 8.0, "engage_hp": 0.35},
	"character_dwarf": {"caution": 0.7, "engage": 10.0, "engage_pack": 6},
	"character_artificer": {"caution": 1.1, "engage": 5.0, "engage_pack": 4,
			"anchor": "center", "anchor_radius": 560.0},

	# --- Anchored: a place worth fighting near (or away from) ---
	"character_engineer": {"anchor": "structures", "anchor_radius": 260.0,
			"still": "prefer", "gold_end": 1.6, "end_secs": 6},
	# Streamer (tracker #22113, Nightmare Abyss win): the human takes 12-75
	# steps a WAVE and collects 630-1,130 materials from the standing tick.
	# stand_income prices exactly that tick (player.gd NotMovingTimer, 1 s,
	# repeating; handle_gold_stat pays min(cap, max(1, pct x held))): standing
	# earns it, and a step forfeits the second already accumulated.
	# stand x3 vs x1, gold gained (n=4): w10 613 vs 497 but 2/4 died at 33 HP,
	# w13 701 vs 441, w15 497 vs 415, w17 763 vs 680, all 4/4.
	# USER OVERRIDE: prioritise MATERIALS in the FIRST 10 WAVES -- hold ground
	# firmly (stand x3 from wave 1, the +23% income seen above) instead of the old
	# survival-first x1-early. stand_below still drops to x1 below half HP so a
	# critical Streamer retreats and lives to keep farming (a dead bot earns 0).
	"character_streamer": {"anchor": "structures", "anchor_radius": 240.0,
			"still": "prefer", "stand_income": true,
			"stand_phases": [[99, 3.0]], "stand_below": [0.5, 1.0],
			"gold_end": 1.6, "end_secs": 6},
	"character_multitasker": {"anchor": "structures", "anchor_radius": 320.0,
			"caution": 0.75},
	"character_mage": {"anchor": "away_structures", "anchor_inner": 500.0,
			"caution": 1.2},
	# Pacifist is PAID 0.65 materials+XP per enemy still alive at the horn
	# (halved on horde waves) and deals ~1 damage, so the guide's whole wave
	# is a lap of the arena's outside edge with hands batting the crowd away:
	# "the outside edge of the field, rotating in circles, is where we spend
	# all our time"; walk AWAY from spawns and never stomp a red X (a cancelled
	# spawn is lost income); loot aliens are uncatchable and not worth a step;
	# consumables heal nothing once the worms stack; trees are the only kills
	# it has (lumberjack shirt) and the only crates -- reach them before the
	# horn. dps 0: the kill reward can only drag it toward things it cannot
	# kill; loot_value 0 for the same reason; tree_value gives the lap a
	# reason to bend inward when a tree stands.
	# The orbit is an ANNULUS, not a rim: inner 340 keeps the lap off the
	# centre, outer 560 keeps it >= 200 px off the short walls. At inner 520
	# on a 2164x1536 arena the "cheapest floor" was the wall band itself, and
	# the live w3 log showed the lap running at edge 24-48 with the whole
	# crowd in a conga line behind and every hit landing against a wall.
	# caution 1.2 through w8, 1.0 from w9: the weaponless kit flees, and once
	# the density peaks (~w9: 100+ threats, 46-114 live projectiles) fleeing
	# EVERYTHING walks it into the wall. w9 arms n=8: caution 1.2 4/8, 1.0
	# 6/8, 0.9 4/8; but w8 (40 HP) wants the 1.2 (1.0 -> 3/8), so it phases.
	"character_pacifist": {"food": "none", "anchor": "perimeter", "orbit": 30.0, "pin": true, "pin_dwell": 60,
			"anchor_inner": 340.0, "anchor_radius": 560.0, "still": "never",
			"caution_phases": [[8, 1.2], [99, 1.0]], "lethality": 3.0,
			"dps": 0.0, "loot_value": 0.0, "tree_value": 5.0,
			"avoid_births": 160.0},
	"character_creature": {"gold_phases": [[8, 1.8], [99, 0.9]],
			"caution_phases": [[8, 1.2], [99, 0.8]], "anchor": "perimeter",
			"anchor_inner": 460.0, "anchor_wave": 10, "still": "never"},
	# The guide's One-Armed goes ranged by ~wave 5 and then holds the centre
	# (the base row). With a single MELEE weapon it is a different character:
	# every hit is lifesteal, the axe only pays at contact, and a centre leash
	# plus above-baseline caution hold it exactly where it earns nothing.
	# The melee overlay plays it like Wildling -- press in while healthy,
	# widen only when low -- with the anchor dropped.
	"character_one_arm": {"gold": 1.6, "caution_phases": [[5, 0.7], [9, 1.4], [99, 1.1]],
			"anchor": "center", "anchor_radius": 520.0, "anchor_wave": 5,
			"if_melee": {"caution": 0.7, "caution_phases": [[99, 0.7]],
					"caution_below": [0.35, 1.3], "engage": 8.0, "engage_hp": 0.35,
					# a WIDE centre leash, not the ranged row's 520: every melee
					# death on the w10 bed was at edge 12-24 -- the brawl drifts
					# into the wall band and the 36 HP body gets pinned there
					"anchor": "center", "anchor_radius": 620.0,
					# no fighting in the wall band: rim spawns are not worth
					# the corner they are standing in
					"fight_room": 220.0}},
	"character_king": {"caution_phases": [[12, 1.4], [99, 0.8]]},

	# --- Still / never-still ---
	# Soldier is the tap-mover: +50% damage AND +50% attack speed while
	# stationary, fire resumes the instant it stops (no re-arm delay), and
	# +200% pickup range vacuums drops without walking to them. So: stand and
	# shoot (prefers_still doubles the DPS payout for the ZERO candidate, and
	# the stop-bonus in the arbiter's continuity term lets a dodge end the
	# moment the threat clears), never detour for gold mid-wave (0.3 -- the
	# pickup radius does the collecting), then sweep what the vacuum missed in
	# the final seconds when standing has nothing left to shoot at.
	# fire_still is the load-bearing key: weapons only fire while stationary, so
	# the arbiter's kill reward pays double when standing and near-nothing when
	# moving (see FIRE_STILL_* in the arbiter). Field report that forced it: the
	# bot kited constantly, never fired, and lost by attrition. caution below 1
	# leans the same way -- a potato that must stand to shoot has to accept more
	# incoming pressure than one that can retreat at no cost to its DPS.
	# gold 1.2 (was 0.3): the passive-vacuum theory underestimated how far away
	# a tap-moving Soldier kills things -- drops accumulate at weapon range and
	# the stand never walks there. Above-baseline value makes repositioning
	# paths route THROUGH drop fields; the stand-floor and trade budget still
	# outrank it wherever shooting matters, so it shapes the walk, not the fight.
	# pin: the stand-and-shoot behaviour is also how this kit gets CORNERED --
	# the stand holds while the crowd closes the exits (wave-12 field report).
	# Pin escape overrides every fire_still perk while it runs: no floor, no
	# kill-discount, no trade budget, no taps -- escape at the loss of firing.
	"character_soldier": {"still": "prefer", "fire_still": true, "pin": true,
			"caution_phases": [[3, 1.1], [99, 0.9]], "gold": 1.2, "gold_end": 2.0, "end_secs": 10},
	"character_speedy": {"still": "never", "caution": 1.15},

	# --- Caution-only rows ---
	"character_captain": {"caution_per_wave": 0.02},
	"character_romantic": {"caution_per_wave": 0.02},
	"character_gangster": {"caution": 1.4},
	# Explorer (tracker run #27048, Nightmare Abyss win): the human picks up
	# 26/47/64/79/101 materials on w1-5 and fells 5-26 trees a wave; the bot on
	# the same builds collected 8/9/25/44/43 with kills near-human from w6.
	# The character IS the tree lap (+50 pickup range, one-hit trees), so
	# materials and living trees are worth more than the generic row says.
	# Both w9 deaths (33 HP) were two 22-damage bullets taken at edge 36-42;
	# pin-dwell and wall x2 did nothing (3/6, 2/6, 4/6). The map is +33%, so
	# the centre leash is wider than the Pacifist annulus.
	# Tasers are RANGED with a 200 px reach (weapons/ranged/taser: type 1,
	# 7 dmg, no knockback): the human kills 50/93/134/151 on w2-5, the bot
	# 12/34/70/53 because it keeps everything past 200 px. The Crazy band
	# (engage 6 above half HP) is the generic "go stand near it" for a
	# short-reach kit that must still flee when hurt.
	# Caution by phase: at 11-15 HP (w2-5) caution x0.6 and engage x2 only
	# added damage (w2 "both" died at 11 s, kills flat at 8-13); at 33 HP
	# (w9) caution x0.6 was 6/6 with kills 433-483 vs the human's 549 and
	# materials 216-255 vs 410 -- the taser kit earns its income by standing
	# in the crowd once the body can take a hit.
	"character_explorer": {"caution": 1.3, "caution_phases": [[8, 1.3], [99, 0.8]],
			"gold": 2.0, "tree_value": 6.0,
			"anchor": "center", "anchor_radius": 700.0,
			"engage": 6.0, "engage_hp": 0.5},
	"character_diver": {"caution": 1.25},
	"character_generalist": {"caution": 0.8},
	"character_gladiator": {"caution": 0.8},
	"character_doctor": {"caution": 0.85},
	"character_sick": {"caution": 0.85},
	"character_renegade": {"caution": 0.75},
}

const WINDUP_ANIM_LENGTH = 0.4   # enemy_charge_prep_animation.tres: start_shoot at 0, shoot at 0.4
const SIN_DRIFT_HORIZON = 0.8    # must match Arbiter.HORIZON: how far a weaving bullet strays

# -- Weaving bullets --
#
# Projectile._physics_process moves a bullet by (velocity + sinusoidal_offset),
# where sinusoidal_offset = sin(sinusoidal_time) * sinusoidal_motion * 0.5. So
# the sine is a VELOCITY perturbation, and every input to it is readable: phase,
# amplitude and rate all live on the projectile.
#
# The old model ignored that and smeared the bullet instead, widening its radius
# by half-amplitude x horizon. That is a defensible bound for a gentle weave and
# catastrophic for a violent one. Bullet-hell variants differ 12x in amplitude:
#
#   BulletHell_*_3      50-75   ->  +20-30 px      (fine)
#   BulletHell_Top etc.   100   ->  +40 px         (fine)
#   BulletHell_0      250,250   ->  +141 px
#   BulletHell_2          400   ->  +160 px
#   BulletHell_*_2       +-600  ->  +240 px        (a 257 px BLOB per bullet)
#
# With 14-21 bullets up, the +-600 variants blanket the arena: every candidate
# direction sits inside something, the term goes flat across the compass and
# stops discriminating. That is the same saturation that made room18 score 0/10
# and made a butcher blade undodgeable as a 320 px disc -- and it matches the
# observed failure exactly, where the bot does NOT thrash but calmly walks into
# a wall while nothing is chasing it, because nothing pulls it anywhere better.
#
# So sample the sine instead of smearing it: integrate the bullet's real path
# over the scan window and emit a few small circles where it WILL be. Same
# threat model, same scorer, correct geometry.
# -- Orbiting projectiles --
#
# Some bosses carry their projectiles as their OWN children instead of handing
# them to the EnemyProjectiles container. The predator spins nine of them on a
# Pivot (corrupted_tree/pivot.gd) at radii 250-600, rotation_speed 1.2 rad/s,
# destroy_on_hit = false, damage scaling to ~23 by wave 20.
#
# gather() only scanned main's EnemyProjectiles children, so these never entered
# the threat list at all. Not mispriced -- ABSENT. No amount of scoring helps
# against a hazard that is not in the model, and this one is a permanent
# 420 px/s flail wrapped around a 15000 HP boss on the final wave.
#
# They are sampled along their ARC rather than given a straight-line velocity:
# at 1.2 rad/s the pivot turns 0.96 rad across one horizon, so a tangent would
# put a 350 px orbiter hundreds of px from where it really goes. Same treatment
# the weaving bullets get, and for the same reason.
const ORBIT_SAMPLES = 4
const ORBIT_SMEAR_MAX = 60.0     # px of residual widening per sample

const SIN_SAMPLES = 4            # circles per weaving bullet
const SIN_SMEAR_MAX = 60.0       # px of residual widening we still allow per sample,
                                 # covering the phase drift between samples
const SIN_SIGNIFICANT = 60.0     # amplitude below this, one straight-line threat with
                                 # the old cheap widening is already accurate enough

# -- Contact persistence --
#
# Every threat tuple carries the expected number of damage applications it
# lands over one horizon. For anything that fires once and is spent -- a
# bullet, a pillar, a completed dash -- that is 1. For a body it is not.
#
# Every enemy in the game shares attack_cd = 30 frames, so the hit RATE carries
# no information: a body you are touching lands HORIZON * 60 / 30 = 1.6 hits
# regardless of species. What differs enormously is how long it keeps touching
# you, and that is pure speed ratio. You shed a 150-speed pursuer almost at
# once; you do not shed a 350-speed lamprey at all while the potato moves ~470.
#
# The horizon truncation is what makes this matter. Pricing only 0.8 s is sound
# when the next decision can undo the exposure -- but against something you
# cannot outrun the next decision cannot, and every future horizon inherits the
# same contact. Each horizon separates you by (1 - ve/vp) of the closing gap,
# so the expected number of horizons spent attached is the geometric sum
# 1 / (1 - ve/vp): 1.0 for a stationary egg, ~1.5 for a pursuer, ~3.9 for a
# lamprey, and divergent as the enemy approaches your speed -- hence the cap.
#
# This replaces a flat CONTACT_TICKS = 1.6 that priced every body as a brush.
# The flat constant is why w2-fisherman needed --arb-contact=3 to survive
# (lampreys at 350 and chasers at 380) while the same override did nothing on
# w12-wildling and mildly hurt w4-loud: one number cannot be right for a body
# you cannot escape and a body you can walk away from.
const CONTACT_RATE = 1.6         # HORIZON * 60 / attack_cd; uniform across all enemies
const PERSIST_MAX = 4.0          # cap on horizons-attached, for ve >= vp
const TICKS_ONCE = 1.0           # bullets, pillars and dashes connect at most once

var threats = []
var rewards = []
var targets = []
var chargers = []                # idle chargers whose cooldown may expire soon
var mitigation = 1.0             # share of incoming damage that actually lands
var far_corner = Vector2.ZERO
var body_radius = BODY_RADIUS_FALLBACK
var weapon_range = 1000.0
var prefers_still = false
var current_hp = 1.0
var player_speed = 1.0           # sets how sticky every body is; a fast build
                                 # genuinely can afford to brush past things a
                                 # slow one must never touch
# Per-frame resolved profile handed to the arbiter: already-plain numbers, so
# the scorer never learns a character's name. Empty = pure baseline steering.
# Keys the arbiter reads: anchor, anchor_radius, anchor_inner, caution,
# engage, never_still, plus the v2.3.0 signals hp_ratio (always written) and
# kite_frac (0.0 = no standoff wanted) written unconditionally in gather.
var profile = {}
var wave_time_left = 1e9         # seconds until the wave ends; 1e9 when unreadable


# Sweepable via --arb-persist=<cap>, so this mechanism can be ablated like any
# weight. Note persist=1 reproduces the old flat CONTACT_TICKS = 1.6 exactly:
# the floor then clamps every separation to 1.0, so speed stops mattering. That
# makes it the honest control arm rather than an approximation of one.
var persist_max = PERSIST_MAX


# Arm/disarm window for a stationary attack, in animation-time, read off the
# animation's own method track: the key that calls enable_hitbox and the next
# one that calls disable_hitbox. Cached per Animation resource -- keying by name
# would collide, since a pillar and a slash both call theirs "shoot".
var _aoe_window_cache = {}

# Sweepable: --arb-aoeclock=0 reverts to "every un-spent telegraph is live right
# now", which is exactly how stationary attacks were priced before 2026-08-19.
# That makes the pre-fix behaviour an exact control arm rather than a guess at one.
var aoe_clock = 1.0

# Separate from aoe_clock on purpose: --arb-movingclock=0 reverts ONLY the
# in-flight telegraph timing, leaving the stationary pillar clock (committed and
# validated) in place. Without this, the control arm would revert two changes at
# once and could not attribute either.
var moving_clock = 1.0

# Sweepable: --arb-orbit=0 stops scanning boss subtrees for attached
# projectiles, restoring the previous behaviour where they were invisible.
var orbit_scan = 1.0

# Sweepable: --arb-mblade=0 puts flying blades back on the single fat circle,
# leaving the stationary decomposition untouched, so the control arm isolates
# exactly this change.
var moving_blade = 1.0

# Sweepable: --arb-bonusspeed=0 reverts enemy speed to bare current_stats,
# restoring the boost-blind threat model as an exact control arm.
var bonus_speed_scan = 1.0

# Sweepable: --arb-dpsref=0 pins the killability reference back to the static
# KILL_HP_REF, restoring build-blind kill values as an exact control arm.
var dps_ref_scan = 1.0
var _kill_ref = KILL_HP_REF      # refreshed per gather from live weapon stats
var _loot_value = LOOT_VALUE     # per-character loot-alien reward, set each gather
var _kill_ref_logged = -1e9      # last value announced on BOTLOG DPSREF

# Sweepable: --arb-charprofile=0 disables ALL character-specific logic at once,
# so "generic strategy on this character" stays an exact control arm.
# --arb-goldval overrides just the Builder's gold value (0 = ignore, positive
# = generic greed) to sweep the avoidance separately from the anchor.
var char_profile = 1.0
var profile_mode = ""          # --arb-profile=auto|table|merge (auto = infer from build traits)
var gold_pickup_draw = GOLD_PICKUP_DRAW  # --arb-golddraw: sweep the gold-pickup pull
var gold_value_override = null
var anchor_inner_override = null # --arb-inner: sweep a perimeter row's keep-out radius
var center_mode_override = 0.0   # --arb-centermode=<radius>: perimeter row -> center anchor
var engage_hp_override = null    # --arb-engagehp: sweep a row's engage_hp band
var caution_mult = 1.0           # --arb-caution: multiplier on the resolved row caution
var leash_override = 0.0         # --arb-leash=<px>: override the builder turret leash radius
var tree_mult = 1.0              # --arb-tree: DEFAULT_TREE_VALUE multiplier (0 = old)
var food_mult = FOOD_INJURED_MULT  # --arb-food: hurt-fruit multiplier (0 = old)

# Sweepable: --arb-blade=0 reverts to one inflated circle per stationary hitbox,
# which is exactly how blades were priced before, so the comparison is exact.
var blade_split = 1.0

# Sweepable: --arb-sweep=0 falls back to the blade's live pose instead of the
# union of everything it covers while armed, so the previous behaviour stays an
# exact control arm.
var sweep_union = 1.0

# Sweepable: --arb-sine=0 restores the single smeared circle, so the previous
# behaviour is an exact control arm.
var sine_sample = 1.0


# Value of a keyed track at or before `at`, held (not extrapolated) outside the
# key range -- which is how Godot itself samples a track before its first key.
func _held_value(keys: Array, at: float):
	if keys.empty():
		return null
	var out = keys[0][1]
	for k in keys:
		if k[0] <= at + 0.0001:
			out = k[1]
		else:
			break
	return out


func _aoe_profile(anim) -> Dictionary:
	var nm = anim.current_animation
	if nm == "" or not anim.has_animation(nm):
		return {"arm": AOE_ARM_FALLBACK, "disarm": AOE_DISARM_FALLBACK, "swept": false}
	var track = anim.get_animation(nm)
	var key = track.get_instance_id()
	if _aoe_window_cache.has(key):
		return _aoe_window_cache[key]

	var arm = -1.0
	var disarm = -1.0
	var pos_keys = []
	var ext_keys = []
	for ti in range(track.get_track_count()):
		var ttype = track.track_get_type(ti)
		if ttype == Animation.TYPE_METHOD:
			for ki in range(track.track_get_key_count(ti)):
				var when = track.track_get_key_time(ti, ki)
				var method = track.method_track_get_name(ti, ki)
				if method == "enable_hitbox":
					if arm < 0.0:
						arm = when
				elif method == "disable_hitbox" and arm >= 0.0 and disarm < 0.0:
					disarm = when
		elif ttype == Animation.TYPE_VALUE:
			var path = String(track.track_get_path(ti))
			if path.ends_with("Collision:position"):
				for ki in range(track.track_get_key_count(ti)):
					pos_keys.push_back([track.track_get_key_time(ti, ki), track.track_get_key_value(ti, ki)])
			elif path.ends_with("Collision:shape:extents"):
				for ki in range(track.track_get_key_count(ti)):
					ext_keys.push_back([track.track_get_key_time(ti, ki), track.track_get_key_value(ti, ki)])

	# `windowed` says a REAL enable_hitbox/disable_hitbox pair was found, as
	# opposed to the fallback guess. Only a real window may be applied to a
	# MOVING projectile: ordinary enemy bullets have no method track at all, and
	# applying the pillar's 0.54 s fallback to them would tell the bot a live
	# bullet is harmless for half a second.
	var profile = {"arm": AOE_ARM_FALLBACK, "disarm": AOE_DISARM_FALLBACK,
			"swept": false, "windowed": false}
	if arm >= 0.0:
		profile["arm"] = arm
		profile["disarm"] = disarm if disarm >= 0.0 else track.length
		profile["windowed"] = true

	# Union of every pose the collision box holds WHILE ARMED.
	#
	# This is the difference between planning against the blade and planning
	# against a stale stub. Both tracks' first key sits at the arm moment, so
	# during the whole 0.48 s wind-up -- the only time a dodge can actually be
	# planned -- sampling the live pose returns the blade's STARTING pose: a
	# 60x34 stub at x=-122, when the blade goes on to sweep a 306x34 region
	# centred at x=+1. The centre is 123 px wrong and the extent 5x too small,
	# so the bot sidesteps one end and the sweep takes it anyway. At ~1900 px/s
	# of sweep against a 470 px/s potato, reacting once it starts is hopeless.
	if not pos_keys.empty() and not ext_keys.empty():
		var lo = Vector2(1e9, 1e9)
		var hi = Vector2(-1e9, -1e9)
		var seen = 0
		for k in pos_keys:
			var when2 = k[0]
			if when2 < profile["arm"] - 0.0001 or when2 > profile["disarm"] + 0.0001:
				continue
			var c = k[1]
			var e = _held_value(ext_keys, when2)
			if e == null:
				continue
			lo.x = min(lo.x, c.x - e.x); hi.x = max(hi.x, c.x + e.x)
			lo.y = min(lo.y, c.y - e.y); hi.y = max(hi.y, c.y + e.y)
			seen += 1
		if seen > 0:
			profile["swept"] = true
			profile["centre"] = (lo + hi) * 0.5
			profile["half"] = (hi - lo) * 0.5
	_aoe_window_cache[key] = profile
	return profile


func apply_overrides(d: Dictionary) -> void:
	if d.has("persist"):
		persist_max = max(float(d["persist"]), 1.0)
		print("WORLDVIEW persist_max=%.2f" % persist_max)
	if d.has("aoeclock"):
		aoe_clock = float(d["aoeclock"])
		print("WORLDVIEW aoe_clock=%.0f" % aoe_clock)
	if d.has("aoemult"):
		aoe_mult = float(d["aoemult"])
		print("WORLDVIEW aoe_mult=%.2f" % aoe_mult)
	if d.has("blade"):
		blade_split = float(d["blade"])
		print("WORLDVIEW blade_split=%.0f" % blade_split)
	if d.has("sweep"):
		sweep_union = float(d["sweep"])
		print("WORLDVIEW sweep_union=%.0f" % sweep_union)
	if d.has("sine"):
		sine_sample = float(d["sine"])
		print("WORLDVIEW sine_sample=%.0f" % sine_sample)
	if d.has("movingclock"):
		moving_clock = float(d["movingclock"])
		print("WORLDVIEW moving_clock=%.0f" % moving_clock)
	if d.has("orbit"):
		orbit_scan = float(d["orbit"])
		print("WORLDVIEW orbit_scan=%.0f" % orbit_scan)
	if d.has("mblade"):
		moving_blade = float(d["mblade"])
		print("WORLDVIEW moving_blade=%.0f" % moving_blade)
	if d.has("bonusspeed"):
		bonus_speed_scan = float(d["bonusspeed"])
		print("WORLDVIEW bonus_speed_scan=%.0f" % bonus_speed_scan)
	if d.has("dpsref"):
		dps_ref_scan = float(d["dpsref"])
		print("WORLDVIEW dps_ref_scan=%.0f" % dps_ref_scan)
	if d.has("charprofile"):
		char_profile = float(d["charprofile"])
		print("WORLDVIEW char_profile=%.0f" % char_profile)
	if d.has("goldval"):
		gold_value_override = float(d["goldval"])
		print("WORLDVIEW gold_value_override=%.2f" % gold_value_override)
	if d.has("golddraw"):
		gold_pickup_draw = float(d["golddraw"])
		print("WORLDVIEW gold_pickup_draw=%.2f" % gold_pickup_draw)
	if d.has("inner"):
		anchor_inner_override = float(d["inner"])
		print("WORLDVIEW anchor_inner_override=%.0f" % anchor_inner_override)
	if d.has("leash"):
		leash_override = float(d["leash"])
		print("WORLDVIEW leash_override=%.0f" % leash_override)
	if d.has("engagehp"):
		engage_hp_override = float(d["engagehp"])
		print("WORLDVIEW engage_hp_override=%.2f" % engage_hp_override)
	if d.has("caution"):
		caution_mult = float(d["caution"])
		print("WORLDVIEW caution_mult=%.2f" % caution_mult)
	if d.has("tree"):
		# v2.3.0: multiplier on the default living-tree value. 0 = old
		# behaviour, where only characters with a tree mechanic felled trees.
		tree_mult = float(d["tree"])
		print("WORLDVIEW tree_mult=%.2f" % tree_mult)
	if d.has("food"):
		# v2.3.0: multiplier on a consumable's value while hurt. 0 = old
		# unscaled value, so the control arm is exact rather than approximate.
		food_mult = float(d["food"])
		print("WORLDVIEW food_mult=%.2f" % food_mult)
	if d.has("sweep"):
		sweep_override = float(d["sweep"])
		print("WORLDVIEW sweep_override=%.2f" % sweep_override)
	if d.has("dashfix"):
		dash_fix = float(d["dashfix"])
		print("WORLDVIEW dash_fix=%.0f" % dash_fix)
	if d.has("revive"):
		revive_mult = float(d["revive"])
		print("WORLDVIEW revive_mult=%.2f" % revive_mult)
	if d.has("centermode"):
		# Startup args parse as floats, so the mode switch is numeric: a
		# nonzero value turns a perimeter row into a CENTER anchor with that
		# leash radius -- the A/B for "rim orbit vs room to dodge".
		center_mode_override = float(d["centermode"])
		print("WORLDVIEW center_mode_override=%.0f" % center_mode_override)
	if d.has("curse"):
		# v2.4.0: signed stance on cursed enemies. >0 = target value x v
		# (engage), <0 = avoid (target 0, threat damage x(1+|v|)), 0 = exact
		# v2.3.0 control arm.
		curse_mult = float(d["curse"])
		print("WORLDVIEW curse_mult=%.2f" % curse_mult)
	if d.has("evolved"):
		# Same signed stance for meca/mutant (evolved) enemies.
		evolved_mult = float(d["evolved"])
		print("WORLDVIEW evolved_mult=%.2f" % evolved_mult)
	if d.has("evo"):
		# v2.4.0: multiplier on the evolution-pickup values. 0 restores the
		# old food-only pricing exactly, so it is the A/B control arm.
		evo_mult = float(d["evo"])
		print("WORLDVIEW evo_mult=%.2f" % evo_mult)
	if d.has("walk"):
		# v2.5.0: 0 = do NOT append the 5th tuple field, i.e. write the v2.4
		# [pos, value, false, rim] tuple verbatim. Together with the Lead's
		# arbiter (r[4] distinguishes walk-on from held) this is the exact
		# "held parking vs walk-on pickup" control arm.
		walk_tag = float(d["walk"])
		print("WORLDVIEW walk_tag=%.0f" % walk_tag)
	if d.has("waveend"):
		# v2.5.0: 0 = no end-of-wave urgency scaling on meca/mutant fruit.
		waveend_mult = float(d["waveend"])
		print("WORLDVIEW waveend_mult=%.2f" % waveend_mult)
	if d.has("bounty"):
		# v2.6.0: 0 = no special-target tag on target tuples and the 2.5.0
		# loot-alien value; exact control arm for the bounty layer.
		bounty_tag = float(d["bounty"])
		print("WORLDVIEW bounty_tag=%.0f" % bounty_tag)
	if d.has("boxes"):
		# v2.6.0: 0 = item crates keep their 2.5.0 healing-only pricing.
		boxes_mult = float(d["boxes"])
		print("WORLDVIEW boxes_mult=%.2f" % boxes_mult)
	if d.has("windup"):
		# v2.6.1: 0 = a winding-up charger keeps only its dash lane (the 2.6.0
		# tuple), i.e. its frozen body is free to walk over.
		windup_priced = float(d["windup"])
		print("WORLDVIEW windup_priced=%.0f" % windup_priced)
	if d.has("hitbox"):
		# v2.6.1: 0 = contact reach comes from the hurtbox only (the 2.6.0
		# model), so the elite/boss/brachiosaurus under-estimate is restored.
		hitbox_scan = float(d["hitbox"])
		print("WORLDVIEW hitbox_scan=%.0f" % hitbox_scan)


# Expected damage applications from a body over one horizon: how often it hits
# while attached, times how many horizons it stays attached. See the
# CONTACT_RATE block above for the derivation.
func _contact_ticks(enemy_speed: float) -> float:
	var separation = 1.0 - enemy_speed / player_speed
	return CONTACT_RATE / max(separation, 1.0 / persist_max)


func gather(main, player) -> void:
	threats = []
	rewards = []
	targets = []
	chargers = []
	# v2.4.0 DLC telemetry counters (see the BOTLOG DLC line at the end).
	last_cursed_n = 0
	last_evolved_n = 0
	last_evo_ground_n = 0
	far_corner = ZoneService.current_zone_max_position
	body_radius = _body_radius(player)
	mitigation = _mitigation(player)
	player_speed = max(float(player.get_move_speed()), 1.0)

	var pos = player.position
	var range_sq = THREAT_RANGE * THREAT_RANGE
	var pickup_sq = PICKUP_RANGE * PICKUP_RANGE
	var spawner = main._entity_spawner

	# The wave clock, for phase behaviours keyed to it (end-of-wave sweeps now;
	# cyborg's half-wave switch later). _wave_timer is Main's own Timer node --
	# time_left is 0 while it is stopped (between waves), which correctly reads
	# as "the wave is over, sweep" rather than as a huge remaining duration.
	wave_time_left = 1e9
	if "_wave_timer" in main and main._wave_timer:
		wave_time_left = float(main._wave_timer.time_left)

	weapon_range = _weapon_range(player)
	_refresh_kill_ref(player)
	var character_id = RunData.get_player_character(player.player_index).my_id
	# char_profile = 0 (--arb-charprofile=0) empties the row, which is what makes
	# "this character, generic steering" an exact control arm rather than an
	# approximation of one.
	var row = _resolve_profile_row(player, spawner, character_id)
	prefers_still = row.get("still", "") == "prefer"
	_loot_value = float(row.get("loot_value",
			LOOT_BOUNTY_VALUE if bounty_tag != 0.0 else LOOT_VALUE))
	if row.has("kill_ref"):
		# A weaponless kit has no weapon DPS to measure, so killability would
		# sit at the 20 HP floor and nothing on wave 5+ would count as killable.
		_kill_ref = max(_kill_ref, float(row["kill_ref"]))
	if row.get("explosion_ref", false):
		# Bull: the explosion is 30 base + 3x each of melee/ranged/elemental
		# damage (bull_explosion_stats scaling), times %damage and %explosion
		# damage. Killable means "dies to one blast", so the reference IS the
		# blast. Crits ignored -- the estimate runs conservative.
		var flat = float(Utils.get_stat(Keys.generate_hash("stat_melee_damage"), 0)) \
				+ float(Utils.get_stat(Keys.generate_hash("stat_ranged_damage"), 0)) \
				+ float(Utils.get_stat(Keys.generate_hash("stat_elemental_damage"), 0))
		var pct = float(Utils.get_stat(Keys.generate_hash("stat_percent_damage"), 0))
		var expl = float(Utils.get_stat(Keys.generate_hash("explosion_damage"), 0))
		var blast = (30.0 + 3.0 * flat) * (1.0 + pct / 100.0) * (1.0 + expl / 100.0)
		_kill_ref = clamp(blast, KILL_HP_REF, KILL_REF_MAX)
		if abs(_kill_ref - _kill_ref_logged) > 25.0:
			_kill_ref_logged = _kill_ref
			print("BOTLOG DPSREF explosion=%.0f kill_ref=%.0f" % [blast, _kill_ref])
	var row_sig = str(row)
	if character_id != _announced_char or row_sig != _announced_row_sig:
		_announced_char = character_id
		_announced_row_sig = row_sig
		print("BOTLOG PROFILE char=%s %s" % [character_id,
				"baseline" if row.empty() else row_sig])

	var target_reach = max(THREAT_RANGE, weapon_range + TARGET_EXTRA)
	var target_range_sq = target_reach * target_reach

	for enemy in spawner.enemies:
		_add_unit(enemy, pos, range_sq, target_range_sq, pickup_sq)
	for boss in spawner.bosses:
		_add_unit(boss, pos, range_sq, target_range_sq, pickup_sq)

	var projectiles = main.get_node_or_null("EnemyProjectiles")
	if projectiles:
		for p in projectiles.get_children():
			if not (p is Projectile):
				continue    # BulletHell wave containers live here too
			if not p._hitbox or not p._hitbox.active:
				continue
			_add_projectile(p, pos, range_sq)

	# Projectiles a boss keeps as its own children never reach that container.
	# Bosses only: they are few, so walking their subtrees is cheap, and every
	# attached-projectile design in this game is a boss mechanic.
	if orbit_scan != 0.0:
		for boss in spawner.bosses:
			_add_attached(boss, pos, range_sq)

	current_hp = float(player.current_stats.health)
	var max_hp = max(float(player.max_stats.health), 1.0)
	var missing_hp = max_hp - current_hp
	var food_mode = row.get("food", "")
	# v2.4.0: evolution consumables are a reward class the old food pricing
	# cannot express -- they heal nothing, cannot be attracted (see the EVO_*
	# block above), and the only way to take one is to step the ItemPickupArea
	# over it. _consumable_value prices them as progression and gates them on
	# the game's own eligibility rules; everything that IS food keeps the old
	# _food_value line and the old 2-field tuple (rim = pickup_radius).
	#
	# --arb-evo=0 is the exact v2.3.0 control arm, so it runs the old line
	# verbatim -- same tuple arity, same food value for every consumable --
	# instead of asking the new classifier. That keeps a HEAD-vs-new A/B on
	# the all-zero arm value-for-value identical, which is what the control
	# arm is for.
	last_evo_ground_n = 0
	for c in main._consumables:
		var dist_sq = c.position.distance_squared_to(pos)
		if dist_sq >= pickup_sq:
			continue
		var kind = _consumable_kind(c)
		if kind != "":
			last_evo_ground_n += 1
		if evo_mult == 0.0:
			rewards.push_back([c.position,
					_food_value(food_mode, c.position, missing_hp, spawner)])
			continue
		var v = _consumable_value(c, player, food_mode, missing_hp, spawner)
		if v == 0.0:
			continue
		if _consumable_is_food(c):
			rewards.push_back([c.position, v])
		else:
			# Evolution pickup: rim (see EVO_WALK_RIM) so a move that ENDS
			# inside the physical pickup circle is paid in full; rim 0 would
			# leave the bot circling the edge. v2.5.0: r[4] tags it walk-on
			# (one-shot, not a held stand), and the end-of-wave race scales
			# the two fruits the game does NOT vacuum; 0.0 means "arrive at
			# eta+margin", so the scaling is exactly 1.0 unless time is short.
			v *= _evo_waveend_scale(kind, sqrt(dist_sq))
			if walk_tag != 0.0:
				rewards.push_back([c.position, v, false, EVO_WALK_RIM,
						EVO_WALK_TAG])
			else:
				rewards.push_back([c.position, v, false, EVO_WALK_RIM])
	# Drops are collected by the attract area, not by contact: the arbiter
	# prices distance to its rim (profile pickup_radius) and pays a "taken"
	# bonus for a move that ends inside it. A drop already flying to us is
	# income either way and steers nothing.
	if "_item_attract_area" in player and player._item_attract_area != null:
		var shape = player._item_attract_area.get_node_or_null("CollisionShape2D")
		if shape != null and shape.shape != null and "radius" in shape.shape:
			pickup_radius = float(shape.shape.radius)
	var gold_value = _gold_value(row, player)
	# Safe-gated extra greed: boost the pull toward drops only while no live enemy
	# is within GOLD_DRAW_QUIET_RADIUS, so it never yanks the bot into a fight.
	var draw_sq = GOLD_DRAW_QUIET_RADIUS * GOLD_DRAW_QUIET_RADIUS
	var enemy_near = false
	for en in spawner.enemies:
		if is_instance_valid(en) and not en.dead and not en.is_loot \
				and en.position.distance_squared_to(pos) < draw_sq:
			enemy_near = true
			break
	var draw = 1.0 if enemy_near else gold_pickup_draw
	# Sweep: between spawn bursts the floor is free money and the human walks
	# it (Explorer #27048 left 2-34 bonus gold a wave, the bot ~half its
	# drops). With no enemy inside sweep_radius the drops are worth more.
	var sweep = float(row.get("sweep", 1.0))
	if sweep_override >= 0.0:
		sweep = sweep_override
	if sweep != 1.0:
		var quiet_sq = pow(float(row.get("sweep_radius", SWEEP_RADIUS)), 2)
		var quiet = true
		for en in spawner.enemies:
			if is_instance_valid(en) and not en.dead and not en.is_loot 					and en.position.distance_squared_to(pos) < quiet_sq:
				quiet = false
				break
		if quiet:
			gold_value *= sweep
	for g in main._active_golds:
		if not is_instance_valid(g):
			continue
		if "attracted_by" in g and g.attracted_by != null:
			continue
		if g.position.distance_squared_to(pos) < pickup_sq:
			rewards.push_back([g.position, gold_value * draw])

	# Scapegoat revive (see REVIVE_VALUE): a dead goat's zone is a held reward.
	if revive_mult > 0.0 and ("pets" in spawner):
		for pet in spawner.pets:
			if not is_instance_valid(pet) or not pet.get("is_scapegoat"):
				continue
			var id = pet.get_instance_id()
			if pet.dead and not pet.get("_end_of_wave"):
				if not _goat_dead.has(id):
					_goat_dead[id] = 0.0
					print("BOTLOG GOAT died wave=%d t=%d pos=(%d,%d)" % [RunData.current_wave,
							int(main._wave_timer.wait_time - main._wave_timer.time_left),
							int(pet.position.x), int(pet.position.y)])
				_goat_dead[id] += 1.0 / float(max(Engine.iterations_per_second, 1))   # one physics tick
				rewards.push_back([pet.position + SCAPEGOAT_ZONE_OFFSET, REVIVE_VALUE * revive_mult,
						false, SCAPEGOAT_ZONE])
			elif _goat_dead.has(id):
				print("BOTLOG GOAT revived wave=%d t=%d after=%.1fs" % [RunData.current_wave,
						int(main._wave_timer.wait_time - main._wave_timer.time_left), _goat_dead[id]])
				_goat_dead.erase(id)

	# Trees: pacifist's only kills and crates; cryptid's income (negative value
	# later). spawner.neutrals holds them.
	var tree_value = float(row.get("tree_value", 0.0))
	if tree_value != 0.0 and ("neutrals" in spawner):
		for n in spawner.neutrals:
			if is_instance_valid(n) and not n.dead and not n._pending_die \
					and n.position.distance_squared_to(pos) < pickup_sq:
				rewards.push_back([n.position, tree_value, false])   # felled, not attracted

	# Enemy spawn markers (the red X). EntityBirth nodes are pooled under
	# main._births_container; an active one is shown by start() and hidden
	# again by birth(), so `visible` is the liveness test. Priced as a small
	# standing AoE so the collision term keeps the bot OFF the marker without
	# fearing it: stepping on one relocates the spawn (bull loses the pile it
	# was setting up) or cancels it (pacifist/jack/king lose the payout).
	var births_r = float(row.get("avoid_births", 0.0))
	if births_r > 0.0 and ("_births_container" in main) and main._births_container:
		for b in main._births_container.get_children():
			if not b.visible or not ("type" in b) or b.type != EntityType.ENEMY:
				continue
			if b.global_position.distance_squared_to(pos) < range_sq:
				threats.push_back([b.global_position, Vector2.ZERO, births_r,
						BIRTH_STEP_COST, KIND_MARK, 0.0, TICKS_ONCE, INF_TIME])

	profile = {}
	profile["pickup_radius"] = pickup_radius   # every row: the attract rim prices drops
	# v2.5.0 telemetry only: lets the arbiter's BOTLOG show the end-of-wave
	# race. Deliberately not a scoring key -- the two un-vacuumed fruits
	# already carry the bonus in their reward value (_evo_waveend_scale), so
	# nothing may add it a second time from here.
	profile["wave_left"] = wave_time_left
	# v2.3.0 contract: BOTH signals are written every frame, unconditionally --
	# including on the --arb-charprofile=0 control arm and for rows whose
	# resolver was skipped. The arbiter's own switches (--arb-kite=0,
	# --arb-plan=0, --arb-adapt=0) decide whether they are used, so writing
	# them cannot change control-arm steering.
	#   hp_ratio  -- same value the damage_dive block below writes; hoisting it
	#                here gives the kite / hit-adaptation terms a read on every
	#                character, not just divers (old readers keep the same value).
	#   kite_frac -- standoff share of weapon range: 0.75 with any ranged weapon,
	#                0.0 for all-melee and weaponless kits (no standoff to keep).
	profile["hp_ratio"] = current_hp / max_hp
	profile["kite_frac"] = KITE_FRAC_RANGED if _has_ranged_weapon(player) else 0.0
	if row.get("stand_income", false):
		# The not-moving material tick, in the pickup unit (gold_value per
		# material), and how far into the current second the stand is.
		var per_sec = 0.0
		for ts in RunData.get_player_effect(Keys.temp_stats_while_not_moving_hash, player.player_index):
			if ts[0] == Keys.percent_materials_hash:
				var v = max(1.0, abs(float(ts[1]) / 100.0 * float(RunData.get_player_gold(player.player_index))))
				if ts.size() >= 3:
					v = min(v, float(ts[2]))
				per_sec += v
		var stand_w = float(row.get("stand_w", 1.0))
		if row.has("stand_phases"):
			stand_w = _phase_value(row["stand_phases"], stand_w)
		if row.has("stand_below") and current_hp / max_hp < float(row["stand_below"][0]):
			stand_w = float(row["stand_below"][1])
		profile["stand_income"] = per_sec * gold_value * stand_w
		var progress = 0.0
		if ("not_moving_bonuses_applied" in player) and player.not_moving_bonuses_applied 				and ("_not_moving_timer" in player) and player._not_moving_timer != null:
			var t = player._not_moving_timer
			progress = clamp((t.wait_time - t.time_left) / max(t.wait_time, 0.01), 0.0, 1.0)
		profile["stand_progress"] = progress
	if not row.empty():
		var hp_ratio = current_hp / max_hp
		var caution = _caution(row, hp_ratio)
		if caution != 1.0:
			profile["caution"] = caution
		if row.get("still", "") == "never":
			profile["never_still"] = true
		if row.get("fire_still", false):
			profile["fire_still"] = true
		if row.get("pin", false):
			profile["pin"] = true
		if row.has("dps"):
			profile["dps"] = float(row["dps"])
		if row.has("lethality"):
			profile["lethality"] = float(row["lethality"])
		if row.has("fight_room"):
			profile["fight_room"] = float(row["fight_room"])
		if row.get("explode_trade", false):
			profile["explode_trade"] = true
		if row.get("damage_dive", false):
			profile["damage_dive"] = true
			profile["hp_ratio"] = hp_ratio
			profile["blast"] = _kill_ref    # explosion_ref makes this the blast damage
		if row.has("anchor_w"):
			profile["anchor_w"] = float(row["anchor_w"])
		var engage = _engage(row, hp_ratio, pos, spawner)
		if engage > 0.0:
			profile["engage"] = engage
			# Cluster pricing only once a pile exists; while seeking, the plain
			# nearest-body pull closes the distance faster than 0.4x of it.
			if row.get("engage_mode", "") == "cluster" and last_engage_block != "seek":
				profile["engage_cluster"] = true
		_resolve_anchor(row, spawner)

	# -- v2.4.0 DLC telemetry -------------------------------------------------
	# At most one line per second. This exists for the real-game A/B: it proves
	# the bot actually SAW cursed / evolved bodies and evolution pickups on the
	# floor, not merely that it scored them differently. The counts are updated
	# even on the all-zero control arm, so both arms can be compared on the
	# same population. Throttled on WALL CLOCK, not physics ticks: gather() only
	# runs on decision frames and --arb-every=N can space those N ticks apart,
	# so a tick counter would silently become a once-per-N-seconds line.
	var now_ms = OS.get_ticks_msec()
	if now_ms - _dlc_log_ms >= 1000:
		_dlc_log_ms = now_ms
		print("BOTLOG DLC wave=%d cursed=%d evolved=%d evo_ground=%d curse=%.2f evolved=%.2f evo=%.2f" % [
				RunData.current_wave, last_cursed_n, last_evolved_n,
				last_evo_ground_n, curse_mult, evolved_mult, evo_mult])


# "Killable" is relative to the guns doing the killing, and pinning it to a
# static 20 HP is why a maxed build still tiptoed around elites it could
# delete: killability read an 800 HP elite as 0.02 forever, so neither the
# kill reward nor the Soldier's standing discount ever learned the build had
# outgrown the number. The reference is now the damage the CURRENT loadout
# deals in KILL_TIME seconds of fire, measured from live weapon stats
# (weapon.stats is post-init, so attack-speed and damage purchases are already
# in the cooldown and damage fields; crits and conditional bonuses are not --
# the estimate runs conservative). Floored at the old constant so a naked
# early build behaves exactly as before, capped so a bad read cannot explode.
func _refresh_kill_ref(player) -> void:
	_kill_ref = KILL_HP_REF
	if dps_ref_scan == 0.0 or not ("current_weapons" in player):
		return
	var dps = 0.0
	for w in player.current_weapons:
		if not is_instance_valid(w) or not w.stats:
			continue
		var nproj = 1.0
		if "nb_projectiles" in w.stats:
			nproj = max(float(w.stats.nb_projectiles), 1.0)
		dps += float(w.stats.damage) * nproj * 60.0 / max(float(w.stats.cooldown), 1.0)
	_kill_ref = clamp(dps * KILL_TIME, KILL_HP_REF, KILL_REF_MAX)
	if abs(_kill_ref - _kill_ref_logged) > 25.0:
		_kill_ref_logged = _kill_ref
		print("BOTLOG DPSREF dps=%.0f kill_ref=%.0f" % [dps, _kill_ref])


# The Builder's phased material value -- see the character-profiles block.
# Phase state is read off the run, not tracked: the wave number and the
# turret's own XP stat (structure_range) fully determine the phase, so a
# mid-run save/load or a WaveLab snapshot injection lands in the right
# phase for free. --arb-goldval overrides ALL phases at once, so a sweep
# can still price gold flat.
var _builder_phase = -1          # last announced phase, for the BOTLOG line only
var _announced_char = ""         # ditto: which character's row we already logged
var _announced_row_sig = ""      # last logged row (auto inference can change mid-run)


# Value of the first phase row whose wave ceiling has not been passed.
func _phase_value(phases: Array, fallback: float) -> float:
	for p in phases:
		if RunData.current_wave <= int(p[0]):
			return float(p[1])
	return fallback


func _gold_value(row: Dictionary, player) -> float:
	var mode = row.get("gold_mode", "")
	if mode == "builder":
		return _builder_gold_value(player)
	if gold_value_override != null:
		return gold_value_override
	# End-of-wave sweep: characters that spend the wave NOT collecting (Soldier
	# stands and lets its tripled pickup radius vacuum; Engineer holds its pod)
	# still want the leftovers, and the last seconds are when collecting them
	# costs the least -- the spawner has wound down and, per the Golem guide,
	# damage taken right before the horn is nearly free. Deliberately a no-op
	# for the Builder: its feed phase exists precisely to LEAVE the floor full.
	if row.has("gold_end") and wave_time_left <= float(row.get("end_secs", 8.0)):
		return float(row["gold_end"])
	var base = float(row.get("gold", GOLD_VALUE))
	if row.has("gold_phases"):
		base = _phase_value(row["gold_phases"], GOLD_VALUE)
	if mode == "enemy_gated":
		# Lucky's pickups DEAL DAMAGE (dmg_when_pickup_gold, 15% of Luck), so a
		# material collected on an empty floor is a wasted shot. Let it lie
		# until there is something for it to hit.
		return base if not targets.empty() else 0.0
	if mode == "metered":
		# Buccaneer: a pickup RESETS every weapon cooldown, and one pickup pays
		# the same whether one weapon was waiting or six. Vacuuming a pile
		# spends its resets on weapons that were ready anyway -- the value is
		# entirely in the spacing, so only reach for gold while something cools.
		return base if _weapon_cooling(player) else 0.0
	return base


# Is any weapon deep enough into cooldown that resetting it actually buys a shot?
func _weapon_cooling(player) -> bool:
	if not ("current_weapons" in player):
		return true    # unknown loadout shape: fall back to plain greed
	for w in player.current_weapons:
		if is_instance_valid(w) and w._current_cooldown >= METER_COOLDOWN_MIN:
			return true
	return false


func _food_value(mode: String, fpos: Vector2, missing_hp: float, spawner) -> float:
	if mode == "none":
		# Golem cannot heal at all mid-wave and Vampire's consumable_heal is
		# -100: fruit is scenery, and detouring for it is pure risk.
		return 0.0
	if mode == "full_hp" and missing_hp <= 0.0:
		# Farmer (+1 harvesting) and Druid (a luck roll) are PAID for eating at
		# full health, which inverts the usual save-it-until-hurt logic.
		return FOOD_FULL_SEEK
	if mode == "bomb":
		# Chef ignites on pickup, Glutton detonates for 500% melee. The fruit is
		# a grenade with a fixed blast, so its worth is who is standing in it --
		# and eating it alone throws the whole charge away.
		var near = 0
		var r_sq = FOOD_BOMB_RADIUS * FOOD_BOMB_RADIUS
		for e in spawner.enemies:
			if is_instance_valid(e) and not e.dead and not e.is_loot \
					and e.position.distance_squared_to(fpos) < r_sq:
				near += 1
		if near == 0:
			return FOOD_BOMB_ALONE
		return min(FOOD_BOMB_MAX, FOOD_BOMB_PER * near)
	if mode == "bank" and missing_hp <= 0.0:
		# The ground is the safest inventory: fruit not yet eaten is healing that
		# cannot be wasted. Step on it once the healing is real, not before.
		return FOOD_BANK_FULL
	# Hurt: a banked heal becomes an OPPORTUNITY, not a tie-breaker. The whole
	# term scales with --arb-food (default 2.5), INCLUDING its cap:
	#   food_mult * min(FOOD_MAX, missing_hp)   ->  30 at the default.
	# Scaling only the value under a flat FOOD_MAX=12 cap is a no-op for real
	# damage -- min(12, missing*2.5) equals the old min(12, missing) from 12 HP
	# lost upward -- which is exactly the "hurt but won't eat fruit" case the
	# player reported. The scaled cap stays a tie-breaker against real threats
	# (a 15-65 threat still wins, especially after the pickup distance term).
	# food_mult = 1 reproduces the old value exactly, so the flag is a clean
	# A/B dial; food_mult = 0 falls through to the old unscaled formula (exact
	# control arm).
	if food_mult > 0.0:
		return food_mult * min(FOOD_MAX, missing_hp)
	return min(FOOD_MAX, missing_hp)


# --- v2.4.0: Primal Dread evolution pickups --------------------------------
#
# The four evolution consumables are new RESOURCES, not a new healing path: a
# meca/mutant fruit is one point of stat_evolution (a permanent camp
# commitment), a mutation fruit opens the wave-end "mutate an item" choice, and
# meca parts are the weapon-evolution currency. The old gather() priced every
# consumable with _food_value, i.e. by MISSING HP: at full HP a bank-mode kit
# priced them NEGATIVE (-0.8) and even a full-HP-eater valued them as healing
# that does nothing. And none of them can be collected by the attract area
# (Player.can_attract_consumable_data explicitly excludes meca/mutant fruit,
# and ItemAttractArea only pulls heal-effect consumables), so the only way to
# take one is to physically walk the ItemPickupArea over it. A food-priced
# reward can never justify that detour -- which is the reported bug: they lie
# on the floor for the whole wave.
#
# So they get a dedicated reward class, a walk-on rim (EVO_WALK_RIM) plus the
# v2.5.0 r[4]=1.0 walk-on tag instead of the attract rim, and the eligibility
# gates the GAME itself uses: picking up
# an ineligible fruit does nothing at best and drags the evolution bar the
# wrong way at worst, so the bot must not path to one it cannot use.

# Value of one consumable for the arbiter. 0.0 = do not collect / do not price.
func _consumable_value(c, player, food_mode: String, missing_hp: float, spawner) -> float:
	var data = c.get("consumable_data")
	if data == null:
		return 0.0
	# v2.6.0: item crates (normal / legendary) are a whole item choice, not
	# just the 3/100 HP their healing effect happens to carry. Price them as
	# the better of "food value" and their item value so a full-HP bank-mode
	# kit still walks over one when the floor is calm (the goal layer picks it
	# up from the reward list). --arb-boxes=0 restores the 2.5.0 food pricing.
	if boxes_mult != 0.0:
		var boxv = _box_value(c) * boxes_mult
		if boxv > 0.0:
			var foodv = 0.0
			if _consumable_is_food(c):
				foodv = _food_value(food_mode, c.position, missing_hp, spawner)
			return max(foodv, boxv)
	var kind = _evolution_consumable_kind(data)
	if kind != "":
		# 0 is the exact v2.3.0 control arm. (The gather loop branches on it
		# before calling here and runs the old food-only line verbatim; the
		# guard stays so a direct caller sees "feature off" rather than a
		# value that would be applied to a reward the old build never made.)
		if evo_mult == 0.0:
			return 0.0
		var pi = int(player.player_index)
		# The game's own gate: camp locks, evolution threshold, DLC presence.
		if not RunData.can_pick_up_consumable(data, pi):
			return 0.0
		if not _evolution_direction_ok(kind, pi):
			return 0.0
		return evo_mult * _evolution_base_value(kind)
	if not _consumable_is_food(c):
		# Non-healing, non-evolution consumables are not food. In 1.2.0.1 the
		# only one is DLC1's poisoned fruit (ConsumableDamageEffect: eating it
		# HURTS), which the old generic _food_value line happily priced as
		# healing and walked over when hurt. Unknown future pickups are left
		# out for the same reason: "not healing" is the honest price of an
		# effect class this function does not understand.
		return 0.0
	return _food_value(food_mode, c.position, missing_hp, spawner)


# v2.5.0 wave-end urgency for a walk-on evolution pickup, applied to the value
# AFTER _consumable_value (so it never rescues an ineligible or zero-priced
# item) and BEFORE the reward is pushed. Only meca/mutant fruit are lost at the
# horn (attracted_at_end_of_wave=false); mutation fruit / meca parts are
# vacuumed and return 1.0. wave_time_left is 1e9 between waves, so the scaling
# is a no-op there. Never lowers a value: clamped at 1.0 / EVO_WAVEEND_CAP.
func _evo_waveend_scale(kind: String, dist: float) -> float:
	if waveend_mult == 0.0:
		return 1.0
	if kind != "meca_fruit" and kind != "mutant_fruit":
		return 1.0
	var eta = dist / max(player_speed, 1.0)
	var span = eta + EVO_WAVEEND_MARGIN
	if wave_time_left >= span:
		return 1.0
	return clamp(1.0 + EVO_WAVEEND_BOOST * (1.0 - wave_time_left / span),
			1.0, EVO_WAVEEND_CAP)


# v2.6.0: item crate detection by the game's own id hashes (with id-string
# fallback for resources whose hash channel is deferred). 0 = not a crate.
func _box_value(c) -> float:
	var data = c.get("consumable_data")
	if data == null:
		return 0.0
	var id_hash = data.get("my_id_hash")
	if typeof(id_hash) == TYPE_INT or typeof(id_hash) == TYPE_REAL:
		var ih = int(id_hash)
		if ih == Keys.consumable_legendary_item_box_hash:
			return LEGENDARY_BOX_VALUE
		if ih == Keys.consumable_item_box_hash:
			return BOX_VALUE
	var my_id = data.get("my_id")
	if my_id is String:
		if my_id == "consumable_legendary_item_box":
			return LEGENDARY_BOX_VALUE
		if my_id == "consumable_item_box":
			return BOX_VALUE
	return 0.0


# Healing consumables keep the old attract-rim semantics (the arbiter prices
# them at profile pickup_radius). Everything else -- today only the evolution
# items -- is a physical walk-on pickup, priced with the EVO_WALK_RIM rim and
# (v2.5.0) the r[4] walk-on tag so the rim payment is one-shot, not held.
func _consumable_is_food(c) -> bool:
	return c.has_method("has_healing_effect") and c.has_healing_effect()


# Convenience wrapper so gather() can count ground evolution pickups for
# telemetry without unpacking the Consumable -> ConsumableData hop itself.
func _consumable_kind(c) -> String:
	return _evolution_consumable_kind(c.get("consumable_data"))


# "" = ordinary consumable; otherwise one of the four evolution kinds.
# Detection is by the game's own id hash; the declared id string and the effect
# list are fallbacks for a resource whose hash generation was deferred
# (ItemParentData generates my_id_hash call_deferred from my_id) and for
# hand-built data in offline tests. The effect fallback is what still catches
# meca_parts if the hash channel is unavailable -- its GainMecaPartsEffect is
# serialized with key "meca_parts" and value 2.
func _evolution_consumable_kind(data) -> String:
	if data == null:
		return ""
	var id_hash = data.get("my_id_hash")
	if typeof(id_hash) == TYPE_INT or typeof(id_hash) == TYPE_REAL:
		var ih = int(id_hash)
		if ih == Keys.consumable_meca_fruit_hash:
			return "meca_fruit"
		if ih == Keys.consumable_mutant_fruit_hash:
			return "mutant_fruit"
		if ih == Keys.consumable_mutation_fruit_hash:
			return "mutation_fruit"
		if ih == Keys.consumable_meca_parts_hash:
			return "meca_parts"
	var my_id = data.get("my_id")
	if my_id is String and my_id != "":
		if my_id == "meca_consumable_fruit":
			return "meca_fruit"
		if my_id == "mutant_consumable_fruit":
			return "mutant_fruit"
		if my_id == "mutation_consumable_fruit":
			return "mutation_fruit"
		if my_id == "meca_parts_consumable":
			return "meca_parts"
	var effects = data.get("effects")
	if effects is Array:
		for e in effects:
			if e == null:
				continue
			var ekey = e.get("key")
			if not (ekey is String) or ekey == "":
				continue
			if ekey == "stat_evolution":
				# meca fruit is +1 (key = stat_evolution, value = 1), mutant
				# fruit is -1: the sign IS the camp.
				var ev = 0.0
				var evalue = e.get("value")
				if typeof(evalue) == TYPE_INT or typeof(evalue) == TYPE_REAL:
					ev = float(evalue)
				return "meca_fruit" if ev > 0.0 else "mutant_fruit"
			if ekey == "meca_parts":
				return "meca_parts"
	return ""


# What one evolution pickup is worth BEFORE --arb-evo: fruit 6 (a camp point),
# mutation fruit 9 (a wave-end item mutation -- the strongest single pickup),
# meca parts 6 (two parts, half a weapon evolution). These are OPPORTUNITY
# values, sized like LOOT_VALUE (4) and below EGG_VALUE (60): they shape a path
# that is already safe, never outbid a real threat.
func _evolution_base_value(kind: String) -> float:
	if kind == "mutation_fruit":
		return EVO_MUTATION_VALUE
	if kind == "meca_parts":
		return EVO_PARTS_VALUE
	return EVO_FRUIT_VALUE


# Camp direction. RunData.can_pick_up_consumable already enforces the hard game
# rule (camp lock, evolution threshold); this adds the policy the spec asks
# for: a non-dual kit must not be tempted ACROSS the zero line -- a meca fruit
# is only worth a step while the bar is on the meca side, a mutant fruit only
# while it is on the mutant side. mutation fruit / meca parts have no direction
# of their own; the game gate is the whole rule for those.
func _evolution_direction_ok(kind: String, player_index: int) -> bool:
	if RunData.is_dual_evolution(player_index):
		return true
	var evolution = float(RunData.get_player_effect(Keys.stat_evolution_hash, player_index))
	if kind == "meca_fruit":
		return not RunData.is_mutant_only(player_index) and evolution >= 0.0
	if kind == "mutant_fruit":
		return not RunData.is_meca_only(player_index) and evolution <= 0.0
	return true


func _caution(row: Dictionary, hp_ratio: float = 1.0) -> float:
	var c = float(row.get("caution", 1.0))
	if row.has("caution_phases"):
		c = _phase_value(row["caution_phases"], 1.0)
	if row.has("caution_below") and hp_ratio < float(row["caution_below"][0]):
		# The other half of an HP-band kit: below the band it is not merely
		# "not seeking contact", it is actively kiting to let regen refill --
		# Bull's "back off and regenerate" -- so caution flips ABOVE baseline.
		c = float(row["caution_below"][1])
	if row.has("caution_per_wave"):
		# Captain hands every enemy +2 HP and +2 damage per wave, Romantic sheds
		# armour to curse on the same clock: the danger compounds, so caution has
		# to climb with it instead of sitting at whatever suited wave 1.
		c += float(row["caution_per_wave"]) * max(RunData.current_wave - 1, 0)
	return max(c * caution_mult, 0.1)


# Contact seeking -- the inverse of kiting. For characters paid in hits TAKEN
# (bull explodes when hit; vampire/lich/masochist scale off missing HP) or in
# one swing landing across a crowd (dwarf, ogre, artificer). Both gates matter:
# they switch the behaviour off exactly where it would otherwise kill the run.
var last_engage_block = "-"      # why _engage returned 0 this frame: off|hp|boss|pack|ok

func _engage(row: Dictionary, hp_ratio: float, pos: Vector2, spawner) -> float:
	last_engage_block = "off"
	var e = float(row.get("engage", 0.0))
	if e <= 0.0:
		return 0.0
	last_engage_block = "hp"
	var band = float(row.get("engage_hp", 0.0))
	if engage_hp_override != null:
		band = engage_hp_override
	if row.has("engage_end_hp") and wave_time_left <= float(row.get("end_secs", 8.0)):
		# "Clear as many enemies right before the end of the wave as
		# possible": the band drops for the final seconds, because HP spent
		# now buys income and there is no next crowd this wave to save it for.
		band = float(row["engage_end_hp"])
	if hp_ratio <= band:
		return 0.0    # below the band: break off and let the kit refill
	last_engage_block = "boss"
	# The rule is a bool for most rows and the String "trash" for Bull. Never
	# compare the two with != directly: GDScript 3 raises "Invalid operands"
	# for String-vs-bool, which aborted this function every frame and left
	# Bull's dive permanently disarmed (eblk=boss on a wave with no boss).
	var boss_rule = row.get("engage_boss", false)
	var allow_with_boss = (boss_rule is bool and boss_rule) \
			or (boss_rule is String and boss_rule == "trash")
	if not allow_with_boss:
		# Every guide for these characters draws the same line: walk into TRASH,
		# never into the elite. The mechanics that pay for contact -- an explosion
		# per hit taken, lifesteal, a swing across six bodies -- all scale with
		# enemy COUNT, and an elite is one body that hits back far harder than the
		# trash the behaviour was designed around. Knight is the documented
		# exception and opts back in with engage_boss.
		for b in spawner.bosses:
			if is_instance_valid(b) and not b.dead:
				last_engage_block = "boss:" + str(b.get("enemy_id"))
				return 0.0
	if row.has("engage_pack"):
		# A herder must not charge the first enemy it sees: the payoff needs a
		# CLUMP (dwarf wants 6 kills in one hit), and engaging early is exactly
		# what stops one forming.
		var near = 0
		var r_sq = ENGAGE_PACK_RADIUS * ENGAGE_PACK_RADIUS
		for en in spawner.enemies:
			if is_instance_valid(en) and not en.dead and not en.is_loot \
					and en.position.distance_squared_to(pos) < r_sq:
				near += 1
		last_engage_block = "pack"
		if near < int(row["engage_pack"]):
			# No pile yet. engage_pack_seek keeps a reduced pull toward the
			# nearest enemy so the kit HUNTS the next pile instead of waiting
			# for one to arrive -- every "pack" second on the Bull logs was dead
			# time. The resolver drops cluster mode for it (see gather), so the
			# pull is the plain nearest-body term at full share.
			var seek = float(row.get("engage_pack_seek", 0.0))
			if seek > 0.0:
				last_engage_block = "seek"
				return e * seek
			return 0.0
	last_engage_block = "ok"
	return e


# Writes the anchor keys into `profile`. The modes differ only in where the
# point comes from and whether the cost is for straying OUT (a leash) or for
# closing IN (a keep-out ring); the arbiter needs nothing but radius and inner.
func _resolve_anchor(row: Dictionary, spawner) -> void:
	var mode = row.get("anchor", "")
	if mode == "":
		return
	if row.has("anchor_wave") and RunData.current_wave < int(row["anchor_wave"]):
		return
	if row.has("gold_end") and wave_time_left <= float(row.get("end_secs", 8.0)):
		return    # the end-of-wave sweep needs the leash off, or it only sweeps the pod

	var point = far_corner * 0.5
	var radius = float(row.get("anchor_radius", 0.0))
	var inner = float(row.get("anchor_inner", 0.0))
	if anchor_inner_override != null and inner > 0.0:
		inner = anchor_inner_override
	if center_mode_override > 0.0 and mode == "perimeter":
		mode = "center"
		inner = 0.0
		radius = center_mode_override

	if mode == "builder":
		if RunData.current_wave <= BUILDER_ECON_WAVES:
			return    # phase 1 roams to collect; a leash would cost every material
		var turret = _builder_turret(spawner)
		if turret == null:
			return
		point = turret.position
		# Leash to the turret's own firing circle: enemies chasing a player
		# inside it are enemies the turret gets to shoot.
		var turret_range = float(turret.stats.max_range) if turret.stats else BUILDER_ANCHOR_MAX
		radius = clamp(turret_range, BUILDER_ANCHOR_MIN, BUILDER_ANCHOR_MAX)
		if leash_override > 0.0:
			radius = leash_override
	elif mode == "structures" or mode == "away_structures":
		# The centroid, not the nearest: Engineer's turrets spawn as a POD and
		# the pod's middle is the spot the guides describe standing in. With one
		# structure the centroid is that structure, so Mage's keep-away works off
		# the same number.
		var c = _structure_centroid(spawner)
		if c.empty():
			return
		point = c[0]
	elif mode != "center" and mode != "perimeter":
		return
	# center and perimeter both anchor on the arena middle and differ only in
	# which side of it costs: a perimeter row sets inner and no radius, so the
	# cheapest floor is the rim and the bot laps it instead of parking on a wall.

	profile["anchor"] = point
	if radius > 0.0:
		profile["anchor_radius"] = radius
	if inner > 0.0:
		profile["anchor_inner"] = inner


func _structure_centroid(spawner) -> Array:
	if not ("structures" in spawner):
		return []
	var sum = Vector2.ZERO
	var n = 0
	for s in spawner.structures:
		if is_instance_valid(s):
			sum += s.position
			n += 1
	if n == 0:
		return []
	return [sum / n]


func _builder_turret(spawner):
	if not ("structures" in spawner):
		return null
	for s in spawner.structures:
		if is_instance_valid(s) and s is BuilderTurret:
			return s
	return null


func _builder_gold_value(player) -> float:
	var phase = 1
	var struct_range = 0
	if RunData.current_wave > BUILDER_ECON_WAVES:
		struct_range = int(RunData.get_player_effect(Keys.structure_range_hash, player.player_index))
		phase = 2 if BuilderTurret.get_level(struct_range) < BUILDER_TURRET_MAX_LEVEL else 3
	if phase != _builder_phase:
		_builder_phase = phase
		print("BOTLOG BUILDER phase=%d wave=%d struct_range=%d" % [
				phase, RunData.current_wave, struct_range])
	if gold_value_override != null:
		return gold_value_override
	if phase == 1:
		return GOLD_VALUE            # economy first, collect everything
	if phase == 2:
		return BUILDER_GOLD_VALUE    # feed the turret to its final tier
	return BUILDER_GOLD_LATE         # maxed; take some, not all


# --- v2.4.0: DLC enemy classification --------------------------------------
#
# Curse (DLC1 Abyssal Terrors): CurseEnemyEffectBehavior.init adds the DLC
# outline color (Utils.CURSE_COLOR = ca61ff) to the enemy and nothing removes
# it while the body is alive (Entity._outline_colors is cleared only when the
# entity dies / returns to the pool). There is no cursed flag on Unit, so the
# outline is the one reliable public marker -- and it is also exactly what the
# player sees, which keeps the bot's read of the screen honest.
#
# Evolution (DLC2 Primal Dread): EvolutionSceneEffectBehavior sets
# Enemy._is_meca / Enemy._is_mutant (both exported, false by default) when it
# boosts a body, and evolved scenes can author the flags directly. The "in"
# guards keep the read safe for any unit shape that does not carry them
# (boss subclasses, offline fakes) -- GDScript's `in` on an Object tests for
# the property instead of throwing.
func _enemy_is_cursed(unit) -> bool:
	return unit.has_method("has_outline") and unit.has_outline(Utils.CURSE_COLOR)


func _enemy_is_evolved(unit) -> bool:
	if ("_is_meca" in unit) and unit._is_meca:
		return true
	return ("_is_mutant" in unit) and unit._is_mutant


# The avoid side of a signed DLC knob: v<0 makes the body a hazard whose damage
# is multiplied by (1+|v|) (v=-1 -> x2, "twice as scary"). Engage and control
# values return 1.0, so the all-zero arm keeps damage bit-identical.
func _avoid_scale(v: float) -> float:
	return 1.0 - v if v < 0.0 else 1.0


func _add_unit(unit, pos: Vector2, range_sq: float, target_range_sq: float, pickup_sq: float) -> void:
	if unit.dead or unit._pending_die:
		return
	if unit.has_method("get_charmed_by_player_index") and unit.get_charmed_by_player_index() != -1:
		return    # allied, harmless

	var offset = unit.position - pos
	var dist_sq = offset.length_squared()

	if unit.is_loot:
		# Loot aliens flee and are worth chasing, not avoiding -- for anyone
		# who can catch and kill one. Pacifist can do neither (loot_value 0).
		if dist_sq < pickup_sq and _loot_value != 0.0:
			rewards.push_back([unit.position, _loot_value])
		return

	var radius = _body_radius(unit)
	var damage = DEFAULT_CONTACT_DAMAGE
	if unit.current_stats and unit.current_stats.damage > 0:
		damage = float(unit.current_stats.damage)

	# v2.4.0 DLC kinds (see the classification block above). Both feeds matter:
	# the target value below decides whether the bot is willing to KEEP this
	# body inside weapon range, and the threat damage decides how hard it tries
	# to keep away from it. The counters feed the once-a-second BOTLOG line.
	var cursed = _enemy_is_cursed(unit)
	var evolved = _enemy_is_evolved(unit)
	if cursed:
		last_cursed_n += 1
	if evolved:
		last_evolved_n += 1

	# The avoid half of the knobs. The curse/evolution stat boost is already
	# inside current_stats.damage; a negative knob multiplies that by (1+|v|)
	# so "avoid" both removes the target pull below and makes the approach
	# genuinely more expensive. v>=0 leaves damage untouched (bit-identical to
	# the old build), which is what the all-zero control arm requires.
	var threat_damage = damage
	if cursed:
		threat_damage *= _avoid_scale(curse_mult)
	if evolved:
		threat_damage *= _avoid_scale(evolved_mult)

	# Targets reach further than threats: a weapon can outrange the distance at
	# which an enemy endangers us, and clipping targets to the threat radius
	# blinded the bot to things it could already be shooting.
	if dist_sq < target_range_sq:
		# Third field: is this a boss/elite. The cluster engage mode must
		# never count one as part of the pile it dives into.
		#
		# v2.4.0: the DLC target stance. _kill_value keeps the ORIGINAL damage
		# (killability is about the body, not about the stance) and the signed
		# knob then scales it (engage) or zeroes it (avoid). Only non-Boss
		# bodies get the TARGET-value treatment: an elite is not a fight the
		# bot chose to pick, and multiplying its target value would pull the
		# bot into its face -- the opposite of what the default stance should
		# do to an elite. Bosses still get the avoid side on the threat damage
		# (scaled in _add_unit before this block), which is all "keep away"
		# needs. When both kinds apply, engage multipliers multiply and either
		# avoid zeroes the value.
		var tv = _kill_value(unit, damage)
		if not (unit is Boss):
			if cursed and curse_mult > 0.0:
				tv *= curse_mult
			if evolved and evolved_mult > 0.0:
				tv *= evolved_mult
			if (cursed and curse_mult < 0.0) or (evolved and evolved_mult < 0.0):
				tv = 0.0
		# v2.6.0: 4th field = special-target class (1 boss/elite, 2 spawner
		# egg, 3 cursed/evolved) for the arbiter's bounty approach. With
		# --arb-bounty=0 the tuple stays the exact 2.5.0 3-field form.
		if bounty_tag != 0.0:
			var special = 0
			if unit is Boss:
				special = 1
			elif _is_egg(unit):
				special = 2
			elif cursed or evolved:
				special = 3
			targets.push_back([unit.position, tv, unit is Boss, special])
		else:
			targets.push_back([unit.position, tv, unit is Boss])

	if dist_sq >= range_sq:
		return    # too far to threaten us this horizon

	var corridor = _dash_corridor(unit)
	if not corridor.empty():
		corridor[3] = threat_damage
		# v2.6.1: during the wind-up the dash lane has not started yet, but the
		# body is FROZEN in place with a live contact hitbox. The lane tuple does
		# not cover the pre-launch interval (the arbiter integrates a threat only
		# over [T_START, T_END]), so without this the wind-up body is free to
		# walk over: a probe priced walking straight through it at 0.00 vs 17.42
		# for a plain walker (20 px case; 0.93 vs 16.15 at 60 px). Price the
		# frozen body as a contact threat that expires exactly when the dash
		# launches; the lane then takes over. In flight (T_START == 0) the lane
		# already is the body, so nothing is added. --arb-windup=0 = old tuple.
		var launch = float(corridor[5])
		if windup_priced != 0.0 and launch > 0.0001:
			var frozen_health = 20.0
			if unit.current_stats and unit.current_stats.health > 0:
				frozen_health = float(unit.current_stats.health)
			threats.push_back([unit.position, Vector2.ZERO, radius, threat_damage,
					KIND_CONTACT, 0.0, _contact_ticks(0.0), launch,
					_kill_ref / (_kill_ref + frozen_health)])
		threats.push_back(corridor)
		return    # a dashing body is described by its dash, not by its walk

	# Idle charger: not dashing yet, but its cooldown is a clock. Standing
	# inside its launch range when that clock runs out is a choice, and the
	# arbiter can only price it if it knows the range and the remaining time.
	var ab = unit._current_attack_behavior
	if ab is ChargingAttackBehavior:
		chargers.push_back([unit.position, float(ab.max_range), threat_damage,
				max(ab._current_cd, 0.0) / 60.0])    # _current_cd counts frames

	# Model the walker as moving at its own speed toward wherever it is headed.
	# Most enemies chase the player directly, but fly-likes commit to a frozen
	# point near us — steering at the player would put them somewhere they were
	# never going. Over a sub-second horizon this is close enough, and it is
	# what makes contact cost fall out of geometry instead of a panic ramp.
	var chase = Vector2.ZERO
	var unit_speed = 0.0
	if unit.current_stats:
		# Speed boosts live OUTSIDE current_stats: a pursuer's boost_self()
		# accumulates in Unit.bonus_speed (+45 per second, up to +450, reset on
		# hit), so reading current_stats alone models a 600 px/s chaser at 150.
		# That error poisons both uses of this number -- the projected future
		# position (the pursuer "cannot reach us this horizon" while actually
		# crossing 480 px of it) and _contact_ticks' can-you-outrun test (150
		# says shed it at once; 600 says it never lets go). The observed failure
		# mode is exactly that: the bot stands while a boosted pursuer walks the
		# last 400 px into it. decaying_bonus_speed is the same channel with a
		# sign: knockback slows really do make a body less able to reach us.
		unit_speed = max(float(unit.current_stats.speed)
				+ bonus_speed_scan * (float(unit.bonus_speed)
				+ float(unit.decaying_bonus_speed)), 0.0)
		var goal = pos
		var mb = unit._current_movement_behavior
		if mb and ("_current_target" in mb) and mb._current_target != Vector2.ZERO:
			goal = mb._current_target
		var toward = goal - unit.position
		if toward.length_squared() > 1.0:
			chase = toward.normalized() * unit_speed
	# The optional 9th field is the body's killability (same falloff as
	# _kill_value): the arbiter's fire_still discount reads it to price
	# "standing here SHOOTS this thing before it arrives". Contact threats
	# only -- a bullet cannot be shot down and a dash connects regardless.
	var health = 20.0
	if unit.current_stats and unit.current_stats.health > 0:
		health = float(unit.current_stats.health)
	threats.push_back([unit.position, chase, radius, threat_damage, KIND_CONTACT, 0.0,
			_contact_ticks(unit_speed), INF_TIME,
			_kill_ref / (_kill_ref + health)])


# Returns a dash threat tuple, or [] if this unit is not currently dashing or
# winding up a dash. Either way it is one moving body; a wind-up is the same
# body with its motion deferred until the telegraph animation finishes.
func _dash_corridor(unit) -> Array:
	var behavior = unit._current_attack_behavior
	if not (behavior is ChargingAttackBehavior):
		return []

	var in_flight = unit._move_locked
	var winding_up = (not unit._can_move) and (not in_flight)
	if not (winding_up or in_flight):
		return []
	if winding_up and behavior.target_calculation_timing != ChargingAttackBehavior.Timing.START_SHOOT:
		return []    # direction is not decided yet, so there is nothing to dodge

	var charge_dir = behavior._charge_direction
	if charge_dir.length_squared() < 1.0:
		return []

	var dir = charge_dir.normalized()
	# Same bonus_speed blindness as the walker fix above: a dash rides on the
	# unit's live base speed, boosts included. The launch itself is applied
	# by the game AS bonus_speed (charging_attack_behavior.shoot: bonus_speed
	# = charge_speed), so once in flight the boost is already in the live
	# figure; adding charge_speed on top priced a croc dash at 1550 px/s
	# instead of 950 (tracker Jack w11: the bot fled dashes from 440 px into
	# its own pillar ring). During the wind-up the boost is still to come.
	var dash_speed = max(float(unit.current_stats.speed)
			+ bonus_speed_scan * (float(unit.bonus_speed)
			+ float(unit.decaying_bonus_speed)), 0.0)
	if not in_flight or bonus_speed_scan == 0.0 or dash_fix == 0.0:
		dash_speed += behavior.charge_speed
	var radius = _body_radius(unit)
	var damage = DEFAULT_CONTACT_DAMAGE
	if unit.current_stats and unit.current_stats.damage > 0:
		damage = float(unit.current_stats.damage)

	var launch_delay = 0.0
	if not in_flight:
		launch_delay = _windup_remaining(unit)
	# The charge ENDS: charging_attack_behavior unlocks movement when its
	# charge_duration timer runs out (0.5-0.6 s for the croc = ~520 px), and
	# the body is an ordinary walker again. An unbounded lane priced every
	# candidate along the bearing for the whole horizon, which is what made
	# radial flight the only answer to a dash that stops short.
	var t_end = INF_TIME
	if dash_fix != 0.0 and ("_unlock_move_timer" in behavior) and behavior._unlock_move_timer != null:
		var timer = behavior._unlock_move_timer
		var left = float(timer.time_left) if in_flight else float(timer.wait_time)
		t_end = launch_delay + max(left, 0.0)
	# A dash connects once and then the charger is spent and recovering, so it
	# is not priced as sustained contact however fast the corridor moves.
	return [unit.position, dir * dash_speed, radius, damage, KIND_DASH, launch_delay,
			TICKS_ONCE, t_end]


# Seconds until a winding-up charge actually launches. The telegraph animation
# is a fixed WINDUP_ANIM_LENGTH played at the behavior's playback speed, so the
# remaining time is readable rather than guessed. Falling back to zero treats
# the dash as already moving, which errs toward dodging early.
func _windup_remaining(unit) -> float:
	var anim = unit._animation_player
	if anim == null or not anim.is_playing():
		return 0.0
	var speed = max(anim.playback_speed, 0.01)
	return max(WINDUP_ANIM_LENGTH - anim.current_animation_position, 0.0) / speed


# Projectiles parented to a boss rather than to EnemyProjectiles. Currently that
# means Pivot-mounted orbiters; the Pivot carries the angular rate we need.
func _add_attached(unit, pos: Vector2, range_sq: float) -> void:
	if unit.dead or unit._pending_die:
		return
	for child in unit.get_children():
		if not (child is Pivot):
			continue
		# pivot.gd: rotation += direction * rotation_speed * accessibility * delta
		var omega = child.direction * child.rotation_speed \
				* RunData.current_run_accessibility_settings.speed
		for orb in child.get_children():
			if not (orb is Projectile):
				continue
			if not orb._hitbox or not orb._hitbox.active or orb._hitbox.is_disabled():
				continue
			_add_orbiter(orb, child, omega, pos, range_sq)


func _add_orbiter(p, pivot, omega: float, pos: Vector2, range_sq: float) -> void:
	# global_*, not position/rotation: these are nested two levels under the
	# boss, so the local transform is meaningless in world terms.
	var center = p.global_position
	if p._hitbox and p._hitbox._collision:
		center = p.global_position \
				+ (p._hitbox.position + p._hitbox._collision.position).rotated(p.global_rotation)
	if center.distance_squared_to(pos) > range_sq:
		return

	var radius = _projectile_radius(p)
	var damage = _projectile_damage(p)
	var arm = center - pivot.global_position
	var step = SIN_DRIFT_HORIZON / float(ORBIT_SAMPLES)
	# Widen by how far along the arc it travels inside one sample window.
	var drift = min(abs(omega) * arm.length() * step * 0.5, ORBIT_SMEAR_MAX)
	for i in range(ORBIT_SAMPLES):
		var t0 = float(i) * step
		var t1 = t0 + step
		var mid = (t0 + t1) * 0.5
		var at = pivot.global_position + arm.rotated(omega * mid)
		threats.push_back([at, Vector2.ZERO, radius + drift, damage, KIND_PROJ,
				t0, TICKS_ONCE, t1])


func _add_projectile(p, pos: Vector2, range_sq: float) -> void:
	# The danger is where the hitbox is, not where the node is: a slash carries
	# its blade at a rotated offset, so a node-centered threat misses by a body
	# width on exactly the attacks that hurt most.
	var center = p.position
	if p._hitbox and p._hitbox._collision:
		center = p.position + (p._hitbox.position + p._hitbox._collision.position).rotated(p.rotation)
	if center.distance_squared_to(pos) > range_sq:
		return

	var radius = _projectile_radius(p)
	var damage = _projectile_damage(p)

	if p.velocity.length_squared() < STATIONARY_SPEED_SQ:
		# Read the pillar's clock off its animation, exactly as _windup_remaining
		# does for a charge. Unknown animation state falls through as "live now,
		# never expires", which is the old behaviour -- so an AoE type that does
		# not animate like a pillar is still feared rather than silently ignored.
		var arm_in = 0.0
		var disarm_in = INF_TIME
		var profile = {"swept": false}
		var anim = p._animation_player
		if anim and anim.is_playing():
			profile = _aoe_profile(anim)
			if aoe_clock != 0.0:
				var anim_speed = max(anim.playback_speed, 0.01)
				var anim_pos = anim.current_animation_position
				if anim_pos >= profile["disarm"]:
					return    # already spent; stop fleeing dead telegraphs
				arm_in = max(profile["arm"] - anim_pos, 0.0) / anim_speed
				disarm_in = (profile["disarm"] - anim_pos) / anim_speed
		var dmg = _aoe_damage(p)
		for seg in _stationary_segments(p, profile):
			threats.push_back([seg[0], Vector2.ZERO, seg[1], dmg, KIND_AOE,
					arm_in, TICKS_ONCE, disarm_in])
		return

	# A MOVING telegraphed projectile -- a colossus pillar, fired at 150 or 300
	# rather than parked -- is armed for the same 0.14 s slice as a stationary
	# one, but it used to fall straight through to the always-live branch below.
	# So an 18-pillar ring spawned around the player at 400 px read as an
	# impassable wall, when in truth every pillar in it is inert for its first
	# 0.54 s: over half a second in which the bot can simply walk out between
	# them. That is the colossus encircling attack, and this is why it could not
	# be answered.
	#
	# Gated on `windowed`, so it applies ONLY where a genuine
	# enable_hitbox/disable_hitbox pair exists. Ordinary bullets have no method
	# track and are untouched.
	var m_anim = p._animation_player
	if aoe_clock != 0.0 and moving_clock != 0.0 and m_anim and m_anim.is_playing():
		var m_prof = _aoe_profile(m_anim)
		if m_prof["windowed"]:
			var m_speed = max(m_anim.playback_speed, 0.01)
			var m_pos = m_anim.current_animation_position
			if m_pos >= m_prof["disarm"]:
				return    # already spent; its hitbox will never come back
			var m_arm = max(m_prof["arm"] - m_pos, 0.0) / m_speed
			var m_off = (m_prof["disarm"] - m_pos) / m_speed
			# Carry the threat forward to where it will be when it goes live --
			# the scorer defers a threat's MOTION until T_START (that is what
			# makes a dash wind-up tractable), which is wrong for something
			# already in flight.
			var carry = p.velocity * m_arm

			# A FLYING blade is still a blade. mom throws slash_projectile_2 at
			# 650: geometrically identical to the butcher's -- sweeps -122..143,
			# peaks at 273x28, armed 0.48-0.60 -- but the decomposition lived
			# only in the stationary branch, so in flight it was priced as a
			# CIRCLE of radius max(extents) = 136 against a blade 14 px thin.
			# That is the same ~10x perpendicular over-estimate that made the
			# butcher undodgeable as a 320 px disc, and mom's slashes are the
			# single largest killer on w11-dwarf at 2.0 hits/run.
			#
			# Circles are deliberately left on the old single-radius path: a
			# moving pillar (colossus) is already validated at 29/30, and
			# routing it through _stationary_segments would apply the pillar
			# footprint inflation it does not currently get.
			var m_shape = null
			if p._hitbox and p._hitbox._collision:
				m_shape = p._hitbox._collision.shape
			if moving_blade != 0.0 and blade_split != 0.0 and m_shape is RectangleShape2D:
				for seg in _stationary_segments(p, m_prof):
					threats.push_back([seg[0] + carry, p.velocity, seg[1],
							damage, KIND_PROJ, m_arm, TICKS_ONCE, m_off])
			else:
				threats.push_back([center + carry, p.velocity, radius,
						damage, KIND_PROJ, m_arm, TICKS_ONCE, m_off])
			return

	# Weaving bullets: sample the sine rather than smearing it. See the
	# SIN_SAMPLES block above for why a fat radius fails on the +-600 variants.
	var amp = 0.0
	if "sinusoidal_motion" in p and p.sinusoidal_motion is Vector2:
		amp = p.sinusoidal_motion.length()
	if amp <= SIN_SIGNIFICANT or sine_sample == 0.0:
		# Gentle weave (or feature disabled): the old bound is cheap and tight.
		threats.push_back([center, p.velocity, radius + amp * 0.5 * SIN_DRIFT_HORIZON,
				damage, KIND_PROJ, 0.0, TICKS_ONCE, INF_TIME])
		return

	# Integrate position along the real path. Each sample becomes its own threat,
	# live only for the slice of time the bullet actually occupies it -- so a
	# bullet that will be somewhere in 0.6 s does not deny that ground now.
	var span = SIN_DRIFT_HORIZON
	var step = span / float(SIN_SAMPLES)
	var t_now = p.sinusoidal_time
	var rate = p.sinusoidal_motion_speed
	var amp_v = p.sinusoidal_motion * 0.5
	# NOT named `pos`: that is already a parameter of this function, and
	# redeclaring it is a GDScript parse error -- which fails world_view, fails
	# player_movement_behavior's preload of it, and drops the whole movement
	# extension with no error logged. Symptom is 7 extensions instead of 8 and a
	# bot that never steers.
	var sim_pos = center
	var sub = step / 4.0                     # integrate finer than we emit
	var elapsed = 0.0
	for _i in range(SIN_SAMPLES):
		var seg_start = elapsed
		for _s in range(4):
			t_now += Vector2(sub * rate.x, sub * rate.y)
			var off = Vector2(sin(t_now.x), sin(t_now.y)) * amp_v
			sim_pos += (p.velocity + off) * sub
			elapsed += sub
		# Radius covers the bullet plus how far it can stray between samples.
		var drift = min(amp * 0.5 * step, SIN_SMEAR_MAX)
		threats.push_back([sim_pos, Vector2.ZERO, radius + drift, damage, KIND_PROJ,
				seg_start, TICKS_ONCE, elapsed])


# Pillar damage is stamped on the hitbox at spawn like every other projectile's,
# so read it rather than assuming. The old hardcoded AOE_DAMAGE = 10 happened to
# sit right next to a wave-6 gargoyle pillar (10-11 observed in play) and drifts
# everywhere else: that attack carries damage_increase_each_wave = 1.15, so the
# constant is progressively too small as a run goes on -- under-fearing exactly
# the attack that gets deadliest.
func _aoe_damage(p) -> float:
	if p._hitbox and ("damage" in p._hitbox) and p._hitbox.damage > 0:
		return float(p._hitbox.damage)
	return AOE_DAMAGE


# One or more [world_center, radius] circles covering a stationary hitbox.
# A blob returns one circle (unchanged); a blade returns a line of them.
func _stationary_segments(p, profile: Dictionary) -> Array:
	var hb = p._hitbox
	if not hb or not hb._collision:
		return [[p.position, 8.0]]
	var base = hb.position + hb._collision.position
	var shape = hb._collision.shape

	if blade_split != 0.0 and shape is RectangleShape2D:
		# extents are HALF-extents; work in the rectangle's own frame, then
		# rotate each segment out by the projectile's rotation.
		var half_long = shape.extents.x
		var half_thin = shape.extents.y
		# Prefer the swept union: the live pose is only where the blade is at
		# this instant, and during the wind-up that is its starting stub.
		if sweep_union != 0.0 and profile.get("swept", false):
			base = hb.position + profile["centre"]
			half_long = profile["half"].x
			half_thin = profile["half"].y
		var along = Vector2(1.0, 0.0)
		if half_thin > half_long:
			var swap = half_long
			half_long = half_thin
			half_thin = swap
			along = Vector2(0.0, 1.0)
		# Only split what is actually elongated; a squarish box stays one circle.
		var n = int(clamp(ceil(half_long / max(half_thin, 1.0)), 1, BLADE_SEGMENTS_MAX))
		# Segment radius must still span the gaps left by capping n, so it is the
		# larger of the true thinness and the spacing it has to cover.
		var r = max(half_thin, half_long / float(n)) * BLADE_MARGIN
		var out = []
		for i in range(n):
			var t = -half_long + 2.0 * half_long * (float(i) + 0.5) / float(n)
			out.push_back([p.position + (base + along * t).rotated(p.rotation), r])
		return out

	# Circles (pillars) keep the old footprint inflation: their rest-pose
	# collision genuinely understates the telegraph they draw on the ground.
	# reach is the danger RADIUS; base only shifts the CENTRE (done above), so
	# adding base.length() here double-counted the hitbox offset -- for a croc
	# ring pillar (offset 20, collision ~23) that inflated a 23 px hit to ~50
	# before the mult, then 2.2x closed the 157 px pillar spacing into a solid
	# wall (0/35 on the Jack croc bed: no threadable gap existed in the model).
	var reach = _projectile_radius(p)
	return [[p.position + base.rotated(p.rotation),
			min(reach * aoe_mult, AOE_RADIUS_MAX)]]


func _projectile_radius(p) -> float:
	if not p._hitbox or not p._hitbox._collision:
		return 8.0
	var shape = p._hitbox._collision.shape
	if shape is CircleShape2D:
		return shape.radius
	if shape is RectangleShape2D:
		return max(shape.extents.x, shape.extents.y)
	return 8.0


# Hitbox.damage is where the real number lives: the shooter stamps it there at
# spawn, so it already accounts for wave scaling and danger level.
func _projectile_damage(p) -> float:
	if p._hitbox and ("damage" in p._hitbox) and p._hitbox.damage > 0:
		return float(p._hitbox.damage)
	if "damage" in p and p.damage > 0:
		return float(p.damage)
	return DEFAULT_PROJ_DAMAGE


# What killing this enemy is worth, in HP we would otherwise lose.
#
# Two factors. How much damage it does to us if it lives -- its contact damage
# over a few exchanges. And how likely we are to actually kill it soon: a 4 HP
# charger dies to a burst, an 880 HP boss does not, and rewarding the bot for
# hugging a boss it cannot kill is how a naive DPS term gets you killed.
#
# Eggs are the exception that drives the whole design. They barely damage you
# themselves, so a damage-based value scores them near zero -- but everything
# they hatch is future damage, compounding for the rest of the wave. Killing
# one early is worth far more than killing any single thing it spawns, which
# is why they carry a flat high value rather than a damage-derived one.
func _kill_value(unit, damage: float) -> float:
	var health = 20.0
	if unit.current_stats and unit.current_stats.health > 0:
		health = float(unit.current_stats.health)
	var killability = _kill_ref / (_kill_ref + health)

	var value = damage * EXPECTED_EXCHANGES
	if _is_egg(unit):
		value = max(value, EGG_VALUE)
	return value * killability


func _is_egg(unit) -> bool:
	if ("_attack_behavior" in unit) and unit._attack_behavior is SpawningAttackBehavior:
		return true
	return unit._current_attack_behavior is SpawningAttackBehavior


# Expected share of a nominal hit that actually reaches our HP. Dodge removes
# hits outright and armor scales them down, so a heavily armored build should
# genuinely be willing to walk through fire the fragile one must avoid.
func _mitigation(player) -> float:
	var m = 1.0
	var stats = player.current_stats
	if stats and ("dodge" in stats):
		m *= 1.0 - clamp(float(stats.dodge), 0.0, 0.9)
	if stats and ("armor" in stats):
		m *= clamp(RunData.get_armor_coef(stats.armor), 0.1, 1.0)
	return max(m, 0.05)


func _body_radius(unit) -> float:
	var r = BODY_RADIUS_FALLBACK
	if unit._hurtbox and unit._hurtbox._collision:
		var shape = unit._hurtbox._collision.shape
		if shape is CircleShape2D:
			r = shape.radius
		# A non-circle hurtbox was not expressible before (the old code fell back
		# to BODY_RADIUS_FALLBACK); leave that fallback in place so the switch-off
		# path stays the exact 2.6.0 value. The contact-dealing HITBOX branch
		# below supplies the conservative reach instead -- the hurtbox is the
		# damage-RECEIVING shape and its capsule (brachiosaurus) is much wider
		# than the true contact reach.
	# v2.6.1: contact damage is dealt by the enemy HITBOX — the game's contact
	# pair is (enemy Hitbox, player Hurtbox) — while this model historically used
	# the enemy HURTBOX radius. For normal trash that is the larger circle (safe,
	# over-cautious); for elites/bosses and DLC non-circle hitboxes it can be
	# SMALLER than the real reach, which is the "bot walks into the monster"
	# direction. Take the larger reach of the two and never under-estimate: plain
	# trash keeps its exact old value, so behaviour is unchanged for it.
	if hitbox_scan != 0.0 and ("_hitbox" in unit) and unit._hitbox \
			and ("_collision" in unit._hitbox) and unit._hitbox._collision:
		r = max(r, _collision_reach(unit._hitbox._collision, unit))
	return r


# Conservative circle radius AROUND THE UNIT ORIGIN enclosing one collision
# shape: the shape's own local reach x effective node scale, plus the shape
# centre's distance from the unit origin. Used only for shapes the old
# Circle-only read could not express (elites, DLC capsules, scaled nodes), and
# only in the over-cautious direction: it can price contact earlier than the
# true hitbox, never later.
func _collision_reach(col, unit) -> float:
	if col == null or col.shape == null:
		return BODY_RADIUS_FALLBACK
	var local = BODY_RADIUS_FALLBACK
	var shape = col.shape
	if shape is CircleShape2D:
		local = shape.radius
	elif shape is CapsuleShape2D:
		# height counts the end caps, so height * 0.5 is the axial half-extent
		local = max(shape.radius, shape.height * 0.5)
	elif shape is RectangleShape2D:
		local = sqrt(shape.extents.x * shape.extents.x + shape.extents.y * shape.extents.y)
	var sc = col.global_transform.get_scale()
	var centre = col.global_position - unit.global_position
	return local * max(abs(sc.x), abs(sc.y)) + centre.length()


# Kite by ranged weapons only: one melee sidearm must not drag the whole build
# down to knife range.
func _all_melee(player) -> bool:
	if not ("current_weapons" in player) or player.current_weapons.empty():
		return false
	for weapon in player.current_weapons:
		if is_instance_valid(weapon) and weapon.current_stats is RangedWeaponStats:
			return false
	return true


# v2.3.0: positive form of _all_melee for the arbiter's standoff ("kite") term.
# True when ANY equipped weapon is ranged -- one gun is enough to want distance,
# which is the mirror rule of _weapon_range (ranged weapons set the reach).
# False for an all-melee kit AND for an empty loadout: with nothing to shoot
# there is no standoff worth keeping, so profile["kite_frac"] is 0.0.
func _has_ranged_weapon(player) -> bool:
	if not ("current_weapons" in player):
		return false
	for weapon in player.current_weapons:
		if is_instance_valid(weapon) and weapon.current_stats is RangedWeaponStats:
			return true
	return false


func _weapon_range(player) -> float:
	var best = 1000.0
	var has_ranged = false
	for weapon in player.current_weapons:
		if weapon.current_stats is RangedWeaponStats:
			has_ranged = true
	for weapon in player.current_weapons:
		if has_ranged and not (weapon.current_stats is RangedWeaponStats):
			continue
		if weapon.current_stats.max_range < best:
			best = weapon.current_stats.max_range
	return best


# =============================================================================
# Build-trait profile inference (--arb-profile=auto, the default)
#
# Instead of a hand-written row per character id, derive the behavioural priors
# from signals the game already exposes at runtime: survivability (max HP vs
# mitigation), sustain (lifesteal / regen), whether weapons can fire while
# moving, standing/moving bonuses, contact payoffs (explosion on hit), and
# whether the player owns structures. The output uses exactly the same row keys
# as CHARACTER_PROFILES, so every downstream resolver (caution, engage, anchor,
# pin, fire_still, ...) is unchanged.
#
# Modes (startup arg --arb-profile=<mode>):
#   auto  (default) infer every frame from build traits, ignore the table
#   table           use the old hand-written CHARACTER_PROFILES table
#   merge           inferred row wins, table fills keys the inference omits
# =============================================================================

func _resolve_profile_row(player, spawner, character_id: String) -> Dictionary:
	var mode = _profile_mode()
	# --arb-charprofile=0 disables character-specific logic entirely (exact
	# control arm) for both the table and the inference.
	if char_profile == 0.0:
		return {}
	if mode == "table":
		return _table_row(character_id, player)
	var row = _infer_profile(player, spawner)
	if mode == "merge":
		var table_row = _table_row(character_id, player)
		for k in table_row.keys():
			if not row.has(k):
				row[k] = table_row[k]
	return row


func _profile_mode() -> String:
	if profile_mode != "":
		return profile_mode
	profile_mode = "auto"
	var args = Utils.get_startup_arguments()
	var raw = args.get("arb-profile", "")
	if raw is String:
		var m = raw.to_lower()
		if m == "auto" or m == "table" or m == "merge":
			profile_mode = m
	print("BOTLOG PROFILE_MODE ", profile_mode)
	return profile_mode


# The old hand-written table (kept for --arb-profile=table / merge and A/B).
func _table_row(character_id: String, player) -> Dictionary:
	var row = {}
	if CHARACTER_PROFILES.has(character_id):
		row = CHARACTER_PROFILES[character_id].duplicate()
		# Loadout-conditional rows. Some characters play two different games
		# depending on what they picked up -- One-Armed is a ranged kiter with
		# a gun and a lifesteal brawler with an axe -- and a row tuned for one
		# actively fights the other. `if_melee` overlays its keys when the
		# player holds NO ranged weapon (same test _weapon_range uses).
		if row.has("if_melee") and _all_melee(player):
			var merged = row.duplicate()
			for k in row["if_melee"]:
				merged[k] = row["if_melee"][k]
			row = merged
	return row


# --- Measured build traits -> behavioural row -------------------------------

func _infer_profile(player, spawner) -> Dictionary:
	var pi = int(player.player_index)
	var row = {}

	var max_hp = max(float(player.max_stats.health), 1.0)
	var mit = _mitigation(player)                       # share of incoming damage that lands
	var ehp = max_hp / max(mit, 0.05)
	var hits = ehp / DEFAULT_CONTACT_DAMAGE              # contact hits to die (rough)

	var lifesteal = _stat_float(Keys.stat_lifesteal_hash, pi)
	var regen = _stat_float(Keys.stat_hp_regeneration_hash, pi)
	var sustain = clamp(max(lifesteal / 20.0, regen / 10.0), 0.0, 1.0)

	# Weapons can only fire while standing still unless this effect is granted;
	# Soldier-style kits set it to 0, which is exactly the old hand-written
	# "fire_still" flag -- now measured instead of looked up.
	var fire_still = not _effect_enabled(Keys.can_attack_while_moving_hash, pi)

	var stand_bonus = _effect_enabled(Keys.temp_stats_while_not_moving_hash, pi) \
			or _effect_enabled(Keys.effect_stat_while_not_moving_hash, pi) \
			or _effect_enabled(Keys.effect_gold_while_not_moving_hash, pi)
	var move_bonus = _effect_enabled(Keys.temp_stats_while_moving_hash, pi) \
			or _effect_enabled(Keys.effect_stat_while_moving_hash, pi) \
			or _effect_enabled(Keys.effect_gold_while_moving_hash, pi)
	var stand_penalty = _effect_value_sum(Keys.effect_stat_while_not_moving_hash, pi) < 0.0

	var pacifist = _effect_enabled(Keys.generate_hash("pacifist"), pi)
	var cryptid = _effect_enabled(Keys.generate_hash("cryptid"), pi)
	var explosion_on_hit = _effect_enabled(Keys.explode_on_hit_hash, pi) \
			or _effect_enabled(Keys.explode_when_below_hp_hash, pi)
	var explosion_dmg = _stat_float(Keys.explosion_damage_hash, pi)

	var weapons_empty = _run_weapons_empty(player)
	var weapon_dps = _run_weapon_dps(player)
	var all_melee = _all_melee(player)

	# --- Standing / moving preference ---
	if fire_still:
		row["fire_still"] = true
		row["still"] = "prefer"
	elif stand_bonus and not move_bonus:
		row["still"] = "prefer"
	elif (move_bonus and not stand_bonus) or stand_penalty:
		row["still"] = "never"

	# --- Caution / lethality from how many hits the bar survives ---
	var contact_norm = 1.0 if (explosion_on_hit or sustain > 0.2 or all_melee) else 0.0
	var caution = 1.6 - 0.10 * (hits - 1.4) - 0.30 * sustain - 0.15 * contact_norm
	if fire_still:
		caution -= 0.4    # a stand-to-fire kit must accept pressure to shoot
	row["caution"] = clamp(caution, 0.5, 2.0)
	var lethality = clamp(4.0 + (2.5 - hits) * 0.20, 2.0, 5.0)
	if pacifist or cryptid:
		lethality = min(lethality, 3.0)
	if abs(lethality - 4.0) > 0.05:
		row["lethality"] = lethality

	# --- Pin escape: fire_still kits and fragile no-sustain kits get cornered ---
	if fire_still:
		row["pin"] = true
		row["pin_dwell"] = 40
	elif hits <= 1.2 and sustain < 0.25:
		row["pin"] = true
		row["pin_dwell"] = 0
		row["caution"] = min(float(row["caution"]) + 0.2, 2.0)

	# --- Contact seeking from payoffs that scale with hits taken ---
	if explosion_on_hit:
		if weapons_empty:
			# Bull archetype: explosion per hit taken, no weapons to fire.
			row["engage"] = 14.0
			row["engage_hp"] = 0.25
			row["engage_boss"] = "trash"
			row["engage_mode"] = "cluster"
			row["explode_trade"] = true
			row["damage_dive"] = true
			row["explosion_ref"] = true
			row["fight_room"] = 220.0
			row["avoid_births"] = 90.0
			row["dps"] = 0.0
		else:
			row["engage"] = clamp(6.0 + explosion_dmg / 25.0, 6.0, 12.0)
			row["engage_hp"] = 0.4
			if all_melee:
				row["fight_room"] = 220.0
	elif sustain > 0.2:
		row["engage"] = clamp(3.0 + 9.0 * sustain, 0.0, 12.0)
		row["engage_hp"] = 0.4
		if all_melee:
			row["fight_room"] = 220.0

	if weapons_empty and not explosion_on_hit:
		row["dps"] = 0.0
	elif weapon_dps <= 0.0:
		row["dps"] = 0.0

	# --- Streamer-style standing income (not-moving material tick) ---
	if _has_percent_materials_stand(player):
		row["stand_income"] = true
		row["stand_w"] = 1.0
		row["still"] = "prefer"

	# --- Structures / presence -> anchor leashes ---
	var has_structures = ("structures" in spawner) and not spawner.structures.empty()
	var turret = _builder_turret(spawner) if ("structures" in spawner) else null
	if turret != null:
		row["anchor"] = "builder"
		row["anchor_w"] = 2.5
		row["gold_mode"] = "builder"
	elif has_structures:
		row["anchor"] = "structures"
		var range_guess = _weapon_range(player)
		row["anchor_radius"] = clamp(range_guess * 0.6, 220.0, 320.0)

	# --- No offense at all: perimeter orbit (Pacifist / Cryptid / weaponless) ---
	if pacifist or cryptid or (weapons_empty and not explosion_on_hit and not fire_still):
		row["anchor"] = "perimeter"
		row["orbit"] = 30.0
		row["anchor_inner"] = 340.0
		if not fire_still:
			row["still"] = "never"
		row["dps"] = 0.0
		if pacifist:
			row["tree_value"] = 5.0
			row["avoid_births"] = 120.0
			row["loot_value"] = 0.0
			row["food"] = "none"

	# --- Economy: gold / food / trees from the kit's actual mechanics ---
	var harvesting = _stat_float(Keys.stat_harvesting_hash, pi)
	var gold_weight = 0.8
	var pickup_damage = _effect_enabled(Keys.dmg_when_pickup_gold_hash, pi)
	var pickup_reload = _effect_enabled(Keys.reload_when_pickup_gold_hash, pi)
	var gold_moving = _effect_enabled(Keys.effect_gold_while_moving_hash, pi)
	var gold_standing = _effect_enabled(Keys.effect_gold_while_not_moving_hash, pi)
	var gold_start = _effect_enabled(Keys.effect_gain_pct_gold_start_wave_hash, pi) \
			or _effect_enabled(Keys.gain_pct_gold_start_wave_hash, pi)
	var vacuum = _effect_enabled(Keys.effect_instant_gold_attracting_hash, pi)
	if pickup_damage:
		# Lucky: pickups deal damage, so grab them when something is in range.
		row["gold_mode"] = "enemy_gated"
		row["gold"] = 1.6
	elif pickup_reload:
		# Buccaneer: a pickup resets weapon cooldowns; spacing matters.
		row["gold_mode"] = "metered"
		row["gold"] = 2.0
	elif gold_moving or gold_standing or gold_start:
		gold_weight = 1.5
	if harvesting > 0.0:
		gold_weight = max(gold_weight, clamp(0.8 + harvesting / 15.0, 0.8, 1.6))
	if vacuum:
		gold_weight = max(gold_weight, 1.2)
		row["sweep"] = 1.5
	if not row.has("gold"):
		row["gold"] = gold_weight

	var food_bomb = _effect_enabled(Keys.explode_on_consumable_hash, pi) \
			or _effect_enabled(Keys.explode_on_consumable_burning_hash, pi)
	var no_heal = _effect_enabled(Keys.no_heal_hash, pi)
	var food_full = _effect_enabled(Keys.consumable_stats_while_max_hash, pi) \
			or _effect_enabled(Keys.temp_consumable_stats_while_max_hash, pi)
	if food_bomb:
		row["food"] = "bomb"
	elif no_heal:
		row["food"] = "none"
	elif food_full:
		row["food"] = "full_hp"
	elif not row.has("food") and food_mult > 0.0:
		# v2.3.0 default: BANK the heal. At full HP fruit is a mild cost (the
		# ground is the safest inventory, and main.gd vacuums leftovers at the
		# horn); once hurt it becomes a real opportunity (see _food_value).
		# Pacifist's explicit "none" above, and the bomb/none/full_hp rows, all
		# win. --arb-food=0 keeps the old default food mode "" (no key at all),
		# so the control arm is byte-identical to the old inferred row.
		row["food"] = "bank"

	var tree_signal = _effect_enabled(Keys.one_shot_trees_hash, pi) \
			or _effect_enabled(Keys.tree_turrets_hash, pi) \
			or _effect_enabled(Keys.effect_gain_stat_for_every_tree_hash, pi) \
			or _effect_enabled(Keys.living_tree_hash, pi)
	if tree_signal and not row.has("tree_value"):
		row["tree_value"] = 6.0
		row["gold"] = max(float(row.get("gold", 0.8)), 1.4)

	# v2.3.0 default: every ordinary kit values a living tree a little. A felled
	# tree drops a consumable + material, so it is free income whenever the
	# floor is quiet; the arbiter's threat terms still outvote it in a fight.
	# Explicit values above win (pacifist 5.0, tree-mechanic 6.0). Cryptid is
	# excluded on purpose -- its tree policy is character-specific, not this
	# generic default. --arb-tree=0 writes no key at all, so the inferred row is
	# byte-identical to the old one (exact control arm).
	if not row.has("tree_value") and not cryptid and tree_mult > 0.0:
		row["tree_value"] = DEFAULT_TREE_VALUE * tree_mult

	return row


func _effect_enabled(key_hash: int, pi: int) -> bool:
	var v = RunData.get_player_effect(key_hash, pi)
	var t = typeof(v)
	if t == TYPE_BOOL:
		return bool(v)
	if t == TYPE_INT or t == TYPE_REAL:
		return float(v) != 0.0
	if t == TYPE_ARRAY:
		return not v.empty()
	if t == TYPE_DICTIONARY:
		return not v.empty()
	return false


func _effect_value_sum(key_hash: int, pi: int) -> float:
	var total = 0.0
	var v = RunData.get_player_effect(key_hash, pi)
	if typeof(v) == TYPE_ARRAY:
		for e in v:
			if e is Array and e.size() >= 2:
				total += float(e[1])
	return total


func _stat_float(key_hash: int, pi: int) -> float:
	var v = Utils.get_stat(key_hash, pi)
	if typeof(v) == TYPE_INT or typeof(v) == TYPE_REAL:
		return float(v)
	return 0.0


func _weapons_empty(player) -> bool:
	if not ("current_weapons" in player):
		return true
	return player.current_weapons.empty()


# RunData is authoritative: the Player node's current_weapons can be empty for
# the first spawn frames, which would mis-read a normal build as weaponless.
func _run_weapons_empty(player) -> bool:
	var run_weapons = RunData.get_player_weapons(player.player_index)
	if run_weapons is Array:
		return run_weapons.empty()
	return _weapons_empty(player)


func _run_weapon_dps(player) -> float:
	var dps = 0.0
	var player_weapons = []
	if "current_weapons" in player:
		player_weapons = player.current_weapons
	if not player_weapons.empty():
		for w in player_weapons:
			if not is_instance_valid(w) or not w.stats:
				continue
			var nproj = 1.0
			if "nb_projectiles" in w.stats:
				nproj = max(float(w.stats.nb_projectiles), 1.0)
			dps += float(w.stats.damage) * nproj * 60.0 / max(float(w.stats.cooldown), 1.0)
		return dps
	var run_weapons = RunData.get_player_weapons(player.player_index)
	if run_weapons is Array:
		for w in run_weapons:
			if w == null or not ("stats" in w) or w.stats == null:
				continue
			var nproj2 = 1.0
			if "nb_projectiles" in w.stats:
				nproj2 = max(float(w.stats.nb_projectiles), 1.0)
			dps += float(w.stats.damage) * nproj2 * 60.0 / max(float(w.stats.cooldown), 1.0)
	return dps


func _has_percent_materials_stand(player) -> bool:
	var v = RunData.get_player_effect(Keys.temp_stats_while_not_moving_hash, player.player_index)
	if typeof(v) != TYPE_ARRAY:
		return false
	for ts in v:
		if ts is Array and ts.size() > 0 and int(ts[0]) == Keys.percent_materials_hash:
			return true
	return false
