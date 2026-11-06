extends Reference

# =============================================================================
# contract.gd -- SINGLE SOURCE OF TRUTH for the tuple layout / vocabulary that
# world_view.gd produces and arbiter.gd consumes.
#
# Step-1 structural refactor (task-5): these values used to be defined twice
# (world_view.gd AND arbiter.gd) and could silently drift; see
# _research/review-v3/arch/FINDINGS.md F-03/F-05. world_view/arbiter preload this
# file and keep local `const X = Contract.X` aliases so their hot loops still use
# compile-time constants (no runtime indirection), while the VALUE lives here
# only.
#
# Tuple layouts (this file is the contract; comments elsewhere are not):
#   threat  = [pos, vel, radius, damage, kind, start, ticks, end, (kill)]
#   target  = [pos, value, is_boss, (special_class)]
#   charger = [pos, range, damage, ready]
#   reward  = [pos, value, (attracted), (rim), (walk_on), (velocity), (tag)]
#
# Only constants/plain values belong in this file -- no functions, no state.
# =============================================================================

# -- threat kind (threat[T_KIND]) --
const KIND_PROJ = 0
const KIND_CONTACT = 1
const KIND_DASH = 2
const KIND_AOE = 3
const KIND_MARK = 4

# -- threat tuple layout --
const T_POS = 0
const T_VEL = 1
const T_RADIUS = 2
const T_DAMAGE = 3
const T_KIND = 4
const T_START = 5
const T_TICKS = 6
const T_END = 7
const T_KILL = 8

# -- target tuple layout --
const TG_POS = 0
const TG_VALUE = 1
const TG_BOSS = 2
const TG_SPECIAL = 3          # optional 4th field: special class (SPECIAL_*)

# -- charger tuple layout --
const C_POS = 0
const C_RANGE = 1
const C_DAMAGE = 2
const C_READY = 3

# -- reward tuple layout (the optional tail fields are described in world_view
#    gather(); consumers must use these names, never literal positions) --
const R_POS = 0
const R_VALUE = 1
const R_ATTRACTED = 2
const R_RIM = 3
const R_WALKON = 4
const R_VEL = 5
const R_TAG = 6

# -- special-target class (target[TG_SPECIAL]) --
const SPECIAL_BOSS = 1
const SPECIAL_EGG = 2
const SPECIAL_DLC = 3
const SPECIAL_ELITE = 4

# -- v2.8 high-value produce tags (reward[R_TAG]) --
const OPP_TAG_CRATE = 1
const OPP_TAG_LEGENDARY = 2
const OPP_TAG_EVO = 3
const OPP_TAG_LOOT = 4
const OPP_TAG_TREE = 5

# -- shared geometry fallback: radius used when a hurtbox/hitbox shape cannot be
#    read as a circle. world_view and arbiter both used 20.0 (pmb carried an
#    unrelated legacy constant with the same name; that one is deleted). --
const BODY_RADIUS_FALLBACK = 20.0

# -- v2.9 economy objective layer: resource-acquisition classes ----------------
# reward[R_ECON_FLAGS] is an OPTIONAL 8th tuple field (bitmask), written by
# world_view only while --arb-econ=1. Every consumer must size-check:
#   if r.size() > Contract.R_ECON_FLAGS: flags = int(r[Contract.R_ECON_FLAGS])
# econ=0 writes no extra field, so legacy readers (and the frozen v2.8.0
# control-arm comparisons) see the exact old tuple.
const R_ECON_FLAGS = 7

# Acquisition-path class of the resource (why it is / is not worth a mid-wave
# detour). A reward carries exactly one path class, plus ECON_TRIGGER when it
# also pays a mid-wave pickup-trigger effect.
const ECON_AUTO_AT_HORN = 1    # gold/fruit/box/legendary/mutation/parts: horn vacuum pays it anyway
const ECON_LOST_AT_HORN = 2    # meca_fruit/mutant_fruit, Veteran fruit: lost if not taken mid-wave
const ECON_MID_WAVE_ONLY = 4   # temp/decay/explode-on-consumable: horn vacuum does NOT trigger it
const ECON_TREE = 8            # living tree: horn destroys it and drops nothing
const ECON_TRIGGER = 16        # pays a pickup-trigger effect (gold dmg/reload/heal/...)
const ECON_SPECIAL = 32        # boss/elite/egg/cursed/evolved target (planner candidate)
