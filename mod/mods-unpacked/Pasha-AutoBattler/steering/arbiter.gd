extends Reference

# Tuple layout / vocabulary contract: single source of truth (task-5).
const Contract = preload("res://mods-unpacked/Pasha-AutoBattler/steering/contract.gd")
# Single --arb-* override parser (task-5).
const Config = preload("res://mods-unpacked/Pasha-AutoBattler/steering/config.gd")

# Arbiter: picks ONE movement action per frame by scoring every candidate
# direction under a single cost function, in a single unit (expected HP).
#
# This replaces the potential-field controller's summed force terms. The two
# differ in kind, not degree:
#
#   A summed field asks "which way do all the pressures push me?" Opposing
#   pressures cancel, so a ring of enemies produces a near-zero vector and the
#   field goes blind exactly when it matters most. Every escape subsystem in
#   the old controller exists to detect a case where the sum lied.
#
#   An arbiter asks "of the moves available, which ends best?" Nothing cancels:
#   being surrounded means every candidate scores badly and the least-bad one
#   still wins. Threading two crossing bullet lanes needs no special case,
#   because a candidate that leaves lane A and enters lane B pays for lane B.
#
# Cost is expected HP lost over a short horizon, plus opportunity terms
# converted into HP. Because every term shares that unit, the weights are
# interpretable and tunable by search rather than by hand-balancing strengths.

# -- Horizon --
const HORIZON = 0.8              # s of lookahead; beyond this we re-decide anyway
const TIME_DISCOUNT = 0.45       # a threat landing at t=H is this much cheaper than
                                 # one landing now: later hits get more chances to be
                                 # dodged by a future frame's decision
const MIN_DISCOUNT = 0.15        # ...but never free. A fixed discount applied past the
                                 # horizon would go negative and turn a distant threat
                                 # into a REWARD, so it floors here instead.

# -- Slow-threat lookahead --
#
# A fixed time horizon buys wildly different warning DISTANCES depending on how
# fast the threat moves: 0.8 s is 480 px against a 600 px/s bullet and only
# 160 px against a 200 px/s environmental one. So the slowest projectiles get
# the least reaction distance -- and they hit hardest (measured 7.0 damage per
# hit against 3.6 for regular enemy fire).
#
# The consequence is measurable and specific: environmental bullets land while
# the bot is fleeing IN THEIR DIRECTION 45% of the time, against 17% for fast
# fire. A 470 px/s potato is being run down by a 200 px/s bullet, because a
# bullet 300 px behind arrives at t=1.5 s, sits outside the horizon, and
# therefore costs exactly zero -- so nothing stops the bot walking into where
# it will be hit.
#
# Fix: stretch the scan window for slow movers until it covers a fixed DISTANCE
# rather than a fixed time. This is the same thing the old field controller's
# F6 "slow-shot distance floor" bought, rebuilt as geometry instead of a
# special case.
const SCAN_DISTANCE = 420.0      # px of warning every projectile should get
const SCAN_MAX = 2.4             # s ceiling; past this our own straight-line path
                                 # assumption is worthless anyway

# -- Action space --
# 24 headings at 15 deg, then two bisection rounds around the winner: each
# round tests half a step either side, so the effective resolution is 15/4 =
# 3.75 deg for four extra evaluations rather than the 96 a flat sweep needs.
const DIRS = 24
const REFINE_ROUNDS = 2

# -- Collision --
const HIT_MARGIN = 1.6           # dmin beyond (radii * this) scores zero; between
                                 # hard contact and this the cost tapers smoothly, so
                                 # "barely clear" and "comfortably clear" differ
const BODY_RADIUS_FALLBACK = Contract.BODY_RADIUS_FALLBACK
# How many times a threat lands over the horizon is no longer a constant here:
# world_view computes it per threat (T_TICKS), because a body you cannot outrun
# keeps hitting for every horizon you stay attached while a bullet hits once.

# -- Lethality --
# Absolute HP is the wrong price for a hit. Losing 5 HP is a scratch at 78 max
# and nearly half your life at 12, but a flat cost of 5 sits on the same scale
# as the shaping terms below -- so on a fragile build the scorer will happily
# trade a hit for better positioning. That is what killed it on w2-fisherman
# (0/5, dying at t=8-19s on a 12 HP build) while the field controller went 4/5.
const LETHALITY = 4.0            # cost multiplier at the point where one hit would kill

# -- Weights (HP units; tunable by search) --
const W_PROJ = 1.0               # projectile damage is already HP; this is the anchor
const W_CONTACT = 1.0
const W_DASH = 1.4               # a dash that connects also staggers; worse than its damage
const W_AOE = 1.2
const W_LATENT = 0.5             # an idle charger that COULD launch inside the horizon
const W_ROOM = 6.0               # crowding cost at the horizon's end
const W_WALL = 16.0              # wall proximity, counted per axis so corners cost double.
                                 # Raised from 8: at 8 the term peaked at 4 per axis
                                 # while threats cost 15-65 after lethality scaling, so
                                 # the bot accepted being pinned rather than cross one
const WALL_POWER = 2.0           # superlinear ramp: concentrate the cost in the last
                                 # stretch instead of pushing toward the centre always
const WALL_ENCLOSE_ARC = 0.8     # how strongly a near wall counts as blocked headings
const W_ENCLOSE = 5.0            # threats spread around us rather than massed on one side
const W_DPS = 14.0               # reward for holding killable, dangerous things in weapon range
const W_PICKUP = 1.0             # reward for closing on gold / food / loot
const W_HYST = 1.2               # reward for agreeing with last frame's choice
const W_REVERSE = 2.0            # extra cost for a full reversal

# -- Terminal-state shaping --
const ROOM_CAP = 260.0           # crowding beyond this distance is not crowding
# -- Crowd runway --
# The room term above looks 0.8 s ahead. On the tracker Pacifist w9 bed the
# bot holds the annulus for ~20 s and is then walked from mid-arena to the
# wall in a few seconds by 100 chasers: every 0.8 s step is locally right and
# the sum of them is a corner (PHIST: anc 600 -> 1200, edge 12, then the hit
# chain). The wall runway prices the WALL 2.4 s out; nothing priced the crowd
# that far. This is the crowd's runway: the same crowding measure taken at
# FAR_T along the bearing, threats extrapolated the same way, so a heading
# that stays open beats one the pack will close. Moving candidates only:
# standing is priced by the threat terms already. --arb-roomfar sweeps it.
const FAR_T = 2.0
const W_ROOM_FAR = 3.0
const ROOM_FAR_CAP = 320.0
const WALL_CAP = 220.0           # wall room beyond this is irrelevant
const ENCLOSE_RADIUS = 340.0     # threats inside this ring shape the enclosure term
const ENCLOSE_MIN = 3            # fewer than this cannot meaningfully surround us
const PICKUP_FALLOFF = 320.0     # loot this far away barely steers us
const PICKUP_TAKEN = 1.0         # x value: bonus for a move that ENDS inside the
                                 # attract radius of a drop it started outside --
                                 # the pass-through pickup a kiting lap is made of.
                                 # --arb-taken sweeps it; 0 is the exact control.

# -- Engagement --
# Killing something is worth the damage it would otherwise have done to us, so
# targets are weighted by threat-value (computed in world_view), not counted.
# A flat count saturated: on a busy wave every direction had five-plus enemies
# in range, so the term went constant across the whole compass and stopped
# discriminating exactly when the fight was thickest.
const KILL_SOFT = 40.0           # soft-saturation scale; value beyond this has
                                 # diminishing but never zero marginal return, so
                                 # the term keeps discriminating on dense waves
const ACQUIRE_BAND = 220.0       # targets this far OUTSIDE weapon range still pull,
                                 # which is the only thing making the bot close in

# -- Character anchor --
# Some characters have a point on the map worth fighting near -- the Builder's
# turret is the first (world_view decides WHO anchors and WHERE; the scorer
# only prices distance). A LEASH, not a magnet: zero cost anywhere inside the
# radius so dodging stays free, linear pull beyond it so the pull GROWS the
# further the bot strays, capped so a spawn across the arena cannot flatten
# the compass. Linear matters: the differential between a candidate walking
# home and one walking away is constant (~w_anchor * 670/ANCHOR_NORM ~ 27)
# wherever the bot is below the cap, which is enough to win every tie and
# lose every argument with a live corridor.
const W_ANCHOR = 12.0            # sweep via --arb-anchor; 0 is the exact control arm
const ANCHOR_NORM = 300.0        # px beyond the leash that cost one w_anchor
const ANCHOR_CAP = 8.0           # ~2400 px out the ramp stops growing; differentials
                                 # between candidates survive until then
# The same term read from the other side is a KEEP-OUT ring: cost for being
# CLOSER than an inner radius. That one shape covers three behaviours the
# research asked for -- a leash (inner 0), a perimeter orbit (inner large,
# anchored on the arena middle, so the cheapest floor is the rim and the bot
# laps it rather than parking against one wall), and Mage's stay-away-from-your
# own-turret spacing -- without the scorer knowing which is which.

# -- Contact seeking --
# The inverse of kiting, for characters whose damage or healing is paid in hits
# TAKEN or in one swing landing across a crowd. Deliberately NOT a threat-weight
# change: dropping the threat terms would make the bot ignore corridors and
# dashes too, which kills these characters just as dead as it kills the others.
# Instead it is a separate pull toward the nearest thing worth touching, so a
# live dash still outscores it and the bot walks into BODIES, not into bullets.
const ENGAGE_NORM = 260.0        # distance to the nearest target that costs one
                                 # engage unit; ~a body length past contact
const ENGAGE_CAP = 2.2           # beyond ~570 px the pull stops growing, so a
                                 # far-off straggler cannot drag the bot across
                                 # the arena through everything in between
# Cluster engage (Bull): the explosion is 150 px around the potato and fires
# once per hit taken, so the value of a dive is not "how close is the nearest
# body" but "how many bodies will be inside the blast when the hit lands".
# The candidate's END position is scored by that count. The nearest-target
# pull stays on at reduced weight so the bot still closes on a lone straggler
# when no pile exists yet -- otherwise nothing would ever start one.
const ENGAGE_BLAST = 170.0       # explosion max_range 150 + ~body radius
const ENGAGE_CLUSTER_CAP = 8.0   # bodies in the blast at which the reward saturates
const ENGAGE_CLUSTER_NEAR = 0.4  # share of the nearest-target pull kept in cluster mode
# The cluster reward is PER BODY, not normalised: every body inside the blast
# at the end position dies to the first hit, so a six-body dive is worth six
# kills, not "one saturated dive". Normalised to a 14-point maximum it lost
# every vote to crowding + enclosure + the detonating hit + the bodies just
# outside the blast, and the live w4 log showed the Bull hovering at full HP
# while the crowd grew to 92. Crowding and enclosure at the end position are
# also discounted while the dive is armed: for a Bull, ending inside the
# crowd is the payoff, not the failure the terms were written to price.
const EXPLODE_CROWD = 0.35       # share of room + enclosure cost kept while diving

const NEVER_STILL_COST = 6.0     # Speedy loses 100 armour while stationary and
                                 # Hiker's income IS distance covered: standing
                                 # is a mechanical penalty, so price it as one
const FIRE_STILL_STAND = 2.0     # fire_still: standing collects the kit's +50%
                                 # dmg / +50% AS as a doubled kill payout
const FIRE_STILL_MOVE = 0.4      # ...moving keeps only the approach gradient;
                                 # weapons that fire while standing earn nothing
                                 # on the run, and the scorer must know it
const FIRE_STILL_FLOOR = 16.0    # minimum stand-and-shoot reward with a target
                                 # in true weapon range. 8 beat the room term's
                                 # wander pressure but measured 3 kills a wave:
                                 # at low HP the lethality multiplier prices a
                                 # 2-damage baby alien's approach at ~10, and a
                                 # swarm of them re-evicted the stand every
                                 # frame. 16 holds ground against light trash
                                 # pressure and still folds to anything whose
                                 # damage is actually worth fleeing
# A standing Soldier does not passively receive an approaching body -- it
# SHOOTS it, at +50% damage and +50% attack speed, and trash dies on the way
# in. Pricing that approach at full contact damage is why the bot fled from
# things that would never have arrived: threat pricing assumes the enemy
# lives to touch, which stops being true the moment standing is what kills
# it. So the STANDING candidate's contact coefficients are discounted by the
# body's killability (same KILL_HP_REF falloff the target values use): a
# 6 HP baby alien costs ~40% of book price to stand against, a 300 HP elite
# costs face value -- which reproduces the guide's play exactly: hold ground
# and mow trash, still respect elites, still dodge every bullet (projectile
# and dash coefficients are untouched). Moving candidates always pay full
# price: fleeing does not shoot anything.
# -- The damage trade --
# Field report: once enemies get CLOSE, the bot starts running and never fights
# again. The arithmetic of that spiral: a close crowd prices the stand as the
# sum of every body's contact cost, fleeing prices near zero, so flight wins
# every frame -- but flight fires no shots, the crowd never thins, and the gap
# never closes. A human Soldier breaks the spiral by TRADING: a few hit points
# are the fee for the volley that deletes the crowd. So the standing
# candidate's contact costs from KILLABLE bodies are pooled and capped at a
# budget scaled by current HP: "this much of my bar buys uninterrupted fire."
# The pool only admits genuinely killable bodies (TRADE_KILLABLE_MIN) --
# elites, bullets, dashes and telegraphs stay full price outside the pool, so
# the trade never talks the bot into standing through what actually kills it.
# The budget also shrinks with the bar: a wounded Soldier stops trading.
const TRADE_HP_SHARE = 0.5       # budget in cost points = current HP x this
const TRADE_KILLABLE_MIN = 0.15  # only bodies at least this killable join the pool.
                                 # killability = ref/(ref+hp), so 0.15 admits anything
                                 # that dies inside ~6 s of standing fire. It was 0.35
                                 # (~2 s), which on w17-d6 excluded EVERYTHING: pursuers
                                 # at 394 HP against a 186 kill_ref sat at 0.32, the pool
                                 # stayed empty, every body billed the stand at full
                                 # price, and the bot fled for 15-22 s killing 5-17.
                                 # At 0.15 the same wave ran 54-60 s at 170-270 kills
                                 # and the sustain build healed to full while standing.
                                 # Sweep via --arb-tradekill.

# -- Where a stand is allowed --
# The w12 cornering deaths were not a camping pattern: the per-second edge
# series shows the bot HERDED from open floor to the wall over 20-30 s, then
# dead within two. Every stand perk made holding ground cheap, so the bot kept
# making its stand a little closer to the wall each time the crowd pushed,
# until there was nowhere left. A reactive escape fires too late for that.
# So the perks are gated on wall room: inside FIRE_STILL_WALL_MIN the Soldier
# is priced like any other potato, the wall term walks it back out to open
# floor, and only THERE does it stand again. Escape at the loss of firing,
# but triggered by geometry before the pin instead of by a timer after it.
const FIRE_STILL_WALL_MIN = 220.0
# The perks also drop when a threat closes to melee range: a fragile stand-and-
# shoot kit (Soldier, 10 HP) that holds its stand into the swarm at the open-
# center spawn dies wave 0. Below this distance the stand permission is revoked so
# the arbiter dodges; above it the kit stands, fires, and collects its +50% perks.
const FIRE_STILL_DANGER = 130.0
# -- Hop candidates --
# The croc's second form drops a 10-pillar ring 250 px around the bot that
# arms 0.54 s later; every full-speed candidate covers ~280 px over the
# horizon, so all of them END on or past the ring while it is armed, and the
# only in-ring option was standing still under the dash. A hop is the move a
# human makes there: a short lateral step inside the ring. It is scored at
# HOP_FRAC speed (executed by the movement behaviour as the tap duty cycle,
# 2 frames on / 2 off) on HOP_DIRS headings, and only offered while a ground
# telegraph or a dash is within HOP_RANGE -- it costs HOP_DIRS extra
# evaluations, which the quiet frames must not pay. --arb-hop=0 disables.
const HOP_FRAC = 0.5             # MUST match the tap duty cycle (TAP_MOVE / (TAP_MOVE + TAP_STOP))
const HOP_DIRS = 8
const HOP_RANGE = 420.0
const STUTTER_SPEED_FRAC = 0.5   # net travel speed of the tap cycle; MUST match
                                 # TAP_MOVE / (TAP_MOVE + TAP_STOP) in
                                 # player_movement_behavior.gd (2 / (2 + 2))

const FIRE_STILL_KILL = 0.9      # discount share at killability 1.0. 0.75 measured
                                 # 9-39% still-frames on w6-d5: trash there runs
                                 # 15-30 HP, killability ~0.4, so the discount only
                                 # shaved a third while room+enclosure kept paying
                                 # the bot to drift off its stand
const FIRE_STILL_CROWD = 0.5     # standing's share of the room and enclosure costs.
                                 # Both terms grade the END position, so every flee
                                 # candidate beats the stand on crowding by
                                 # construction -- a permanent eviction pressure.
                                 # But crowding measures how bad this spot is for a
                                 # potato that must ESCAPE it, and a firing Soldier
                                 # is thinning the crowd instead; half price, not
                                 # zero, because bullets do not stop a surround
                                 # from closing

# -- Predictive wall avoidance --
# The wall term prices proximity at the 0.8 s horizon -- ~336 px of
# lookahead -- but the herding that ends in a corner death runs 2-5 s while
# the bot is still mid-arena at full HP (mom analysis: 87% of her hits at
# edge < 150, median 1 s from first touch to death; +16 max HP falsified
# the hit-budget theory, so the corner is an ABSORBING state and the only
# lever is not entering it). This term prices each bearing's RUNWAY: how
# long it can be held before the arena ends it. Walls slide, so a bearing
# is dead only when EVERY moving axis has exhausted its room -- straight at
# a wall stops on contact, a diagonal dies at the corner, parallel to a
# wall runs forever. Per-candidate discriminating geometry, which is what
# the four failed wall-weight attempts were not.
const W_PREDICT = 0.0            # OFF until validated; sweep via --arb-predict
const PREDICT_SECS = 2.5         # bearings that dead-end sooner than this are costed

# -- Pin escape --
# Four attempts to solve pinning by WEIGHT failed: wall28 flat, peril regressed
# five snapshots, trap null on w7 (t=0.49 vs noise 1.65) and null on w11. They
# shared one defect -- each made a pin expensive INSIDE the same sum, so the way
# out still had to outvote every threat term, and in a corner every exit points
# through something. This is a MODE instead: once the bot is confirmed stuck it
# stops optimising the blend, discounts damage on purpose, and commits to
# leaving for a fixed spell.
const PIN_EDGE = 150.0           # closer than this to a wall to count as pinned
const PIN_CLEAR = 260.0          # far enough out to call the escape finished
const PIN_WINDOW = 24            # frames of position history (~0.4 s)
const PIN_TRAVEL_FRAC = 0.35     # stuck if net travel is under this share of what
                                 # our speed could have covered over the window
const PIN_CONFIRM = 8            # consecutive stuck frames before the mode fires
const PIN_DWELL = 40             # fire_still only: frames spent inside PIN_EDGE, moving
                                 # or not, before the mode fires (~1.25 s). The stuck
                                 # test above never arms on a tap-mover -- stutter
                                 # steps read as ordinary travel -- so on w12 the
                                 # Soldier died at edge 36 with pesc=0 twice. A
                                 # stand-and-shoot kit has no business holding a
                                 # wall for more than a second: the swarm closes
                                 # the exits while it fires, and that is the corner
                                 # Any other pin-enabled row arms the same trigger
                                 # with its own "pin_dwell" (frames): a perimeter
                                 # kit sliding along the wall under bullet hell is
                                 # never "stuck" -- lateral travel reads as travel --
                                 # so without a dwell the escape never fires (w7/w8
                                 # Pacifist deaths at edge 12-36 with pesc=0).
const PIN_TICKS = 36             # frames of COMMITTED escape (~0.6 s). Commitment is
                                 # the point: a pin is a local minimum, so leaving
                                 # MUST look worse for several frames. Re-deciding
                                 # every frame is what leaves the bot dithering.
const PIN_THREAT = 0.25          # damage discount while escaping -- the "through some
                                 # damage" knob. 0 ignores threats entirely, 1 is
                                 # normal caution and so is an exact no-op control.
const PIN_WALL_BOOST = 2.5       # pull much harder toward open floor while escaping
const W_TANGENT = 30.0           # while ESCAPING: reward motion ALONG the nearest
                                 # wall. The radial exit is where the herding swarm
                                 # stands; the lateral one is usually open, and no
                                 # other term knows the difference. Only active
                                 # during pin escape, so inert while pin is off.
                                 # Sweep via --arb-tangent.
const TANGENT_RADIUS = 200.0     # wall proximity ramp for the tangent reward

# -- v2.3.0: standoff ring (kite) --
# Field report: ranged characters walk in and fight at contact. The cause is
# structural, not a weight: the kill reward is FLAT inside weapon range (reach
# = 1.0), so ending 50 px from a bruiser scores exactly like ending 380 px
# away, and nothing rewards holding the edge of the range. The old field
# controller's KITE_HP_FACTOR / KITE_REPEL_MULT constants went away with it.
# This is its replacement, as one more term in the same HP unit: price the
# END position's distance to the nearest target, zero at the ring and growing
# as the candidate ends closer. Costs only -- the kill/acquire terms already
# pull INTO range, so the pair forms a well at the ring instead of a repulsion
# field. --arb-kite=0 is the exact control arm (the term is skipped whole).
# The ring is a share of weapon range (profile kite_frac, 0 for melee), and it
# WIDENS as the bar drops (--arb-kitehp, the old KITE_HP_FACTOR semantics:
# keep more distance when a hit matters more).
const W_KITE = 10.0              # standoff cost weight, in HP units
const KITE_HP_GROWTH = 0.4       # ring grows by +40% at zero HP (x hp deficit)

# -- v2.3.0: 2-ply receding-horizon planner --
# choose() used to be single-step greedy: ~29 candidates scored by one 0.8 s
# analytic prediction, argmin. Every frame is locally right and the sum can be
# wrong -- walking into a state that is expensive AT THE NEXT DECISION POINT
# (a pocket the pack is about to close, a dash lane entered from the wrong
# side). The fix is one extra ply on the same cost function, no new model:
# take the K best first headings, advance the threats by one decision interval,
# re-score a coarse second move set from where that heading ends, and add the
# discounted best continuation to the first move's score. The second ply is a
# TIE-BREAKER for our first move, not an enemy forecast (threats are
# extrapolated at constant velocity, targets/rewards held static).
# --arb-plan=0 is the exact greedy control.
const PLAN_BEAM = 4              # first moves given a second ply (--arb-beam)
const PLAN_DIRS = 8              # second-ply move set: 8 headings + stand
const PLAN_GAMMA = 0.6           # second-ply discount (--arb-gamma)
const PLAN_MAX_THREATS = 90      # skip planning above this threat count; the
                                 # second ply is K x (DIRS+1) extra evaluations,
                                 # and a 90+ threat frame is already the expensive
                                 # one -- the frame-rate guard, not a tuning knob
const PLAN_DEDUPE_BINS = 1.05    # angular de-duplication for the beam: headings
                                 # within ~one sweep bin of an already-picked one
                                 # are the same first move twice, so the beam stays
                                 # angularly spread instead of clustering

# -- v2.5.0: pre-emptive breakout (escape a closing ring BEFORE it closes) --
# Field report: "you can see with the naked eye that it is about to be
# surrounded, but the bot does not plan ahead." The 2-ply planner did not fix
# it, and the arithmetic says why: from the middle of a ring every heading
# ends near a body at the 0.8 s horizon, so the first-ply score is nearly flat
# and the second ply is only a discounted tie-breaker. The escape a human
# takes requires RUNNING AT a body on purpose (taking the soft contact price
# now) to be outside the ring 1-2 s later. That is not a weight: it is a
# different objective (future freedom, not current clearance), and the
# codebase's own history says such states need a MODE.
#
# Trigger: the LARGEST ANGULAR GAP the ring leaves now is passable, but
# projected ahead (pursuers walk toward us, bodies widen as the ring shrinks)
# that gap will be gone. Then commit to the heading whose pursuit rollout
# keeps the most clearance over BREAKOUT_ROLLOUT_T and stop pricing contact
# bodies at face value for the duration -- bullets, dashes and telegraphs
# stay full price, so this is "run through the crowd", not "tank".
# --arb-breakout=0 is the exact 2.4.0 control arm (mode never arms).
const BREAKOUT_ENABLE = 1.0      # --arb-breakout
const BREAKOUT_RING = 620.0      # px: contact bodies inside this ring can cage us
const BREAKOUT_FORECAST = 1.8    # s: closure forecast horizon (one long ply)
const BREAKOUT_MIN_GAP = 0.15    # rad: the largest gap must be at least this wide NOW
const BREAKOUT_FUT_GAP = 0.02    # rad: ...and projected to be gone at FORECAST
const BREAKOUT_MIN_CONTACT = 6   # fewer pursuers cannot close a ring around us
const BREAKOUT_MAX_TICKS = 180   # hard cap on one escape (~3 s at 60 Hz)
const BREAKOUT_CLEAR = 260.0     # px: nearest body at which the escape is DONE
                                 # (leaving the mode at 50 px just re-centres the bot
                                 # in the pack -- the local cost's equilibrium)
const BREAKOUT_TICKS = 90        # per-commitment frames before a re-plan (unused cap
                                 # kept for compatibility)
const BREAKOUT_RECHECK = 15      # frames between escape-heading re-plans
const BREAKOUT_COOLDOWN = 45     # frames after a breakout before it can re-arm
const BREAKOUT_CONTACT = 0.35    # contact/dash weight share while breaking out
const BREAKOUT_ROOM = 0.5        # room weight share: the crowd is the point now
const BREAKOUT_PULL = 60.0       # HP-units reward for heading with the escape line
const BREAKOUT_DIRS = 16         # rollout headings
const BREAKOUT_ROLLOUT_T = 1.6   # s of pursuit rollout per heading
const BREAKOUT_ROLLOUT_HZ = 30   # rollout integration rate
const BREAKOUT_PASS = -28.0      # px: worst clearance below this = no passable line
                                 # (~one body radius): a breakout MAY buy the
                                 # escape with a hit -- that is what the mode is for
const BREAKOUT_BODY = 18.0       # px: player body radius used by the rollout

# -- v2.5.0: committed item goal (plan a detour, don't just drift) --
# Rewards currently enter _cost as a per-step gradient with a 320 px falloff,
# capped by the item's own value (6-9 HP for a DLC evolution item). A single
# contact body costs 10-40, so any item 1+ seconds away is invisible: the bot
# only ever collects loot it happens to pass. This is the committed-goal
# layer: when the neighbourhood is calm, pick the best reward by
# value/(1+ETA/GOAL_FALLOFF), then pay a pull for closing the distance
# EVERY frame until it is collected, the item disappears, danger closes in,
# or the commit expires. Value 0 disables; --arb-goal=0 is the control arm.
# The pull is deliberately a separate term, not a higher pickup weight: the
# normal reward gradient must stay comparable across candidates, and an item
# that walks us into a live lane must still lose to the threat terms.
const GOAL_ENABLE = 1.0          # --arb-goal
const W_GOAL = 9.0               # --arb-goalw: pull weight in HP units at value 9
const GOAL_MIN_VALUE = 4.0       # don't plan detours for cheaper pickups
const GOAL_RANGE = 1000.0        # px: never plan for an item beyond this
const GOAL_FALLOFF = 420.0       # px: ETA denominator in the acquisition utility
const GOAL_SAFE_R = 320.0        # px: acquire only when no threat is nearer
const GOAL_ABORT_R = 170.0       # px: drop the goal when something gets this near
const GOAL_DONE_R = 12.0         # px: counted as arrived (pickup AREA reach ~42;
                                 # releasing at the 45 rim left the bot parked
                                 # just outside the real pickup circle)
const GOAL_COMMIT = 60           # frames a goal survives before re-acquisition
const GOAL_COOLDOWN = 30         # frames after a drop before re-acquiring

# -- v2.5.0: walk-on reward semantics --
# v2.4 passed evolution consumables as [pos, value, false, EVO_WALK_RIM] and
# the cost code's `held = r.size() > 3 and r[R_RIM] > 0` read that as a HELD
# reward (revive-zone semantics: paid every frame inside the rim). The bot
# then parks on the rim and never consumes the item -- offline closed-loop
# sim showed exactly that. A walk-on item is a ONE-SHOT pickup: pay the
# gradient and the taken bonus, then the reward disappears when the game
# removes the consumable. world_view marks these with r[R_WALKON] = 1.0;
# --arb-walk=0 ignores the marker and restores the 2.4.0 held reading.
const WALK_ENABLE = 1.0          # --arb-walk

# -- v2.5.0: pursuit-aware second ply --
# _advance_threats used constant velocity, but contact bodies STEER at the
# potato: a ring projected in a straight line keeps its gaps open while the
# real ring turns and closes them. For the second ply, contact/dash threats
# are advanced toward the first-ply end position instead (pursuit), capped at
# touching distance. --arb-pursuit=0 is the exact constant-velocity control.
const PURSUIT_ENABLE = 1.0       # --arb-pursuit

# -- v2.6.0: wall / corner squeeze escape --
# Player report after 2.5.0: "it still gets driven into the map edge and loses
# room to operate." The ring-forecast breakout above only arms when the bodies
# form a CLOSING RING; one-sided pressure can push the bot into the wall band
# one locally-correct step at a time with no ring to forecast (the exact
# herding pattern documented in the W_PREDICT block). The 0.8 s wall term only
# reacts when the player is nearly pinned, and pin escape is after the fact.
# Same committed escape, different trigger: inside BREAKOUT_EDGE of a wall,
# with a crowd on us and NOT already escaping, run the pursuit rollout toward
# open floor. It reuses the --arb-breakout switch; =0 keeps the 2.5.0 mode set.
const BREAKOUT_EDGE = 150.0      # px from the nearest wall that counts as the band
const BREAKOUT_EDGE_CLEAR = 380.0 # px: enough floor to end a corner escape
const BREAKOUT_CROWD_R = 430.0   # px: bodies inside this ring + near a wall = squeeze
const BREAKOUT_CROWD_MIN = 4     # bodies needed to call it a squeeze (ring needs 6)
# v2.6.0: weak "open floor" potential. The wall term above is quadratic and
# only reaches WALL_CAP=220 px, so from mid-arena there is NO gradient against
# drifting into the edge -- many locally-fine steps later the bot is in the
# band with no runway (the reported "driven into the map edge"). This adds a
# tie-breaker-sized pull toward open floor out to SPACE_CAP: at 380 px from a
# wall it is 0, and inside the band it is a few HP points, enough to break the
# wander/commit ties without outvoting a live threat or a kill. --arb-space=0
# is the exact 2.5.0 control arm.
const W_SPACE = 2.5
const SPACE_CAP = 380.0
# A corner retreat is NOT a cage breakout: the floor is still open behind us, so
# it may not buy the exit with contact damage the way the ring mode does. It
# keeps most of the threat price and a weaker pull, letting the normal terms
# veto a retreat through the crowd (soldier/melee herd regressions in the sim).
const BREAKOUT_CORNER_CONTACT = 1.0   # no contact discount: this is a retreat
const BREAKOUT_CORNER_ROOM = 1.0
const BREAKOUT_CORNER_PULL = 18.0
const BREAKOUT_CORNER_TICKS = 90      # 1.5 s: enough to walk out of the band
const BREAKOUT_CORNER_COOLDOWN = 120  # do not ping-pong back to the wall

# -- v2.6.0: bounty approach (special monsters / spawners) --
# Field report: "it still does not like going after special monsters or their
# drops." DLC cursed/evolved bodies, spawner eggs and bosses carry a target
# value but targets are only visible to the DPS term once they are near weapon
# range (+ ACQUIRE_BAND); a special sitting 1-2 screens away simply never
# enters the score. The bounty layer is a committed approach toward a special
# target while the neighbourhood is calm: pull until it is inside firing
# range, abort when a body closes in, hp is low or the target vanishes.
# --arb-bounty=0 is the exact 2.5.0 control arm (no target tag, no pull).
const BOUNTY_ENABLE = 1.0        # --arb-bounty
const BOUNTY_PULL = 14.0         # HP-units per unit of alignment with the target
const BOUNTY_RANGE = 900.0       # px: never plan an approach beyond this
const BOUNTY_BODY_SAFE = 300.0   # px: acquire only when no body is nearer
const BOUNTY_BODY_ABORT = 180.0  # px: drop the approach when something gets this near
const BOUNTY_MIN_HP = 0.35       # don't go hunting below this hp ratio
const BOUNTY_DESIRE = 0.9        # desired range as a share of weapon range
const BOUNTY_TICKS = 45          # frames an approach survives before re-acquisition
const BOUNTY_HOLD = 60.0         # px: target moved this far -> re-acquire

# -- v2.6.1: crowding projection must TRACK a pursuer, not overshoot it ----
# Field report after 2.6.0: "sometimes in relatively simple situations the
# character collides with monsters". Sparse-1v1 closed-loop reproduction: a
# chaser damages us every 0.7 s while the bot orbits it, in the shipped build
# AND in the 2.4/2.6 control arms -- a base cost-model bug, not a v2.5/2.6
# regression. The threat term saturates once the body is inside its (inflated)
# contact radius, so nothing in it rewards increasing the gap; the heading was
# decided by the CROWDING terms instead. Those projected the body with its
# FROZEN current velocity: a chaser closer than speed*HORIZON is projected
# THROUGH and PAST the player, so running away *raised* the computed crowding
# (the chaser is projected to be right where we are heading) while orbiting /
# charging through *lowered* it -- the arbiter then sat in a stable orbit on
# top of the body and took contact hits every 0.7 s.
# The fix: for a CONTACT body SLOWER THAN US whose frozen projection would pass
# us this horizon, project it as a pursuer that FOLLOWS and stops at touching
# distance -- exactly the cap the second ply's pursuit forecast already uses
# (see _advance_threats). Running away then ends farther from where the pursuer
# can be, and the crowding gradient points away from the body instead of into
# it. The slower-than-us scope is deliberate: the point is that flight CAN open
# the gap (that is the reported failure), while against a faster body nothing
# escapes and the frozen projection is not the reported failure -- those keep
# the tuned 2.6.0 behaviour (a slow-character crowd regression was measured
# when the cap was applied to un-outrunnable bodies too).
# Only the room / roomfar terms read these two projections; every other reader
# (blast counting, enclosure, the second ply) keeps the old ones. The cap only
# engages when gap < speed*span (~200-250 px), which is the pathological case;
# distant bodies are projected exactly as before.
# --arb-roomtrack=0 restores the 2.6.0 frozen projection exactly (control arm).
const ROOM_TRACK = 1.0           # --arb-roomtrack

# -- v2.7.0: unified opportunity planner (--arb-opp) ----------------------
# User report after v2.6.0: "special things still don't feel aggressive
# enough". Offline probes showed the v2.6 bounty layer was fenced off by four
# independent walls, and the fix is not a weight:
#   (A) world_view only emitted targets inside target_reach (typical 620-680
#       px), so --arb-bounty's 900 px range could never be used; fixed
#       world_view-side (OPP_SPECIAL_RANGES) for SPECIAL bodies only;
#   (B) a binary safety gate (BOUNTY_BODY_SAFE=300, GOAL_SAFE_R=320, abort
#       <180/170) switched the layer OFF whenever anything was near -- i.e.
#       through most of a real wave, exactly when a detour is a decision;
#   (C) the pull was small next to a body's contact price and decayed with
#       distance, so a far item/elite could never win an "awkward step";
#   (D) special targets reused _kill_value (damage x killability), which for a
#       thick boss/elite can be LOWER than a trash mob's -- the layer would not
#       pick the very thing it was built for.
# v2.7 replaces (B)(C)(D) with one risk-adjusted planner: an explicit value
# table for special classes, route damage estimated from the SAME threat
# model, and a commitment pull scaled by value. (A) stays in world_view.
# --arb-agg is the risk dial: 0 = conservative (old safe-gate strict side),
# 1 = default (may cross 1-2 ordinary bodies for a worthwhile target),
# 2 = aggressive. --arb-opp=0 restores the exact v2.6.1 behaviour: legacy
# _update_goal/_update_bounty, unscaled pulls, no target close-in candidate.
const OPP_TARGET_MAX = 1700.0     # px: defensive cap (world_view gathers <= 1600)
const OPP_TICKS = 100             # frames a commitment survives before re-acquisition
const OPP_COOLDOWN = 15           # frames after a release before re-acquiring
const OPP_ABORT_HP_FRAC = 0.7     # commitment drops below hp_floor * this
const OPP_MARGIN = 1.0            # min (value - risk - travel cost) to commit, HP units
const OPP_ETA_COST = 0.5          # HP-equivalent per second of travel in the score
const OPP_RISK_CAP = 200.0        # sanity cap on the route-risk estimate
const OPP_RISK_BASE = 0.10        # allowed risk = value*(base + per_agg*agg) + flat*agg
const OPP_RISK_PER_AGG = 0.20
const OPP_RISK_FLAT = 2.0
const OPP_HP_FLOORS = [0.55, 0.35, 0.20]   # by agg round+clamp 0..2
const OPP_PULL_BASE = 10.0        # target pull = clamp(base + per_value*value, min, max)
const OPP_PULL_PER_VALUE = 0.6
const OPP_PULL_MIN = 14.0
const OPP_PULL_MAX = 34.0
const OPP_GOAL_SCALE_MAX = 2.0    # reward pull multiplier cap: clamp(value/9, 1, max)
const OPP_HOLD = 90.0             # px: a stored special target may move this far
const OPP_RISK_TAPER = 60.0       # px beyond the hit radius where route risk fades out

# -- v2.10.0: contract-body-aware objective pull guard (--arb-pullsafe) -----
# Round-7 play-test: "sometimes in relatively simple situations the character
# walks into a monster". Root cause is structural and older than the economy
# layer: the contact price SATURATES inside the (Hurtbox-inflated) body radius
# (_taper returns 1.0 for every heading whose closest approach is inside it, and
# a body already next to us is inside it on EVERY heading), so once a body is
# that close the threat term cannot tell "run away" from "walk through" -- and
# every objective-seeking pull (committed goal pull, bounty pull, per-step
# reward attraction) is then free to decide the heading, straight through the
# body. v2.6.1 kept that from happening by accident: its committed-goal layer
# refused to acquire while a body was within GOAL_SAFE_R (320 px) and aborted
# inside GOAL_ABORT_R (170 px); v2.7 replaced those binary gates with a
# straight-line risk budget, and v2.8/v2.9 raised the reward values and the pull
# magnitude (up to 28.8 HP), so a committed resource behind a monster is now
# walked through. The guard restores the missing safety property continuously:
# while ANY contact/dash body is inside its own taper band, objective pulls are
# damped to zero and the contact/crowding terms decide the heading alone.
# Hysteresis (release only once the body is clear of the band) prevents the
# pull from flickering on/off at the boundary. --arb-pullsafe=0 is the exact
# v2.9.1 control arm.
const PULL_SAFE_ENABLE = 1.0
const PULL_SAFE_ENTER = 1.0      # gap / taper-width; < 1 = body inside taper band
const PULL_SAFE_RELEASE = 1.6    # ...and hysteresis: clear of the band by 60%

# -- v2.8.0: high-value coverage (--arb-cov) ------------------------------
# v2.7 coverage had two holes the player's "should cover ALL high-value
# targets" report points at:
#   (1) the monster table lumped Boss and Elite into one class/value, and
#   (2) produces (item crates, evolution items, loot aliens, trees) still
#       entered the unified planner at their old incidental prices (5/10/6-9/
#       3), which are small next to a body's 10-40 contact price -- so the
#       "valuable thing" the player wanted chased was still usually vetoed.
# v2.8 gives every high-value class an explicit opportunity value (below) and
# lets world_view tag identifiable reward classes; `--arb-cov=0` restores the
# exact v2.7.0 tables/usages. Values are HP-equivalent (same unit as threats):
# they answer "what is this objective worth in contact damage budget", before
# the route-risk gate.
const OPP_VALUE_BOSS = 50.0       # class 1 (Boss, is_elite=false)
const OPP_VALUE_ELITE = 30.0      # class 4 (Elite, is_elite=true; DLC elites too)
const OPP_VALUE_EGG = 40.0        # class 2 (spawner egg)
const OPP_VALUE_DLC = 18.0        # class 3 (cursed / evolved body)
const OPP_VALUE_V27_CLASS1 = 30.0 # cov=0: exact v2.7.0 (Boss+Elite share class 1)
const OPP_VALUE_CRATE = 20.0      # reward tag 1: one item choice
const OPP_VALUE_CRATE_LEGENDARY = 34.0  # reward tag 2: one legendary item choice
const OPP_VALUE_EVO = 20.0        # reward tag 3: DLC evolution progression item
const OPP_VALUE_LOOT = 12.0       # reward tag 4: fleeing loot alien
const OPP_VALUE_TREE = 7.0        # reward tag 5: living tree (consumable+material)
const OPP_TAG_CRATE = Contract.OPP_TAG_CRATE          # world_view reward[R_TAG] tags
const OPP_TAG_LEGENDARY = Contract.OPP_TAG_LEGENDARY
const OPP_TAG_EVO = Contract.OPP_TAG_EVO
const OPP_TAG_LOOT = Contract.OPP_TAG_LOOT
const OPP_TAG_TREE = Contract.OPP_TAG_TREE

# -- v2.3.0: hit-adaptive alert --
# A build that just took a big hit should behave more cautiously for a moment.
# Online, cheap, and trivially switchable: compare hp_ratio with the previous
# decision, and when a single decision loses ADAPT_DROP of the bar start an
# alert that multiplies the THREAT weights by (1 + adaptgain) for adaptsecs.
# Deliberately only the threat weights (same set caution scales): room/wall
# must not change, or the character turns into a centre-hugger on damage.
# Composes with caution and pin discount through the SAME saved array, so a
# restore cannot miss it. --arb-adapt=0 is the control arm.
const ADAPT_DROP = 0.12          # hp_ratio lost in one decision that fires the alert
const ADAPT_GAIN = 0.25          # threat-weight boost while alerted (--arb-adaptgain)
const ADAPT_SECS = 2.0           # alert duration in seconds (--arb-adaptsecs)
const ADAPT_MIN_TICKS = 30       # ...but at least this many decisions, so a fast
                                 # decision interval cannot blink the alert away

# -- Threat kinds --
# Tuple layout / vocabulary: single source of truth is steering/contract.gd
# (Step-1 refactor; the values used to be duplicated here and in world_view.gd).
# Local aliases keep the hot loops on compile-time constants.
const KIND_PROJ = Contract.KIND_PROJ
const KIND_CONTACT = Contract.KIND_CONTACT
const KIND_DASH = Contract.KIND_DASH      # a charge, in flight or still winding up
const KIND_AOE = Contract.KIND_AOE        # stationary ground telegraph
const KIND_MARK = Contract.KIND_MARK      # spawn-marker keep-out: priced on CONTACT only

# -- Threat tuple layout (as built by world_view; see steering/contract.gd) --
const T_POS = Contract.T_POS
const T_VEL = Contract.T_VEL
const T_RADIUS = Contract.T_RADIUS
const T_DAMAGE = Contract.T_DAMAGE
const T_KIND = Contract.T_KIND
const T_START = Contract.T_START      # seconds until this threat starts moving
const T_TICKS = Contract.T_TICKS      # expected damage applications over the horizon
const T_END = Contract.T_END          # seconds until this threat stops being dangerous
const T_KILL = Contract.T_KILL        # OPTIONAL 9th field: killability (contact only)

# -- Target tuple layout (see steering/contract.gd) --
const TG_POS = Contract.TG_POS
const TG_VALUE = Contract.TG_VALUE    # expected HP this enemy costs us if left alive
const TG_BOSS = Contract.TG_BOSS      # OPTIONAL: true for bosses/elites
const TG_SPECIAL = Contract.TG_SPECIAL  # OPTIONAL: special class (SPECIAL_*)

# -- Charger tuple layout (see steering/contract.gd) --
const C_POS = Contract.C_POS
const C_RANGE = Contract.C_RANGE      # launch range: outside it the dash cannot trigger
const C_DAMAGE = Contract.C_DAMAGE
const C_READY = Contract.C_READY      # seconds until its cooldown expires

# -- Reward tuple layout (see steering/contract.gd) --
const R_POS = Contract.R_POS
const R_VALUE = Contract.R_VALUE
const R_ATTRACTED = Contract.R_ATTRACTED
const R_RIM = Contract.R_RIM
const R_WALKON = Contract.R_WALKON
const R_VEL = Contract.R_VEL
const R_TAG = Contract.R_TAG

# -- Special-target class (target[TG_SPECIAL]) --
const SPECIAL_BOSS = Contract.SPECIAL_BOSS
const SPECIAL_EGG = Contract.SPECIAL_EGG
const SPECIAL_DLC = Contract.SPECIAL_DLC
const SPECIAL_ELITE = Contract.SPECIAL_ELITE

# Tunable weights, seeded from the constants above. They are instance vars
# rather than consts so a benchmark can sweep them from the command line
# (--arb-dps=9 etc.) without a code edit between runs, which is what both
# ablation and any search-based tuning need.
var w_proj = W_PROJ
var w_contact = W_CONTACT
var w_dash = W_DASH
var w_aoe = W_AOE
var w_latent = W_LATENT
var w_room = W_ROOM
var w_wall = W_WALL
var w_enclose = W_ENCLOSE
var w_dps = W_DPS
var w_pickup = W_PICKUP
var pickup_taken = PICKUP_TAKEN  # --arb-taken
var hop_enable = 1.0             # --arb-hop
var stand_mult = 1.0             # --arb-stand: multiplier on the row's standing income (0 = off)
# A break costs more than the partial second: the NEXT full second has to be
# stood from zero too, so leaving a stand throws away progress + one whole
# tick. stand x3 on the tracker w10 bed changed nothing (156-184 materials
# either way) because the breaks are one-frame flickers priced at a fraction
# of a tick; this is what makes them dear. --arb-standcommit sweeps it.
const STAND_COMMIT = 1.0
var stand_commit = STAND_COMMIT  # --arb-standcommit
var _stand_income = 0.0          # profile stand_income: points per second a stand earns
var _stand_progress = 0.0        # profile stand_progress: share of the current tick done
var last_stand = 0.0             # telemetry mirror of _stand_income
var last_hop = false             # the chosen candidate is a half-speed hop (telemetry + execution)
var _hop_wanted = false          # set by _prepare: a telegraph or dash is close enough
var last_aoe_n = 0               # KIND_AOE threats priced this decision (telemetry)
var _pickup_radius = 0.0         # profile pickup_radius: the attract area's rim
var w_hyst = W_HYST
var lethality = LETHALITY
var lethality_override = -1.0    # --arb-lethality wins over the row's lethality key
var horizon = HORIZON
# Separated from w_room on purpose: the weight sets how hard crowding is
# punished, this sets how far out it is felt at all. A bot that keeps a 136 px
# standoff where the field controller keeps 231 needs the reach changed, not
# the strength -- at ROOM_CAP the term is already flat, so no weight can push
# the standoff past it.
var room_cap = ROOM_CAP
var w_room_far = W_ROOM_FAR      # --arb-roomfar
# Sweepable: --arb-scandist=0 collapses the clamp to the horizon for every
# threat, reproducing the old fixed-window behaviour exactly, so it is a free
# exact control arm rather than an approximation of one.
var scan_distance = SCAN_DISTANCE

# v2.3.0 switches (see the constant blocks above). Defaults are the new
# behaviour; every one has an exact control arm: w_kite=0, plan_depth=0,
# adapt_enable=0. They are instance vars so --arb-* can sweep them.
var w_kite = W_KITE              # --arb-kite
var kite_hp_growth = KITE_HP_GROWTH  # --arb-kitehp
var plan_depth = 1               # --arb-plan: 0 greedy / 1 two-ply
var plan_beam = PLAN_BEAM        # --arb-beam
var plan_gamma = PLAN_GAMMA      # --arb-gamma
var plan_max_threats = PLAN_MAX_THREATS  # --arb-planthreats
var adapt_enable = 1.0           # --arb-adapt
var adapt_gain = ADAPT_GAIN      # --arb-adaptgain
var adapt_secs = ADAPT_SECS      # --arb-adaptsecs

# v2.5.0 switches (see the v2.5 constant blocks above). Defaults are the new
# behaviour; every one has an exact 2.4.0 control arm (=0).
var breakout_enable = BREAKOUT_ENABLE   # --arb-breakout
var bounty_enable = BOUNTY_ENABLE       # --arb-bounty
var room_track = ROOM_TRACK             # --arb-roomtrack
var w_space = W_SPACE                   # --arb-space: open-floor potential
var goal_enable = GOAL_ENABLE           # --arb-goal
var w_goal = W_GOAL                     # --arb-goalw
var walk_enable = WALK_ENABLE           # --arb-walk: honor r[R_WALKON] walk-on marker
var pursuit_enable = PURSUIT_ENABLE     # --arb-pursuit: steering second ply
# v2.5.0 per-decision state (breakout + item goal). Read by _cost.
var _breakout_active = false
var _breakout_dir = Vector2.ZERO
var _breakout_engaged = false
var _breakout_ticks = 0
var _breakout_cooldown = 0
var _breakout_recheck = 0
var _breakout_free_now = 1.0
var _breakout_free_fut = 1.0
var _breakout_reason = ""
var _breakout_edge = 1e9
var _bounty_on = false
var _bounty_pos = Vector2.ZERO
var _bounty_ticks = 0
var _bounty_desired = 0.0
var _goal_on = false
var _goal_pos = Vector2.ZERO
var _goal_value = 0.0
var _goal_frac = 0.0
var _goal_ticks = 0
var _goal_cooldown = 0
# telemetry mirrors for the movement behaviour / BOTLOG
var last_breakout = false
var last_breakout_engaged = false
var last_breakout_free_now = 1.0
var last_breakout_free_fut = 1.0
var last_breakout_evals = 0
var last_breakout_reason = ""
var last_bounty = false
var last_bounty_dist = -1.0
var last_goal = false
var last_goal_dist = -1.0
var last_goal_value = 0.0

# v2.7.0 opportunity planner switches + commitment state (see the OPP_ block).
# opp=0 leaves every legacy path untouched: _opp_on drives only the two new
# pull guards and the new close-in candidate, and _update_opportunity is never
# called (the legacy goal/bounty update path runs instead).
var opp_enable = Config.OPP_ENABLE_DEFAULT
var opp_agg = 1.0
var cov_enable = Config.COV_ENABLE_DEFAULT  # --arb-cov: v2.8 high-value coverage table
var _opp_on = false
var _opp_kind = ""               # "target" | "reward"
var _opp_value = 0.0
var _opp_risk = 0.0
var _opp_ticks = 0
var _opp_cooldown = 0
var _opp_desired = 0.0
var _opp_pull = BOUNTY_PULL
var _opp_goal_scale = 1.0
var _opp_src = Vector2.ZERO      # raw (current) position of the committed reward
# numeric telemetry for gate/selftest probes
var last_opp = false
# v2.9 economy: telemetry for the planner commitment consumed this decision
var last_econ_kind = ""
var last_econ_score = 0.0
var last_opp_kind = ""
var last_opp_value = 0.0
var last_opp_risk = 0.0
# v2.10.0 objective-pull guard: 0.0 when a body is inside its taper band and
# objective pulls are damped, 1.0 otherwise (probe/regression-test telemetry).
var pull_safe = PULL_SAFE_ENABLE
var last_pull_scale = 1.0
var _pull_scale = 1.0
var _pull_suppressed = false
var _cfg = null                 # persistent Config for the compatibility apply_overrides()
# -- v2.9 economy objective layer: the economy module / world_view own the
# pricing; the arbiter only consumes the committed candidate (Phase B hook) and
# must fall back to the v2.8 path for reward tuples without econ flags.
var econ = 0.0                  # --arb-econ: shipped default 1 via Config.parse;
                                # bare instances stay on the v2.8 legacy path.
var _econ_state = {}            # per-decision planner commitment (profile["econ"])

var pin_enable = 0.0             # --arb-pin=1 turns the escape mode on; default OFF
var pin_threat = PIN_THREAT      # --arb-pinthreat
var w_predict = W_PREDICT        # --arb-predict
var predict_secs = PREDICT_SECS  # --arb-predsecs
var w_tangent = W_TANGENT        # --arb-tangent
var wall_swerve = 1.0            # --arb-swerve=0 reverts the dodge sim to raw v
var w_anchor = W_ANCHOR          # --arb-anchor
var fire_still_danger = FIRE_STILL_DANGER  # --arb-firedanger: break the fire_still stand when a threat is this close (0 = never)
var trade_share = TRADE_HP_SHARE # --arb-trade: the damage-trade budget as a share of HP
var fire_floor = FIRE_STILL_FLOOR # --arb-floor: the stand-and-shoot floor
var trade_killable_min = TRADE_KILLABLE_MIN # --arb-tradekill: pool admission threshold
var engage_mult = 1.0            # --arb-engage: multiplier on the profile's engage weight
var never_still_scan = 1.0       # --arb-neverstill=0 ignores rows' still:"never" (control arm)
var aimed_full = 1.0             # --arb-aimedfull=0 restores the time discount for the
                                 # standing candidate (the pre-2026-08-25 pricing) as an
                                 # exact control arm
var cluster_near = ENGAGE_CLUSTER_NEAR # --arb-cnear: nearest-body pull share in cluster mode
var _escaping = false            # set by choose() each frame; read by _cost
# Per-frame character-profile state, resolved by world_view and unpacked once
# in choose() rather than dictionary-looked-up inside the 16+ candidate loop.
var _anchor_on = false
var _anchor = Vector2.ZERO
var _anchor_radius = 0.0
var _anchor_inner = 0.0
var _anchor_w = W_ANCHOR         # w_anchor x the row's anchor_w multiplier
# Orbit: a perimeter kit is herded from mid-arena into a corner in seconds
# (tracker Pacifist w7/w8: anc 790 -> 1150, edge 30, then contact hits) and
# the anchor term cannot stop it -- it prices END positions, so between two
# candidates it differs by ~13, the cost of one bullet. This term prices the
# DIRECTION at the current position once the bot is outside the outer radius:
# the outward radial component costs, the inward one pays, and the tangential
# component (kiting around the middle, which is how the character is played)
# earns half credit, all ramped by how far out we are. Row key "orbit" sets
# the weight; --arb-orbit=W overrides it for every row (0 = off, the control).
var _orbit_w = 0.0
var orbit_override = -1.0        # --arb-orbit
var _orbit_from = 0.0            # radius the orbit ramp starts at (row "orbit_from";
                                 # default the outer anchor_radius)
var orbit_from_override = -1.0   # --arb-orbitfrom
var cluster_override = -1         # --arb-cluster: -1 unset, 0 force off, 1 force on
var last_anchor_dist = -1.0      # distance to the anchor this frame, for telemetry
var _engage = 0.0
var _never_still = false
var _fire_still = false
var _engage_cluster = false      # engage prices bodies-in-blast instead of nearest distance
# The explosion trade (Bull). Bull is priced like every other potato: each
# body in the pile is a separate contact hit, so three bodies in the blast
# cost ~48 to stand against while the dive reward tops out at 14, and the
# dive never happens. But Bull's FIRST hit detonates a 150 px explosion that
# kills everything killable in the blast -- the second and third hits from
# those bodies never arrive. So while the dive is armed (engage > 0, i.e.
# the HP band allows it) the contact costs of killable bodies that will be
# inside the blast at the END position pool and cap at ONE hit: the largest
# single coefficient among them, because that is the one that lands before
# the explosion resolves. Bodies outside the blast, unkillable ones, bullets
# and dashes all pay full price, so the dive is still vetoed by anything the
# explosion would not answer.
var _explode_trade = false
# -- The damage dive --
# The explosion trade only relieves KILLABLE bodies; anything that survives the
# blast (a 250 HP pursuer against a 156 blast) pays full contact price and a
# pile of them vetoes the dive outright. But a blast that does not kill still
# DEALS 156 to every body in it, and a Bull with a full bar can afford the
# exchange. So while the dive is armed, surviving bodies inside the blast pool
# too, and their cost is capped at DAMAGE_DIVE_HITS hits -- the one that
# detonates and the follow-up before the bot steps out -- provided (a) the bar
# is above DAMAGE_DIVE_HP, so two hits are survivable with margin, and (b) the
# blast's total damage across everything in it reaches DAMAGE_DIVE_MIN, so the
# exchange is worth having. Fail either and they pay full price as before.
# Bullets, dashes and elites are never in either pool.
var _damage_dive = false         # profile key damage_dive
var _hp_ratio = 1.0              # profile key hp_ratio (world_view computes it)
# v2.3.0 per-frame state. _kite_r is the standoff ring in px, resolved once in
# choose() from profile kite_frac x weapon_range; _prev_hp_ratio is the last
# decision's bar reading and _adapt_ticks the decisions of alert left to run.
var _kite_frac = 0.0             # profile key kite_frac (0 for melee/weaponless)
var _kite_r = 0.0                # standoff ring: 0 => kite term inert
var _prev_hp_ratio = -1.0        # -1 sentinel: the first decision has no "drop"
var _adapt_ticks = 0             # decisions of hit-adaptive alert still running
var _blast = 0.0                 # profile key blast: damage the explosion deals per body
const DAMAGE_DIVE_HP = 0.5       # bar needed to trade hits with bodies that live
const DAMAGE_DIVE_MIN = 350.0    # blast x bodies-in-blast that makes the trade worth it
const DAMAGE_DIVE_HITS = 2.0     # hits the surviving pile may bill: detonate + one more

const EXPLODE_KILLABLE_MIN = 0.5 # explode_trade admission: killability >= 0.5 means
                                 # hp <= kill_ref, i.e. the body DIES to one blast. The
                                 # general pool's 0.15 ("dies within ~6 s of fire") is
                                 # wrong here -- a body that survives the explosion keeps
                                 # hitting, and pricing it at "one hit" is what let 250 HP
                                 # pursuers bill the w11 horde dive as cheap
var _fight_room = 0.0            # px of wall room a candidate must END with to earn any
                                 # engage or kill reward. The One-Armed w10 timelines: at
                                 # full HP the brawler CHASED rim spawns into the wall band
                                 # (engage 8 + dps 14 outbid the wall term's ~13), sat there
                                 # unhurt for seconds, then took 33 -> 3 in eight. Rewards
                                 # that pull toward a wall are what cornered it; costs
                                 # stay untouched, so it still leaves
var _stand_ok = false            # fire_still AND not escaping AND wall room; gates every perk
var last_stand_ok = false        # read by the tap-mover: no taps while relocating off a wall
var last_engage = 0.0            # resolved contact-seeking weight this frame, for telemetry

var last_dir = Vector2.ZERO      # read for hysteresis and by telemetry
var last_still_gap = 0.0         # cost(stand) - cost(best); overlay only now
var last_stutter_gap = 0.0       # cost(best at stutter speed) - cost(best); the tap gate
var last_plan_used = false       # v2.3.0: the 2-ply planner produced the first action
var last_plan_evals = 0          # v2.3.0: _cost evaluations the planner spent this frame
var last_kite_cost = 0.0         # v2.3.0: standoff cost paid by the chosen candidate
var last_adapt = false           # v2.3.0: hit-adaptive alert active this frame
var last_scores = []             # per-candidate cost, for the debug overlay
var last_dirs = []               # candidate directions matching last_scores
var last_best_index = -1
var last_escaping = false        # did the escape mode fire this frame (telemetry)
var pin_fires = 0                # escape activations this run, for the sweep
var _pin_hist = []               # recent positions, newest last
var _pin_frames = 0              # consecutive confirmed-stuck frames
var _pin_dwell = 0               # consecutive frames inside PIN_EDGE (dwell trigger)
var _pin_dwell_limit = 0         # frames of wall dwell that fire the escape; 0 = off
var tick_step = 1                # physics ticks this choose() call stands for (the
                                 # movement behaviour's decision interval); every pin
                                 # counter advances by it so the frame constants keep
                                 # meaning frames when decisions are skipped
var pin_dwell_override = 0       # --arb-pindwell: force the dwell limit for any pin row
var pin_leak = 0.0               # --arb-pinleak: wall-dwell decay when off the wall. Default
                                 # 0 = hard reset (dwell needs continuous wall time). Leaky
                                 # (1) lets a bot dodging in/out of the wall band accumulate
                                 # net dwell -- intuitive for bullet-hell corner deaths, but
                                 # A/B measured a WASH (Pacifist w8 6/6, w9 6/8, Soldier w12
                                 # 6/4, w4 7/?): kept as a knob only, not the default.
var _pin_ticks = 0               # frames of escape left to run

# Per-frame prepared threat data. Everything here is candidate-independent, so
# it is computed once instead of once per candidate -- with 29 candidates that
# is the difference between affording the wider action space and not.
var _p_pos = []                  # threat position
var _p_vel = []                  # threat velocity
var _p_rad = []                  # combined hit radius (threat + player body)
var _p_soft = []                 # squared radius past which a miss scores zero
var _p_coef = []                 # full damage coefficient: damage x kind x lethality x mitigation
var _p_still = []                # the same coefficient for the STANDING candidate;
                                 # differs only under fire_still, where standing
                                 # kills killable contact threats on their approach
var _p_kill = []                 # killability per threat (0 for non-contact); feeds
                                 # the damage-trade pool
var _p_mark = []                 # true for KIND_MARK: skipped by crowding/enclosure
var _p_aimed = []                # true for KIND_PROJ / KIND_DASH: a thing that flies at
                                 # us. The time discount below assumes a later frame
                                 # can still dodge it -- false for the STANDING
                                 # candidate, so it gets none (see the loop)
var _p_start = []                # wind-up delay
var _p_end = []                  # when it stops being dangerous, clamped to horizon
var _p_future = []               # where it will be at the horizon
var _p_room = []                 # v2.6.1: crowding projection (room term)
var _p_room_far = []             # v2.6.1: crowding projection (roomfar term)
var _p_far = []                  # where it will be at FAR_T (crowd runway)


# Apply command-line weight overrides, e.g. {"dps": 9.0, "enclose": 0.0}.
# Unknown keys are ignored so a sweep script can pass a superset.
func apply_config(cfg, verbose = false) -> void:
	# Step-1: every value comes from the single Config parser (steering/config.gd).
	_cfg = cfg
	w_proj = cfg.w_proj
	w_contact = cfg.w_contact
	w_dash = cfg.w_dash
	w_aoe = cfg.w_aoe
	w_latent = cfg.w_latent
	w_room = cfg.w_room
	w_wall = cfg.w_wall
	w_enclose = cfg.w_enclose
	w_dps = cfg.w_dps
	w_pickup = cfg.w_pickup
	pickup_taken = cfg.pickup_taken
	fire_still_danger = cfg.fire_still_danger
	hop_enable = cfg.hop_enable
	stand_mult = cfg.stand_mult
	stand_commit = cfg.stand_commit
	w_hyst = cfg.w_hyst
	lethality_override = cfg.lethality_override
	horizon = cfg.horizon
	room_cap = cfg.room_cap
	w_room_far = cfg.w_room_far
	scan_distance = cfg.scan_distance
	pin_enable = cfg.pin_enable
	pin_dwell_override = cfg.pin_dwell_override
	pin_leak = cfg.pin_leak
	orbit_override = cfg.orbit_override
	orbit_from_override = cfg.orbit_from_override
	pin_threat = cfg.pin_threat
	w_predict = cfg.w_predict
	predict_secs = cfg.predict_secs
	w_tangent = cfg.w_tangent
	wall_swerve = cfg.wall_swerve
	w_anchor = cfg.w_anchor
	trade_share = cfg.trade_share
	fire_floor = cfg.fire_floor
	trade_killable_min = cfg.trade_killable_min
	engage_mult = cfg.engage_mult
	aimed_full = cfg.aimed_full
	never_still_scan = cfg.never_still_scan
	cluster_near = cfg.cluster_near
	cluster_override = cfg.cluster_override
	w_kite = cfg.w_kite
	kite_hp_growth = cfg.kite_hp_growth
	plan_depth = cfg.plan_depth
	plan_beam = cfg.plan_beam
	plan_gamma = cfg.plan_gamma
	plan_max_threats = cfg.plan_max_threats
	adapt_enable = cfg.adapt_enable
	adapt_gain = cfg.adapt_gain
	adapt_secs = cfg.adapt_secs
	breakout_enable = cfg.breakout_enable
	bounty_enable = cfg.bounty_enable
	room_track = cfg.room_track
	w_space = cfg.w_space
	goal_enable = cfg.goal_enable
	w_goal = cfg.w_goal
	walk_enable = cfg.walk_enable
	pursuit_enable = cfg.pursuit_enable
	opp_enable = cfg.opp_enable
	opp_agg = cfg.opp_agg
	cov_enable = cfg.cov_enable
	pull_safe = cfg.pull_safe
	econ = cfg.econ
	if verbose:
		_print_overrides()


# Debug-only: the exact weight/switch dump the old in-module parser printed
# once per non-empty apply_overrides() call (same text and order).
func _print_overrides() -> void:
	print("ARBITER weights: proj=%.2f contact=%.2f dash=%.2f aoe=%.2f latent=%.2f room=%.2f roomcap=%.0f wall=%.2f enclose=%.2f dps=%.2f pickup=%.2f hyst=%.2f lethality=%.2f horizon=%.2f pin=%.2f pinthreat=%.2f predict=%.2f predsecs=%.2f tangent=%.2f swerve=%.2f anchor=%.2f" % [
	w_proj, w_contact, w_dash, w_aoe, w_latent, w_room, room_cap, w_wall,
	w_enclose, w_dps, w_pickup, w_hyst, lethality, horizon, pin_enable, pin_threat,
	w_predict, predict_secs, w_tangent, wall_swerve, w_anchor])
	print("ARBITER v2.3.0: kite=%.2f kitehp=%.2f plan=%d beam=%d gamma=%.2f planthreats=%d adapt=%.2f adaptgain=%.2f adaptsecs=%.2f" % [
	w_kite, kite_hp_growth, plan_depth, plan_beam, plan_gamma,
	plan_max_threats, adapt_enable, adapt_gain, adapt_secs])
	print("ARBITER v2.5.0: breakout=%.2f goal=%.2f goalw=%.2f walk=%.2f pursuit=%.2f" % [
	breakout_enable, goal_enable, w_goal, walk_enable, pursuit_enable])
	print("ARBITER v2.6.0: bounty=%.2f space=%.2f" % [bounty_enable, w_space])
	print("ARBITER v2.6.1: roomtrack=%.2f" % [room_track])
	print("ARBITER v2.7.0: opp=%.2f agg=%.2f" % [opp_enable, opp_agg])
	print("ARBITER v2.8.0: cov=%.2f" % [cov_enable])
	print("ARBITER v2.10.0: pullsafe=%.2f" % [pull_safe])


# Compatibility wrapper for the offline harnesses (planner-selftest, gate, sim,
# probes and the field-equivalence test call apply_overrides on a bare
# instance). It routes through the SAME single Config parser -- there is no
# second key table -- and copies only the fields the dict actually touched,
# preserving the old accumulate-without-reset semantics the harnesses rely on.
func apply_overrides(d: Dictionary) -> void:
	if _cfg == null:
		_cfg = Config.new()
	_cfg.override(d)
	for f in _cfg.last_fields.keys():
		if f in self:
			set(f, _cfg.get(f))
	# explicit econ switch: Config's last_fields only tracks CHANGES, and the
	# bare-instance default is the legacy path (see world_view.apply_overrides).
	if d.has("econ"):
		econ = float(d["econ"])
	if not d.empty():
		_print_overrides()



# True when at least one reward tuple carries the v2.9 econ-flags field. This is
# the compatibility gate: v2.8-shaped synthetic inputs (470 selftest / 32 gate)
# never do, so they keep the exact legacy path even with the econ switch on.
func _rewards_have_econ_flags(rewards: Array) -> bool:
	for r in rewards:
		if r is Array and r.size() > Contract.R_ECON_FLAGS:
			return true
	return false


# Returns the chosen unit direction, or ZERO to stand still.
#   threats:    array of threat tuples (see layout above)
#   rewards:    array of [pos, value_hp] pickup targets
#   targets:    array of enemy positions worth shooting
#   chargers:   array of idle-charger tuples (latent dash risk)
#   mitigation: expected share of incoming damage that actually lands (dodge, armor)
func choose(p0: Vector2, speed: float, body_radius: float, far: Vector2,
		threats: Array, rewards: Array, targets: Array, chargers: Array,
		weapon_range: float, prefers_still: bool, current_hp: float,
		mitigation: float, profile: Dictionary = {}) -> Vector2:

	var edge = min(min(p0.x, far.x - p0.x), min(p0.y, far.y - p0.y))
	var escaping = false
	_fire_still = profile.get("fire_still", false)    # read by _update_pin's dwell trigger
	# Pin escape arms globally via --arb-pin, or per character via the profile:
	# a stand-and-shoot kit gets cornered by its own best behaviour (the stand
	# holds while the crowd closes the exits), so for those characters the
	# escape mode is part of the profile, not an experiment flag.
	if pin_enable != 0.0 or profile.get("pin", false):
		_pin_dwell_limit = int(profile.get("pin_dwell", PIN_DWELL if _fire_still else 0))
		if pin_dwell_override > 0:
			_pin_dwell_limit = pin_dwell_override
		escaping = _update_pin(p0, speed, edge)
	last_escaping = escaping
	_escaping = escaping         # read by _cost for the tangent reward
	# One flag for every stand perk: fire_still, not escaping, and enough wall
	# room that the stand cannot become the corner (see FIRE_STILL_WALL_MIN).
	_stand_ok = _fire_still and not escaping and edge >= FIRE_STILL_WALL_MIN
	# Break the stand and dodge when a threat is at melee range (see FIRE_STILL_
	# DANGER): stand-fire when safe, run when swarmed. Keeps the +50% perks in the
	# gaps without the fragile kit tanking the open-center opening to death.
	if _stand_ok and fire_still_danger > 0.0:
		var danger_sq = fire_still_danger * fire_still_danger
		for t in threats:
			if p0.distance_squared_to(t[T_POS]) < danger_sq:
				_stand_ok = false
				break
	last_stand_ok = _stand_ok

	_anchor_on = profile.has("anchor") and w_anchor > 0.0
	_anchor = profile.get("anchor", Vector2.ZERO)
	_anchor_radius = float(profile.get("anchor_radius", 0.0))
	_anchor_inner = float(profile.get("anchor_inner", 0.0))
	_anchor_w = w_anchor * float(profile.get("anchor_w", 1.0))
	_pickup_radius = float(profile.get("pickup_radius", 0.0))
	lethality = float(profile.get("lethality", LETHALITY))
	if lethality_override >= 0.0:
		lethality = lethality_override
	_stand_income = float(profile.get("stand_income", 0.0)) * stand_mult
	_stand_progress = float(profile.get("stand_progress", 0.0))
	last_stand = _stand_income
	_orbit_w = float(profile.get("orbit", 0.0))
	if orbit_override >= 0.0:
		_orbit_w = orbit_override
	_orbit_from = float(profile.get("orbit_from", _anchor_radius))
	if orbit_from_override >= 0.0:
		_orbit_from = orbit_from_override
	last_anchor_dist = p0.distance_to(_anchor) if _anchor_on else -1.0
	_engage = float(profile.get("engage", 0.0)) * engage_mult
	last_engage = _engage        # public mirror for telemetry (get() on _engage returns null)
	_engage_cluster = profile.get("engage_cluster", false)
	if cluster_override >= 0:
		_engage_cluster = cluster_override == 1
	_fight_room = float(profile.get("fight_room", 0.0))
	_explode_trade = profile.get("explode_trade", false)
	_damage_dive = profile.get("damage_dive", false)
	_hp_ratio = float(profile.get("hp_ratio", 1.0))
	_blast = float(profile.get("blast", 0.0))
	_never_still = profile.get("never_still", false) and never_still_scan != 0.0
	_fire_still = profile.get("fire_still", false)

	# -- v2.3.0: standoff ring (see the W_KITE block) --
	# world_view writes kite_frac every frame: a share of weapon range when the
	# build carries a ranged weapon, 0.0 otherwise. The ring widens as the bar
	# drops (kitehp), and w_kite=0 leaves _kite_r = 0 so _cost skips the term
	# entirely -- the exact control arm.
	_kite_frac = float(profile.get("kite_frac", 0.0))
	_kite_r = 0.0
	if w_kite > 0.0 and _kite_frac > 0.0 and weapon_range > 0.0:
		_kite_r = _kite_frac * weapon_range * (1.0 + kite_hp_growth * (1.0 - _hp_ratio))

	# -- v2.3.0: hit-adaptive alert (see the ADAPT_* block) --
	# Compare this decision's bar with the last one. -1 is the first-decision
	# sentinel: a wounded character entering a wave must not read its missing
	# health as a fresh hit. The countdown is in DECISIONS: the initial length
	# converts seconds through tick_step (adapt_secs*60/tick_step), and then
	# every choose() call burns exactly ONE decision, whichever multiple of
	# physics ticks that decision stands for. Decrementing by tick_step here
	# instead would shrink the alert to 1/tick_step of its nominal length once
	# --arb-every=0/-N skips ticks (2 s became ~1.0 s at tick_step 2, ~0.67 s
	# at 3). The floor keeps a fast decision cadence from blinking it away.
	if _prev_hp_ratio < 0.0:
		_prev_hp_ratio = _hp_ratio
	last_adapt = false
	if adapt_enable != 0.0:
		if _adapt_ticks > 0:
			_adapt_ticks -= 1
		if _prev_hp_ratio - _hp_ratio >= ADAPT_DROP:
			_adapt_ticks = max(int(round(adapt_secs * 60.0 / float(max(tick_step, 1)))), ADAPT_MIN_TICKS)
		last_adapt = _adapt_ticks > 0
	_prev_hp_ratio = _hp_ratio

	# -- v2.5.0: pre-emptive breakout + committed item goal (see the blocks) --
	# Both are MODES resolved once per decision from the raw threat/reward set,
	# BEFORE the weights are baked into _p_coef down in _prepare(). Their cost
	# terms are read back in _cost. --arb-breakout=0 / --arb-goal=0 leave the
	# state false and the terms skipped, which is the exact 2.4.0 control arm.
	_breakout_active = false
	if breakout_enable != 0.0:
		_breakout_active = _update_breakout(p0, speed, far, threats)
	last_breakout = _breakout_active
	last_breakout_engaged = _breakout_engaged
	last_breakout_reason = _breakout_reason
	last_breakout_free_now = _breakout_free_now
	last_breakout_free_fut = _breakout_free_fut
	# -- v2.9 economy layer: consume world_view's planner commitment ---------
	# Compatibility rule (task-7): the economy path needs BOTH the econ switch and
	# the new reward flags. Synthetic test inputs from v2.8 (old tuples, no
	# profile["econ"]) therefore keep the exact legacy path, flags or not.
	var econ_state = {}
	var econ_flags_present = false
	if econ != 0.0 and profile is Dictionary and profile.has("econ"):
		econ_flags_present = _rewards_have_econ_flags(rewards)
		if econ_flags_present:
			econ_state = profile["econ"]
	_goal_on = false
	_bounty_on = false
	_opp_on = false
	last_opp = false
	last_opp_kind = ""
	last_opp_value = 0.0
	last_opp_risk = 0.0
	last_econ_kind = ""
	last_econ_score = 0.0
	if opp_enable != 0.0:
		# v2.7.0: ONE unified opportunity layer replaces the two separate
		# committed layers. It still drives the same _goal_on/_bounty_on state
		# (so every existing cost/close-in/telemetry reader keeps working) but
		# chooses between special targets and high-value rewards on a
		# value-minus-route-risk score instead of two binary safe windows.
		if not escaping and not _breakout_active:
			if not econ_state.empty() and bool(econ_state.get("on", false)):
				# v2.9: the planner already priced value, deadline and route
				# risk; feed its commitment through the legacy goal channel so
				# _cost's pull/close-in candidate apply unchanged.
				_goal_on = true
				_goal_pos = econ_state["pos"]
				_goal_value = float(econ_state["value"])
				_goal_frac = clamp(_goal_value / 9.0, 0.5, 1.6)
				_opp_on = true
				_opp_kind = "reward"
				_opp_value = _goal_value
				_opp_risk = float(econ_state.get("risk", 0.0))
				_opp_goal_scale = clamp(_goal_value / 9.0, 1.0, OPP_GOAL_SCALE_MAX)
				last_econ_kind = str(econ_state.get("kind", ""))
				last_econ_score = float(econ_state.get("score", 0.0))
			elif econ_flags_present:
				# econ=1 with correctly-priced rewards: do NOT let the v2.8
				# opportunity layer re-price flagged resources through the cov
				# tables (AUTO_AT_HORN must not become a mid-wave detour).
				# Special targets keep the legacy bounty path unchanged.
				if bounty_enable != 0.0:
					_bounty_on = _update_bounty(p0, targets, threats, weapon_range)
					if _bounty_on:
						_opp_kind = "target"
				_opp_on = _bounty_on
			else:
				_opp_on = _update_opportunity(p0, speed, body_radius, mitigation,
						threats, rewards, targets, weapon_range)
		_opp_on = _opp_on and (_goal_on or _bounty_on)
		last_opp = _opp_on
		last_opp_kind = _opp_kind if _opp_on else ""
		last_opp_value = _opp_value if _opp_on else 0.0
		last_opp_risk = _opp_risk if _opp_on else 0.0
	else:
		# exact v2.6.1 legacy path (--arb-opp=0 control arm)
		if goal_enable != 0.0 and not escaping and not _breakout_active:
			_goal_on = _update_goal(p0, threats, rewards)
		# v2.6.0: bounty approach -- one objective at a time, item goal first.
		if bounty_enable != 0.0 and not escaping and not _breakout_active and not _goal_on:
			_bounty_on = _update_bounty(p0, targets, threats, weapon_range)
	last_goal = _goal_on
	last_goal_dist = p0.distance_to(_goal_pos) if _goal_on else -1.0
	last_goal_value = _goal_value if _goal_on else 0.0
	last_bounty = _bounty_on
	last_bounty_dist = p0.distance_to(_bounty_pos) if _bounty_on else -1.0

	# Scaled BEFORE _prepare, deliberately: the per-kind weight is baked into
	# _p_coef in there (see the kw assignment), so discounting these afterwards
	# would compile cleanly, change nothing, and hand back a convincing null.
	#
	# Caution and pin escape both live here and COMPOSE. Caution is a standing
	# character trait -- how much room this potato needs -- while the pin
	# discount is a momentary "accept damage to get out of this corner". One
	# save covers both, so a restore cannot miss a weight the other touched.
	# Note caution multiplies only the THREAT weights: scaling room/wall too
	# would turn a cautious character into a centre-hugging one, which is a
	# different (and mostly wrong) behaviour.
	var caution = float(profile.get("caution", 1.0))
	var dps_scale = float(profile.get("dps", 1.0))
	var adapt_scale = 1.0
	if _adapt_ticks > 0:
		adapt_scale = 1.0 + adapt_gain
	var scaled = escaping or _breakout_active or caution != 1.0 or dps_scale != 1.0 or adapt_scale != 1.0
	var saved = []
	if scaled:
		saved = [w_proj, w_contact, w_dash, w_aoe, w_latent, w_dps, w_room, w_wall]
	if _breakout_active:
		# Run THROUGH the bodies, not around them: the crowd is what the mode
		# is escaping, so its contact price is what the commitment buys down.
		# Projectiles, dashes and telegraphs keep full price -- breaking out
		# must never mean tanking a bullet lane. A CORNER retreat is different:
		# open floor exists behind the crowd, so it keeps most of the price.
		if _breakout_reason == "corner":
			w_contact *= BREAKOUT_CORNER_CONTACT
			w_room *= BREAKOUT_CORNER_ROOM
		else:
			w_contact *= BREAKOUT_CONTACT
			w_room *= BREAKOUT_ROOM
	if caution != 1.0:
		w_proj *= caution
		w_contact *= caution
		w_dash *= caution
		w_aoe *= caution
		w_latent *= caution
	if adapt_scale != 1.0:
		# The alert rides the SAME five threat weights caution scales and the
		# same saved array restores: room/wall/dps are deliberately untouched,
		# so a hit makes the potato respect threats more, not hug the centre.
		w_proj *= adapt_scale
		w_contact *= adapt_scale
		w_dash *= adapt_scale
		w_aoe *= adapt_scale
		w_latent *= adapt_scale
	if dps_scale != 1.0:
		# Weaponless kits (Bull) and kits that cannot kill (Pacifist): the kill
		# reward would only drag them toward things they have no way to shoot.
		w_dps *= dps_scale
	if escaping:
		w_proj *= pin_threat
		w_contact *= pin_threat
		w_dash *= pin_threat
		w_aoe *= pin_threat
		w_latent *= pin_threat
		w_dps = 0.0        # the kill reward must not anchor us in the corner
		w_room = 0.0       # crowding is WHY we are here; it cannot also be the exit test
		w_wall *= PIN_WALL_BOOST
		# w_enclose is left alone on purpose: "which headings are blocked" is
		# exactly the right question to be asking while escaping.

	_prepare(p0, speed, body_radius, threats, current_hp, mitigation)
	# v2.10.0: decide whether objective pulls may steer this frame (see PULL_SAFE).
	# Runs before the candidate sweep because _cost reads _pull_scale.
	_update_pull_safety(p0, threats, body_radius)
	last_pull_scale = _pull_scale

	var cands = []
	for k in range(DIRS):
		var a = k * TAU / DIRS
		cands.push_back(Vector2(cos(a), sin(a)))
	cands.push_back(Vector2.ZERO)   # standing still is a real option, not a fallback

	var scores = []
	var best_i = 0
	var best_cost = 1e18
	for i in range(cands.size()):
		var c = _cost(cands[i], p0, speed, body_radius, far, rewards, targets,
				chargers, weapon_range, prefers_still, current_hp)
		scores.push_back(c)
		if c < best_cost:
			best_cost = c
			best_i = i

	# -- v2.5.0: close-in candidate for the committed goal -------------------
	# The action space is full-speed headings plus stand. A walk-on item that
	# is INSIDE one horizon step (speed x 0.8 s ~= 250 px) is then unreachable
	# in score terms: every full-speed heading OVERSHOOTS it, stand earns
	# nothing, so stand is the least-bad candidate and the bot parks about half
	# a step away forever -- offline closed-loop sim reproduced exactly this
	# (it stops 117 px from a 45 px-rim item and never consumes it). One extra
	# candidate at the exact speed that ends ON the goal teaches the scorer
	# that partial steps exist. Execution is still full speed for the frame and
	# re-decided next frame, so this is a scoring-window correction, not a
	# movement hack; threat prices for this candidate use the slower speed,
	# which is the CONSERVATIVE direction.
	if _goal_on:
		var gv = _goal_pos - p0
		var gd = gv.length()
		if gd > 1.0 and gd < speed * horizon:
			var gdir = gv / gd
			var gspeed = clamp(gd / horizon, speed * 0.15, speed)
			var gc = _cost(gdir, p0, gspeed, body_radius, far, rewards, targets,
					chargers, weapon_range, prefers_still, current_hp)
			cands.push_back(gdir)
			scores.push_back(gc)
			if gc < best_cost:
				best_cost = gc
				best_i = cands.size() - 1

	# -- v2.7.0: close-in candidate for a committed SPECIAL TARGET -----------
	# The same action-space problem the goal candidate above solves: a target
	# inside one horizon step (speed x 0.8 s) is overshot by every full-speed
	# heading, so the value pull is only scored on moves that end PAST the
	# desired firing range and the bot brakes early / stalls outside it. Offer
	# one candidate at the exact speed that ends ON the desired range. Scoring
	# window only; execution is still the full-speed frame (re-decided next
	# frame), exactly the goal-candidate semantics.
	if _opp_on and _bounty_on:
		var tv = _bounty_pos - p0
		var tdist = tv.length()
		var want = max(_bounty_desired, 1.0)
		if tdist > want and tdist - want < speed * horizon + 40.0:
			var tdir = tv / tdist
			var tspeed = clamp((tdist - want) / horizon, speed * 0.15, speed)
			var tc = _cost(tdir, p0, tspeed, body_radius, far, rewards, targets,
					chargers, weapon_range, prefers_still, current_hp)
			cands.push_back(tdir)
			scores.push_back(tc)
			if tc < best_cost:
				best_cost = tc
				best_i = cands.size() - 1

	# -- v2.3.0: 2-ply receding-horizon plan (see the PLAN_* block) --
	# The primary sweep is single-step greedy. Give the best K distinct FIRST
	# headings one extra ply on the same cost function: advance the threat set
	# to the next decision point, prepare there, and take the cheapest coarse
	# continuation (8 headings + stand). total = score1 + gamma * best2.
	# A tie-breaker for OUR first move, not an enemy forecast: constant velocity
	# for threats, targets/rewards held static (see _advance_threats).
	# Guards: --arb-plan=0 (exact greedy control), a threat count above
	# --arb-planthreats (frame-rate), no threats at all (nothing to plan around;
	# quiet frames must stay cheap), and a greedy ZERO winner (standing first is
	# not a rollout: the beam excludes ZERO by design, so overriding it would
	# force movement on fire_still/Streamer stands).
	last_plan_used = false
	last_plan_evals = 0
	if plan_depth > 0 and plan_beam > 0 and not threats.empty() \
			and threats.size() <= plan_max_threats and best_i != DIRS:
		var beam = _plan_beam_indices(cands, scores, plan_beam)
		if not beam.empty():
			# World state at the NEXT decision point: depends only on time, not
			# on which first move is being priced, so it is built once.
			var plan_threats = _advance_threats(threats, horizon)
			var plan_chargers = _advance_chargers(chargers, horizon)
			# _prepare() rewrites thirteen arrays plus two flags. Save the
			# references -- O(1), because _prepare assigns NEW arrays and never
			# mutates the old ones -- and put them back whatever happens below.
			var saved_prepared = [_p_pos, _p_vel, _p_rad, _p_soft, _p_coef,
					_p_still, _p_kill, _p_mark, _p_aimed, _p_start, _p_end,
					_p_future, _p_far, _p_room, _p_room_far]
			var saved_hop_wanted = _hop_wanted
			var saved_aoe_n = last_aoe_n
			var saved_last_dir = last_dir
			var plan_best = -1
			var plan_best_total = 1e18
			for pi in beam:
				var d1 = cands[pi]
				# Where this first move ENDS under the same wall clamp _cost
				# applies: the second decision starts from there.
				var p1 = p0 + d1 * speed * horizon
				p1.x = clamp(p1.x, body_radius, far.x - body_radius)
				p1.y = clamp(p1.y, body_radius, far.y - body_radius)
				# v2.5.0: with pursuit on, the world at the next decision point
				# is rebuilt per branch with pursuers aimed at WHERE THIS MOVE
				# ENDS. The 2.4.0 constant-velocity projection kept a ring's gaps
				# open in a straight line while the real chasers turn and close
				# them; that is the forecast the escape needs to be honest.
				var threats_here = plan_threats
				if pursuit_enable != 0.0:
					threats_here = _advance_threats(threats, horizon, p1)
					last_plan_evals += threats.size()
				# The next decision's hysteresis sees the first move as the
				# previous heading, exactly as the real next frame will.
				last_dir = d1
				_prepare(p1, speed, body_radius, threats_here, current_hp, mitigation)
				var c2 = 1e18
				for k2 in range(PLAN_DIRS):
					var a2 = k2 * TAU / PLAN_DIRS
					var c_next = _cost(Vector2(cos(a2), sin(a2)), p1, speed,
							body_radius, far, rewards, targets, plan_chargers,
							weapon_range, prefers_still, current_hp)
					last_plan_evals += 1
					if c_next < c2:
						c2 = c_next
				var c_stand = _cost(Vector2.ZERO, p1, speed, body_radius, far,
						rewards, targets, plan_chargers, weapon_range,
						prefers_still, current_hp)
				last_plan_evals += 1
				if c_stand < c2:
					c2 = c_stand
				var total = scores[pi] + plan_gamma * c2
				if total < plan_best_total:
					plan_best_total = total
					plan_best = pi
			_p_pos = saved_prepared[0]
			_p_vel = saved_prepared[1]
			_p_rad = saved_prepared[2]
			_p_soft = saved_prepared[3]
			_p_coef = saved_prepared[4]
			_p_still = saved_prepared[5]
			_p_kill = saved_prepared[6]
			_p_mark = saved_prepared[7]
			_p_aimed = saved_prepared[8]
			_p_start = saved_prepared[9]
			_p_end = saved_prepared[10]
			_p_future = saved_prepared[11]
			_p_far = saved_prepared[12]
			_p_room = saved_prepared[13]
			_p_room_far = saved_prepared[14]
			_hop_wanted = saved_hop_wanted
			last_aoe_n = saved_aoe_n
			last_dir = saved_last_dir
			if plan_best >= 0:
				# Adopt the first move with the best DISCOUNTED two-ply total.
				# best_cost goes back to its OWN first-ply score so the hop and
				# refinement passes below keep comparing like with like.
				best_i = plan_best
				best_cost = scores[plan_best]
				last_plan_used = true

	# Hops (see HOP_FRAC): half-speed headings, offered only near a telegraph
	# or a dash and never while escaping a pin (that flight wants every frame).
	var hop_first = cands.size()
	if hop_enable != 0.0 and _hop_wanted and not escaping:
		for k in range(HOP_DIRS):
			var a = k * TAU / HOP_DIRS + TAU / (2 * HOP_DIRS)   # offset from the full set
			var hd = Vector2(cos(a), sin(a))
			var c = _cost(hd, p0, speed * HOP_FRAC, body_radius, far, rewards, targets,
					chargers, weapon_range, prefers_still, current_hp)
			cands.push_back(hd)
			scores.push_back(c)
			if c < best_cost:
				best_cost = c
				best_i = cands.size() - 1
	last_hop = best_i >= hop_first
	var best_speed = speed * HOP_FRAC if last_hop else speed

	# Bisection refinement. A flat 24-way sweep cannot thread a bullet gap
	# narrower than 15 deg; halving twice around the winner reaches 3.75 deg
	# without paying for 96 candidates every frame.
	var best_dir = cands[best_i]
	if best_dir != Vector2.ZERO:
		var step = TAU / DIRS * 0.5
		for _r in range(REFINE_ROUNDS):
			var improved = best_dir
			for s in [step, -step]:
				var rc = best_dir.rotated(s)
				var c = _cost(rc, p0, best_speed, body_radius, far, rewards, targets,
						chargers, weapon_range, prefers_still, current_hp)
				cands.push_back(rc)
				scores.push_back(c)
				if c < best_cost:
					best_cost = c
					improved = rc
					best_i = cands.size() - 1
			best_dir = improved
			step *= 0.5

	last_scores = scores
	last_dirs = cands
	last_best_index = best_i
	last_dir = best_dir
	# How much worse STANDING scored than the chosen move. Kept for the
	# overlay; the tap-mover no longer gates on it, because a stutter is not
	# a stand: it is the chosen move at reduced speed, and pricing it as a
	# full-horizon stop made every flight look uninterruptible when the real
	# cost of a two-frame volley is ~12 px of separation. The ZERO candidate
	# always sits at index DIRS in the initial sweep.
	last_still_gap = scores[DIRS] - best_cost
	# The stutter's TRUE cost: the winning heading scored again at the net
	# speed the tap cycle actually delivers, minus the full-speed score. Same
	# scorer, same threats, same dodge simulation -- only the distance covered
	# changes -- so a pursuer about to connect prices the slowdown as lethal
	# and a swarm still 300 px out prices it as nearly free. Standing needs
	# no stutter (it already fires), so the gap is zero there.
	last_stutter_gap = 0.0
	if _fire_still and best_dir != Vector2.ZERO:
		last_stutter_gap = _cost(best_dir, p0, speed * STUTTER_SPEED_FRAC, body_radius,
				far, rewards, targets, chargers, weapon_range, prefers_still,
				current_hp) - best_cost

	# Telemetry: the standoff cost the CHOSEN move actually paid. Re-scored
	# here because per-candidate costs are not kept; one target loop per frame,
	# and only while the kite term is live (the control arm pays nothing).
	last_kite_cost = 0.0
	if _kite_r > 0.0 and not targets.empty():
		var kp = p0 + best_dir * best_speed * horizon
		kp.x = clamp(kp.x, body_radius, far.x - body_radius)
		kp.y = clamp(kp.y, body_radius, far.y - body_radius)
		var knd_sq = 1e18
		for t in targets:
			var ksq = kp.distance_squared_to(t[TG_POS])
			if ksq < knd_sq:
				knd_sq = ksq
		if knd_sq < _kite_r * _kite_r:
			last_kite_cost = w_kite * (1.0 - sqrt(knd_sq) / _kite_r)

	if scaled:
		w_proj = saved[0]
		w_contact = saved[1]
		w_dash = saved[2]
		w_aoe = saved[3]
		w_latent = saved[4]
		w_dps = saved[5]
		w_room = saved[6]
		w_wall = saved[7]
	return best_dir


# How long can this velocity be held before the arena stops producing
# displacement? Walls SLIDE (the engine cancels only the crossing component),
# so motion dies when EVERY moving axis has exhausted its room: straight at a
# wall stops on contact (no slide component), a diagonal dies at the corner
# (max of the two axis times), parallel to a wall runs forever. An axis with
# no velocity contributes nothing -- it neither runs out nor rescues.
func _runway(p0: Vector2, vel: Vector2, body_radius: float, far: Vector2) -> float:
	var t = 0.0
	if vel.x > 0.0:
		t = max(t, (far.x - body_radius - p0.x) / vel.x)
	elif vel.x < 0.0:
		t = max(t, (p0.x - body_radius) / -vel.x)
	if vel.y > 0.0:
		t = max(t, (far.y - body_radius - p0.y) / vel.y)
	elif vel.y < 0.0:
		t = max(t, (p0.y - body_radius) / -vel.y)
	return t


# Is the bot actually STUCK, as opposed to merely near a wall? Skimming an edge at
# full speed is ordinary play and must not trigger this. What matters is failing to
# convert speed into DISPLACEMENT while cornered, so the test is net travel across a
# window. That also catches oscillation -- a bot flipping between two headings moves
# every frame but goes nowhere, which any per-frame speed check reads as healthy.
# Not being able to see that state is likely why four weight-based attempts could
# not move it: they could only see wall distance.
func _update_pin(p0: Vector2, speed: float, edge: float) -> bool:
	_pin_hist.push_back(p0)
	if _pin_hist.size() > PIN_WINDOW:
		_pin_hist.pop_front()

	if _pin_ticks > 0:
		_pin_ticks -= tick_step
		# End early once genuinely clear, so we spend no more of the damage
		# budget than getting out actually cost.
		if edge >= PIN_CLEAR:
			_pin_ticks = 0
			_pin_frames = 0
			return false
		return true

	var stuck = false
	if edge < PIN_EDGE and _pin_hist.size() >= PIN_WINDOW:
		var travelled = p0.distance_to(_pin_hist[0])
		var could = speed * float(PIN_WINDOW * tick_step) / 60.0
		stuck = travelled < could * PIN_TRAVEL_FRAC
	if stuck:
		_pin_frames += tick_step
	else:
		_pin_frames = 0

	# Wall dwell: the tap-mover's trigger (see PIN_DWELL), and any row's that
	# sets pin_dwell (see the note above PIN_TICKS).
	if _pin_dwell_limit > 0 and edge < PIN_EDGE:
		_pin_dwell += tick_step
	elif _pin_dwell_limit > 0:
		# Leaky, not a hard reset: a bot dodging in and out of the wall band
		# still accumulates net dwell (see pin_leak).
		_pin_dwell = max(_pin_dwell - int(ceil(pin_leak * tick_step)), 0)

	if _pin_frames >= PIN_CONFIRM or (_pin_dwell_limit > 0 and _pin_dwell >= _pin_dwell_limit):
		_pin_frames = 0
		_pin_dwell = 0
		_pin_ticks = PIN_TICKS
		pin_fires += 1
		return true
	return false


# Hoist every candidate-independent quantity out of the scoring loop.
func _prepare(p0: Vector2, speed: float, body_radius: float, threats: Array,
		current_hp: float, mitigation: float) -> void:
	_p_pos = []
	_p_vel = []
	_p_rad = []
	_p_soft = []
	_p_coef = []
	_p_still = []
	_p_kill = []
	_p_mark = []
	_p_aimed = []
	_p_start = []
	_p_end = []
	_p_future = []
	_p_far = []
	_p_room = []
	_p_room_far = []

	var inv_hp = 1.0 / max(current_hp, 1.0)
	var reach = speed * horizon          # everything we could possibly walk to
	_hop_wanted = false
	last_aoe_n = 0
	var hop_sq = HOP_RANGE * HOP_RANGE

	for t in threats:
		var radius = t[T_RADIUS] + body_radius
		var soft = radius * HIT_MARGIN
		var pos = t[T_POS]
		var vel = t[T_VEL]
		var kind = t[T_KIND]
		var speed_of = vel.length()

		# How far ahead this particular threat is worth scanning. Bodies and
		# dashes keep the plain horizon -- they are already fast relative to us
		# and a longer look would just compound the straight-line assumption.
		# Only projectiles, whose speed varies 3x across the game, get stretched.
		var scan = horizon
		if kind == KIND_PROJ and speed_of > 1.0:
			scan = clamp(scan_distance / speed_of, horizon, SCAN_MAX)
		var t_end = min(scan, t[T_END])

		# Crowding still measures where things are at the HORIZON, not at the
		# end of the scan: "how boxed in am I when I get there" is a question
		# about the move being scored, and stretching it for slow bullets would
		# quietly redefine the terminal state for everything else.
		var span = max(horizon - t[T_START], 0.0)
		var scan_span = max(t_end - t[T_START], 0.0)

		# Cull: if the threat cannot close on any reachable point, and ends the
		# horizon far outside the crowding ring, it cannot affect any candidate.
		var travel = speed_of * scan_span
		var gap = pos.distance_to(p0)
		if gap - travel > reach + max(soft, max(ENCLOSE_RADIUS, room_cap) + radius):
			continue

		# Price this hit by the share of remaining life it takes, so the same
		# 5 damage is a scratch at full HP and near-lethal on a 12 HP build.
		# Lethality stays keyed to a SINGLE hit, not to dmg * ticks. Scaling it
		# by the whole expected encounter would compound persistence twice --
		# once in the coefficient and again here -- and a sticky body would end
		# up quadratically feared. One hit landing is what the multiplier was
		# defined against; how many land is already priced by T_TICKS.
		var dmg = t[T_DAMAGE]
		var lethal = 1.0 + lethality * min(dmg * inv_hp, 1.0)
		var kw = w_proj
		if kind == KIND_CONTACT:
			kw = w_contact
		elif kind == KIND_DASH:
			kw = w_dash
		elif kind == KIND_AOE or kind == KIND_MARK:
			kw = w_aoe
		_p_mark.push_back(kind == KIND_MARK)
		_p_aimed.push_back(kind == KIND_PROJ or kind == KIND_DASH)
		if (kind == KIND_AOE or kind == KIND_DASH) and pos.distance_squared_to(p0) < hop_sq:
			_hop_wanted = true
		if kind == KIND_AOE:
			last_aoe_n += 1

		_p_pos.push_back(pos)
		_p_vel.push_back(vel)
		_p_rad.push_back(radius)
		_p_soft.push_back(soft * soft)
		var coef = dmg * kw * t[T_TICKS] * lethal * mitigation
		_p_coef.push_back(coef)
		var still_coef = coef
		var kill = 0.0
		# not _escaping: while pinned, every stand-to-shoot perk yields -- the
		# override the cornering deaths asked for is "escape at the loss of
		# firing", so an escaping Soldier prices threats like anyone else.
		if (_stand_ok or _explode_trade) and t.size() > T_KILL:
			kill = float(t[T_KILL])
			if _stand_ok:
				still_coef = coef * (1.0 - FIRE_STILL_KILL * kill)
		_p_still.push_back(still_coef)
		_p_kill.push_back(kill)
		_p_start.push_back(t[T_START])
		_p_end.push_back(t_end)
		var future_pos = pos + vel * span
		var future_far = pos + vel * max(FAR_T - t[T_START], 0.0)
		# v2.6.1: the crowding projection must not let a pursuer overshoot us.
		# A CONTACT body whose frozen projection passes the player inside this
		# horizon is projected as a pursuer: it walks toward us and stops at
		# touching distance, so radial flight ends farther from it than orbiting.
		# Non-contact kinds and distant bodies keep their old projection, and
		# --arb-roomtrack=0 restores it for everyone (exact 2.6.0 control arm).
		if room_track != 0.0 and kind == KIND_CONTACT and speed_of > 1.0 \
				and speed_of < speed:
			# Scoped to bodies we can actually outrun: the point of the cap is
			# that flight CAN open the gap, so the crowding term must not call
			# flight crowded. Against a body faster than us the old projection is
			# not the reported failure (nothing escapes) and changing it perturbs
			# the tuned slow-player crowd cases, so those keep the frozen
			# projection. --arb-roomtrack=0 still restores it for everyone.
			var track_cap = gap - radius
			if track_cap < speed_of * span:
				var track_dir = vel / speed_of
				var track_now = max(track_cap, 0.0)
				future_pos = pos + track_dir * track_now
				future_far = pos + track_dir * min(
						speed_of * max(FAR_T - t[T_START], 0.0), track_now)
		_p_future.push_back(future_pos)
		_p_far.push_back(future_far)
		_p_room.push_back(future_pos)
		_p_room_far.push_back(future_far)


# -- v2.3.0 planner helpers --

# Advance the threat set to the NEXT decision point, HORIZON later, so the
# second ply prices the world the bot will actually re-decide in. Constant
# velocity and the same tuple layout, so _prepare/_cost consume it unchanged:
#   pos   += vel * max(dt - start, 0)   nothing moves during its wind-up
#   start  = max(start - dt, 0)         a dash that was winding up is now live
#   end    = end - dt                   drop it once it is spent
# TICKS/KILL/radius/damage are properties of the threat, not of the clock, so
# they ride along untouched. Targets and rewards are treated as STATIC: enemies
# walk, but this ply is a tie-breaker for OUR first move, not an enemy model --
# extrapolating them would double-count a prediction the first ply already
# prices as a threat. The cost is one small array per live threat per frame.
#
# v2.5.0: `target` (optional) switches CONTACT/DASH bodies from constant
# velocity to PURSUIT -- they walk toward `target`, capped at touching
# distance. The potato's own motion is what makes a straight-line projection
# lie: a chaser 300 px beside the projected path turns and closes the gap the
# old model kept open, which is exactly the ring-closure the escape planner
# must forecast. Called with no target (the 2.4.0 call shape) the function is
# bit-for-bit the old one, which is also the --arb-pursuit=0 control arm.
func _advance_threats(ts: Array, dt: float, target = null) -> Array:
	var pursuit = target != null and pursuit_enable != 0.0
	var out = []
	for t in ts:
		var start = float(t[T_START])
		var end = float(t[T_END]) - dt
		if end <= 0.0:
			continue
		var pos = t[T_POS] + t[T_VEL] * max(dt - start, 0.0)
		if pursuit and (t[T_KIND] == KIND_CONTACT or t[T_KIND] == KIND_DASH):
			var here = t[T_POS]
			var dist = here.distance_to(target)
			if dist > 0.001:
				var step = t[T_VEL].length() * max(dt - start, 0.0)
				var stop = float(t[T_RADIUS]) + BODY_RADIUS_FALLBACK
				var travel = min(step, max(dist - stop, 0.0))
				pos = here + (target - here) / dist * travel
		var advanced = [pos,
				t[T_VEL], t[T_RADIUS], t[T_DAMAGE], t[T_KIND],
				max(start - dt, 0.0), t[T_TICKS], end]
		if t.size() > T_KILL:
			advanced.push_back(t[T_KILL])
		out.push_back(advanced)
	return out


# Idle chargers are latent dashes: advance their cooldowns with the clock.
# Only ready is time-dependent, so the tuples are rebuilt with one field moved.
func _advance_chargers(cs: Array, dt: float) -> Array:
	if cs.empty():
		return cs
	var out = []
	for c in cs:
		out.push_back([c[C_POS], c[C_RANGE], c[C_DAMAGE],
				max(float(c[C_READY]) - dt, 0.0)])
	return out


# -- v2.5.0 helper: the escape/planning layer ------------------------------
# Everything below is read by choose()/ _cost only when the corresponding
# --arb-* switch is on, so the 2.4.0 control arm never executes it.

const BREAKOUT_BINS = 120        # 3-degree sectors for the gap measure

# Largest angular gap in the ring of CONTACT bodies around us, at t =
# forecast_t (0 = now). Bodies are projected as PURSUERS: they walk toward us
# and stop at touching distance (a body at zero distance has no bearing, so
# it cannot be used for a gap measure -- the cap keeps its bearing intact).
# Each body blocks an arc of half-width atan2(radius + our body, distance):
# the closer the ring, the wider every body blocks, so a ring that still has
# gaps NOW can already read as closed at FORECAST -- which is exactly the
# "I can see it will be surrounded" the player asked for. Cheapest robust
# implementation: 3-degree occupancy bins plus the longest free run on the
# circle (no sorting, wraps correctly).
func _ring_largest_gap(p0: Vector2, threats: Array, forecast_t: float) -> float:
	var bins = []
	bins.resize(BREAKOUT_BINS)
	for i in range(BREAKOUT_BINS):
		bins[i] = false
	var blocked_any = false
	for t in threats:
		var k = t[T_KIND]
		if k != KIND_CONTACT and k != KIND_DASH:
			continue
		var pos = t[T_POS]
		var dist = pos.distance_to(p0)
		if dist > BREAKOUT_RING and forecast_t <= 0.0:
			continue
		if forecast_t > 0.0:
			var stop = float(t[T_RADIUS]) + BREAKOUT_BODY
			if dist > 0.001:
				var travel = min(t[T_VEL].length() * forecast_t, max(dist - stop, 0.0))
				pos = pos + (p0 - pos) / dist * travel
				dist = pos.distance_to(p0)
		if dist > BREAKOUT_RING:
			continue
		var half = atan2(float(t[T_RADIUS]) + BREAKOUT_BODY, max(dist, 1.0))
		var mid = (pos - p0).angle()
		var i0 = int(floor((mid - half + PI) / TAU * float(BREAKOUT_BINS)))
		var i1 = int(floor((mid + half + PI) / TAU * float(BREAKOUT_BINS)))
		# intervals are short (< PI/2); a wrapped linear walk is exact
		for j in range(i1 - i0 + 1):
			var idx = (i0 + j) % BREAKOUT_BINS
			if idx < 0:
				idx += BREAKOUT_BINS
			bins[idx] = true
			blocked_any = true
	if not blocked_any:
		return TAU
	var best = 0
	var run = 0
	for i in range(BREAKOUT_BINS * 2):
		if not bins[i % BREAKOUT_BINS]:
			run += 1
			if run > best:
				best = run
		else:
			run = 0
	best = min(best, BREAKOUT_BINS)
	return float(best) / float(BREAKOUT_BINS) * TAU


func _count_contact(p0: Vector2, threats: Array, radius: float) -> int:
	var n = 0
	var r_sq = radius * radius
	for t in threats:
		var k = t[T_KIND]
		if k != KIND_CONTACT and k != KIND_DASH:
			continue
		if t[T_POS].distance_squared_to(p0) <= r_sq:
			n += 1
	return n


# Closest real BODY (contact/dash) distance; bullets are excluded on purpose:
# a permanent bullet stream must not veto every item goal, and bullets are
# already priced per candidate by the normal threat terms.
func _nearest_body_dist(p0: Vector2, threats: Array) -> float:
	var best = 1e18
	for t in threats:
		var k = t[T_KIND]
		if k != KIND_CONTACT and k != KIND_DASH:
			continue
		var d = t[T_POS].distance_to(p0)
		if d < best:
			best = d
	return best


# v2.10.0: objective-pull guard (see the PULL_SAFE block). Decides whether the
# committed goal/bounty pulls and the per-step reward attraction may steer this
# decision. A body counts as "too close to trust a pull" once it is inside the
# taper band where the contact price starts to matter -- exactly the regime in
# which _taper is flat and the pull would otherwise choose the heading.
#   ratio = (dist - combined_radius) / taper_width
#   ratio <= 0  -> inside the model contact bubble (contact price saturated)
#   ratio >= 1  -> clear of the taper (contact price 0)
# The committed special target is skipped while it is the bounty aim: its own
# body must not veto the approach to it.
func _update_pull_safety(p0: Vector2, threats: Array, body_radius: float) -> void:
	_pull_scale = 1.0
	if pull_safe == 0.0:
		_pull_suppressed = false
		return
	var min_ratio = 1e18
	for t in threats:
		var k = t[T_KIND]
		if k != KIND_CONTACT and k != KIND_DASH:
			continue
		if _bounty_on and t[T_POS].distance_squared_to(_bounty_pos) < 1.0:
			continue    # the thing we are committing to approach is not an obstacle
		var combined = float(t[T_RADIUS]) + body_radius
		var taper = combined * (HIT_MARGIN - 1.0)
		if taper <= 0.001:
			continue
		var ratio = (t[T_POS].distance_to(p0) - combined) / taper
		if ratio < min_ratio:
			min_ratio = ratio
	if _pull_suppressed:
		if min_ratio > PULL_SAFE_RELEASE:
			_pull_suppressed = false
	elif min_ratio < PULL_SAFE_ENTER:
		_pull_suppressed = true
	_pull_scale = 0.0 if _pull_suppressed else 1.0


# Best EVASION LINE out of a closing ring: integrate 16 headings for
# BREAKOUT_ROLLOUT_T against the same pursuit model, score by the WORST
# clearance over the whole line (walls included). This is the piece the local
# cost cannot express -- a line that gives up 20 px of clearance at t=0.3 s
# to be outside the ring at t=1.5 s is worth it, and only a rollout sees
# that. Lines whose worst clearance is below BREAKOUT_PASS are rejected; if
# none survives, the ring is already closed and the mode refuses to arm
# (better the normal dodge than a magical "run through").
func _rollout_escape_dir(p0: Vector2, speed: float, far: Vector2,
		threats: Array) -> Vector2:
	var bodies = []
	for t in threats:
		var k = t[T_KIND]
		if k != KIND_CONTACT and k != KIND_DASH:
			continue
		if float(t[T_START]) > BREAKOUT_ROLLOUT_T:
			continue
		var d = t[T_POS].distance_to(p0)
		if d > BREAKOUT_RING * 1.5:
			continue
		bodies.push_back([t[T_POS], t[T_VEL].length(), float(t[T_RADIUS]), d])
	if bodies.empty():
		return Vector2.ZERO
	# Cap the rollout at the nearest bodies; a full-screen swarm does not make
	# the line any different (the nearest ring is what is in the way) and the
	# integration cost is linear in this count. Selection of the 24 nearest by
	# repeated min -- tiny counts, no sort dependency.
	if bodies.size() > 24:
		var pool = bodies.duplicate()
		var near = []
		for _pick in range(24):
			var bi = 0
			for i in range(1, pool.size()):
				if float(pool[i][3]) < float(pool[bi][3]):
					bi = i
			near.push_back(pool[bi])
			pool.remove(bi)
		bodies = near
	var steps = int(round(BREAKOUT_ROLLOUT_T * BREAKOUT_ROLLOUT_HZ))
	var best_score = -1e18
	var best_worst = -1e18
	var best = Vector2.ZERO
	for k in range(BREAKOUT_DIRS):
		var a = float(k) * TAU / float(BREAKOUT_DIRS)
		var d = Vector2(cos(a), sin(a))
		var p2 = p0
		var pos2 = []
		for b in bodies:
			pos2.push_back(b[0])
		var worst = 1e9
		var final_clear = 1e9
		for _s in range(steps):
			p2 += d * speed / float(BREAKOUT_ROLLOUT_HZ)
			p2.x = clamp(p2.x, BREAKOUT_BODY, far.x - BREAKOUT_BODY)
			p2.y = clamp(p2.y, BREAKOUT_BODY, far.y - BREAKOUT_BODY)
			var frame_clear = min(min(p2.x - BREAKOUT_BODY, far.x - BREAKOUT_BODY - p2.x),
					min(p2.y - BREAKOUT_BODY, far.y - BREAKOUT_BODY - p2.y))
			for i in range(bodies.size()):
				var to = p2 - pos2[i]
				var dist = to.length()
				var stop = float(bodies[i][2]) + BREAKOUT_BODY
				if dist > stop:
					pos2[i] += to / dist * float(bodies[i][1]) / float(BREAKOUT_ROLLOUT_HZ)
				frame_clear = min(frame_clear, p2.distance_to(pos2[i]) - stop)
			worst = min(worst, frame_clear)
			final_clear = frame_clear
		# Worst clearance alone picks the ORBIT, not the exit: skirting the ring
		# at 80 px never touches anybody, while the line that actually leaves
		# has to squeeze past bodies for a moment. The terminal clearance is
		# what distinguishes "still inside the cage" from "outside it", so the
		# score pays for it -- this is the whole lesson of the closed-loop sim.
		var score = worst + 0.6 * final_clear
		if score > best_score:
			best_score = score
			best_worst = worst
			best = d
	if best_worst < BREAKOUT_PASS:
		return Vector2.ZERO
	return best


# Arm / maintain / release the pre-emptive breakout mode (see the block).
func _update_breakout(p0: Vector2, speed: float, far: Vector2,
		threats: Array) -> bool:
	last_breakout_evals = 0
	_breakout_free_now = 1.0
	_breakout_free_fut = 1.0
	_breakout_edge = min(min(p0.x - BREAKOUT_BODY, far.x - BREAKOUT_BODY - p0.x),
			min(p0.y - BREAKOUT_BODY, far.y - BREAKOUT_BODY - p0.y))
	# Pin escape already owns a commitment; never stack the two modes.
	if _escaping:
		_breakout_engaged = false
		_breakout_ticks = 0
		_breakout_reason = ""
		return false
	if _breakout_engaged:
		# RUNNING THE ESCAPE OUT. The mode does not hand control back when the
		# forecast gap re-opens (being 50 px from one body already reads as a
		# wide gap while the rest of the pack is still on us): it ends when the
		# nearest body is genuinely clear, the floor is open again (corner
		# escape), or the safety cap expires.
		_breakout_ticks -= 1
		_breakout_free_now = _ring_largest_gap(p0, threats, 0.0)
		_breakout_free_fut = _ring_largest_gap(p0, threats, BREAKOUT_FORECAST)
		var nearest = _nearest_body_dist(p0, threats)
		var corner_done = _breakout_reason == "corner" \
				and _breakout_edge > BREAKOUT_EDGE_CLEAR \
				and nearest > BREAKOUT_CLEAR * 0.7
		if nearest > BREAKOUT_CLEAR or corner_done or _breakout_ticks <= 0:
			_breakout_engaged = false
			_breakout_cooldown = BREAKOUT_CORNER_COOLDOWN \
					if _breakout_reason == "corner" else BREAKOUT_COOLDOWN
			_breakout_reason = ""
			return false
		_breakout_recheck -= 1
		if _breakout_recheck <= 0:
			_breakout_recheck = BREAKOUT_RECHECK
			var nd = _rollout_escape_dir(p0, speed, far, threats)
			last_breakout_evals += BREAKOUT_DIRS
			if nd != Vector2.ZERO:
				_breakout_dir = nd
		return true
	if _breakout_cooldown > 0:
		_breakout_cooldown -= 1
		return false

	# Trigger 1 (v2.5.0): a closing ring -- gap passable now, gone by FORECAST.
	var contacts = _count_contact(p0, threats, BREAKOUT_RING)
	if contacts >= BREAKOUT_MIN_CONTACT:
		var gap_now = _ring_largest_gap(p0, threats, 0.0)
		_breakout_free_now = gap_now
		if gap_now >= BREAKOUT_MIN_GAP:
			var gap_fut = _ring_largest_gap(p0, threats, BREAKOUT_FORECAST)
			_breakout_free_fut = gap_fut
			if gap_fut < BREAKOUT_FUT_GAP:
				var dir = _rollout_escape_dir(p0, speed, far, threats)
				last_breakout_evals += BREAKOUT_DIRS
				if dir != Vector2.ZERO:
					_breakout_dir = dir
					_breakout_engaged = true
					_breakout_ticks = BREAKOUT_MAX_TICKS
					_breakout_recheck = BREAKOUT_RECHECK
					_breakout_reason = "ring"
					return true

	# Trigger 2 (v2.6.0): one-sided pressure squeezing us into the wall band.
	# No ring is required -- a clump can herd the bot from open floor into the
	# edge (and then a corner) while every 0.8 s step looks locally fine. When
	# the floor is already thin and a crowd is on us, run the same wall-aware
	# rollout back toward open space and commit; this is the missing long-
	# horizon half of the wall term (see BREAKOUT_EDGE).
	if _breakout_edge < BREAKOUT_EDGE:
		var crowd = _count_contact(p0, threats, BREAKOUT_CROWD_R)
		if crowd >= BREAKOUT_CROWD_MIN:
			var cdir = _rollout_escape_dir(p0, speed, far, threats)
			last_breakout_evals += BREAKOUT_DIRS
			if cdir != Vector2.ZERO:
				_breakout_dir = cdir
				_breakout_engaged = true
				_breakout_ticks = BREAKOUT_CORNER_TICKS
				_breakout_recheck = BREAKOUT_RECHECK
				_breakout_reason = "corner"
				return true
	return false


# Arm / maintain / release a BOUNTY approach toward a special target (see the
# BOUNTY_* block): bosses/elites, spawner eggs, cursed/evolved bodies. Only the
# calm case is planned -- a body within BOUNTY_BODY_SAFE vetoes acquisition and
# one inside BOUNTY_BODY_ABORT aborts -- so this is "go pick the fight while it
# is safe", not "tunnel through the wave for a kill".
func _update_bounty(p0: Vector2, targets: Array, threats: Array,
		weapon_range: float) -> bool:
	var desired = max(weapon_range * BOUNTY_DESIRE, 70.0)
	_bounty_desired = desired
	if _bounty_ticks > 0:
		_bounty_ticks -= 1
		var nearest_t = _nearest_special(targets, _bounty_pos, BOUNTY_HOLD)
		if nearest_t < 0.0:
			_bounty_ticks = 0
			return false
		if _nearest_body_dist(p0, threats) < BOUNTY_BODY_ABORT:
			_bounty_ticks = 0
			return false
		if _hp_ratio < BOUNTY_MIN_HP * 0.7:
			_bounty_ticks = 0
			return false
		if p0.distance_to(_bounty_pos) <= desired:
			# Inside firing range: the normal DPS/standoff terms take over.
			_bounty_ticks = 0
			return false
		return true
	if _hp_ratio < BOUNTY_MIN_HP:
		return false
	if _nearest_body_dist(p0, threats) < BOUNTY_BODY_SAFE:
		return false
	var best_u = 0.0
	var best_pos = Vector2.ZERO
	for t in targets:
		if t.size() <= TG_SPECIAL or float(t[TG_SPECIAL]) <= 0.0:
			continue    # no v2.6 special tag (or bounty disabled by world_view)
		var d = p0.distance_to(t[TG_POS])
		if d > BOUNTY_RANGE or d <= desired:
			continue
		# Value / ETA: a high-value special just outside the horizon of the
		# normal target term still loses to a nearer one.
		var u = float(t[TG_VALUE]) / (1.0 + d / 480.0)
		if u > best_u:
			best_u = u
			best_pos = t[TG_POS]
	if best_u <= 0.0:
		return false
	_bounty_pos = best_pos
	_bounty_ticks = BOUNTY_TICKS
	return true


# Distance to the nearest tagged special target, or -1 when none is within
# `radius` of `at` (the goal token check for a moved/despawned target).
func _nearest_special(targets: Array, at: Vector2, radius: float) -> float:
	var best = -1.0
	var r_sq = radius * radius
	for t in targets:
		if t.size() <= TG_SPECIAL or float(t[TG_SPECIAL]) <= 0.0:
			continue
		var dsq = t[TG_POS].distance_squared_to(at)
		if dsq <= r_sq and (best < 0.0 or dsq < best):
			best = dsq
	return -1.0 if best < 0.0 else sqrt(best)


# =============================================================================
# v2.7.0: unified opportunity planner (see the OPP_ block above)
# =============================================================================

# Tier index for the risk dial (round+clamp, so --arb-agg=1.4 reads the default
# row and any out-of-range value lands on an end row).
func _opp_agg_index() -> int:
	return int(round(clamp(opp_agg, 0.0, 2.0)))


func _opp_hp_floor() -> float:
	return float(OPP_HP_FLOORS[_opp_agg_index()])


# Explicit value table for the special-target classes (no _kill_value reuse:
# a 1000 HP boss reads almost zero killability and would lose to a trash mob).
# --arb-bounty still scales it, so bounty=0 disables special candidates.
# v2.8.0 (--arb-cov): Boss 50 vs Elite 30 split (world_view class 4 for elites);
# cov=0 keeps the exact v2.7.0 table (class 1 = 30 for both, no class 4).
func _opp_special_value(special_class: int) -> float:
	if special_class == SPECIAL_EGG:
		return OPP_VALUE_EGG      # spawner egg: killing it stops all future spawns
	if special_class == SPECIAL_DLC:
		return OPP_VALUE_DLC      # cursed / evolved body (DLC payoff)
	if cov_enable == 0.0:
		return OPP_VALUE_V27_CLASS1 if special_class == SPECIAL_BOSS else 0.0
	if special_class == SPECIAL_BOSS:
		return OPP_VALUE_BOSS
	if special_class == SPECIAL_ELITE:
		return OPP_VALUE_ELITE
	return 0.0


# v2.8.0 (--arb-cov): opportunity value of a reward. world_view tags the
# high-value produce classes at reward[6]; the explicit table replaces the
# legacy incidental price (a crate was 5, an evolution item 6-9, a tree 3 --
# all below a single body's 10-40 contact price, so the unified planner could
# almost never justify the detour). Raw r[R_VALUE] is kept as a floor, so a
# situationally boosted reward (hurt fruit, wave-end evolution item) still
# wins. cov=0 returns the exact v2.7.0 raw value.
func _opp_reward_value(r: Array) -> float:
	var raw = float(r[R_VALUE])
	if cov_enable == 0.0 or r.size() <= 6:
		return raw
	var tag = int(round(float(r[R_TAG])))
	var table = 0.0
	if tag == OPP_TAG_CRATE:
		table = OPP_VALUE_CRATE
	elif tag == OPP_TAG_LEGENDARY:
		table = OPP_VALUE_CRATE_LEGENDARY
	elif tag == OPP_TAG_EVO:
		table = OPP_VALUE_EVO
	elif tag == OPP_TAG_LOOT:
		table = OPP_VALUE_LOOT
	elif tag == OPP_TAG_TREE:
		table = OPP_VALUE_TREE
	return max(raw, table)


# Estimated HP damage of walking the straight route p0 -> dest through the
# CURRENT threat set: one closest-approach pass per threat (the same relative-
# motion math _cost uses), tapered over OPP_RISK_TAPER beyond the hit radius.
# A crude but honest "what does this detour cost" number for the acquisition
# gate; the per-frame threat terms still dodge whatever this misses. Bodies
# merely NEAR the route keep a partial price, so agg=0 only accepts an
# effectively empty lane.
func _opp_route_risk(p0: Vector2, dest: Vector2, threats: Array, speed: float,
		body_radius: float, mitigation: float) -> float:
	var to = dest - p0
	var dist = to.length()
	if dist < 1.0:
		return 0.0
	var own_v = to / dist * max(speed, 1.0)
	var eta = dist / max(speed, 1.0)
	var risk = 0.0
	for t in threats:
		var start = float(t[T_START])
		var end = min(float(t[T_END]), eta)
		if end <= start:
			continue
		var w = t[T_POS] - p0
		var rel = t[T_VEL] - own_v
		var tt = start
		var denom = rel.length_squared()
		if denom > 0.000001:
			tt = clamp(- w.dot(rel) / denom, start, end)
		var miss = (w + rel * tt).length()
		var hit_r = float(t[T_RADIUS]) + body_radius
		if miss >= hit_r + OPP_RISK_TAPER:
			continue
		var frac = clamp(1.0 - max(miss - hit_r, 0.0) / OPP_RISK_TAPER, 0.0, 1.0)
		risk += float(t[T_DAMAGE]) * float(t[T_TICKS]) * mitigation * frac
		if risk >= OPP_RISK_CAP:
			return OPP_RISK_CAP
	return risk


# Where to AIM at a reward that may be moving. r[R_VEL] is world_view's measured
# loot-alien velocity (optional 6th field; every older reward is static). Two
# fixed-point iterations: eta depends on the predicted point, which depends on
# eta. The speed is capped just under our own so a faster body cannot send the
# aim to infinity -- the bot then chases it, the honest fallback.
func _opp_aim_point(r: Array, p0: Vector2, speed: float) -> Vector2:
	var pos = r[R_POS]
	if r.size() > 5 and typeof(r[R_VEL]) == TYPE_VECTOR2:
		var vel = r[R_VEL]
		if vel.length() > 0.001:
			var vcap = max(speed * 0.95, 1.0)
			if vel.length() > vcap:
				vel = vel.normalized() * vcap
			var eta = p0.distance_to(pos) / max(speed, 1.0)
			for _i in range(2):
				pos = r[R_POS] + vel * eta
				eta = p0.distance_to(pos) / max(speed, 1.0)
	return pos


# Find the reward currently at/near `at` (the stored source position) inside a
# tolerance that grows with speed. Returns [] when the item is gone.
func _opp_reward_near(rewards: Array, at: Vector2, speed: float) -> Array:
	var found = []
	var best_d = 1e18
	var tol = max(OPP_HOLD, speed * 0.15)
	for r in rewards:
		if r.size() < 2:
			continue
		var d = r[R_POS].distance_to(at)
		if d < tol and d < best_d:
			best_d = d
			found = r
	return found


# A held reward (revive zone) is NOT an opportunity: the legacy mechanics own
# it, and walking a detour for a zone you must stand in confuses both layers.
func _opp_reward_held(r: Array) -> bool:
	if r.size() > 3 and float(r[R_RIM]) > 0.0:
		if not (r.size() > 4 and float(r[R_WALKON]) > 0.0):
			return true
	return false


# Position of the nearest tagged special target within `radius` of `at`
# ([] when none remains). Targets are re-read every frame, so the stored
# position is refreshed from the live tuple instead of chasing a ghost.
func _opp_special_near(targets: Array, at: Vector2, radius: float) -> Array:
	var found = []
	var best_d = 1e18
	var r_sq = radius * radius
	for t in targets:
		if t.size() <= TG_SPECIAL or float(t[TG_SPECIAL]) <= 0.0:
			continue
		var dsq = t[TG_POS].distance_squared_to(at)
		if dsq <= r_sq and dsq < best_d:
			best_d = dsq
			found = [t[TG_POS]]
	return found


func _opp_release() -> bool:
	_opp_ticks = 0
	_opp_cooldown = OPP_COOLDOWN
	_opp_on = false
	_goal_on = false
	_bounty_on = false
	return false


# Arm / maintain / release the unified opportunity commitment. Returns true
# while a useful non-trivial approach exists. Writes the SAME _goal_*/
# _bounty_* state the legacy layers wrote (so cost/pull/close-in/telemetry are
# shared) and adds the value/risk bookkeeping the new layer needs.
func _update_opportunity(p0: Vector2, speed: float, body_radius: float,
		mitigation: float, threats: Array, rewards: Array, targets: Array,
		weapon_range: float) -> bool:
	var desired_t = max(weapon_range * BOUNTY_DESIRE, 70.0)
	var agg = float(_opp_agg_index())
	# -- maintain an existing commitment --
	if _opp_ticks > 0:
		_opp_ticks -= 1
		if _opp_kind == "target":
			_bounty_desired = desired_t
			var special = _opp_special_near(targets, _bounty_pos, OPP_HOLD)
			if special.empty():
				return _opp_release()
			_bounty_pos = special[0]
			var bd = p0.distance_to(_bounty_pos)
			if bd <= desired_t + 20.0:
				return _opp_release()      # inside firing range: normal terms take over
			if _hp_ratio < _opp_hp_floor() * OPP_ABORT_HP_FRAC:
				return _opp_release()
			_opp_on = true
			_goal_on = false
			_bounty_on = true
			return true
		var r = _opp_reward_near(rewards, _opp_src, speed)
		if r.empty():
			return _opp_release()          # picked / despawned
		_opp_src = r[R_POS]
		_goal_pos = _opp_aim_point(r, p0, speed)
		if p0.distance_to(r[R_POS]) < GOAL_DONE_R:
			return _opp_release()          # arrived: the game collects this/next frame
		if _hp_ratio < _opp_hp_floor() * OPP_ABORT_HP_FRAC:
			return _opp_release()
		_goal_value = _opp_reward_value(r)
		_goal_frac = clamp(_goal_value / 9.0, 0.5, 1.6)
		_opp_goal_scale = clamp(_goal_value / 9.0, 1.0, OPP_GOAL_SCALE_MAX)
		_opp_on = true
		_goal_on = true
		_bounty_on = false
		return true
	if _opp_cooldown > 0:
		_opp_cooldown -= 1
		return false
	if _hp_ratio < _opp_hp_floor():
		return false
	# -- acquire: value table target OR high-value reward, risk-adjusted --
	var best_score = OPP_MARGIN
	var best_value = 0.0
	var best_risk = 0.0
	var best_pos = Vector2.ZERO
	var best_src = Vector2.ZERO
	var best_kind = ""
	if bounty_enable != 0.0:
		for t in targets:
			if t.size() <= TG_SPECIAL or float(t[TG_SPECIAL]) <= 0.0:
				continue
			var val = _opp_special_value(int(t[TG_SPECIAL])) * bounty_enable
			if val <= 0.0:
				continue
			var d = p0.distance_to(t[TG_POS])
			if d <= desired_t or d > OPP_TARGET_MAX:
				continue
			var risk = _opp_route_risk(p0, t[TG_POS], threats, speed, body_radius, mitigation)
			if risk > val * (OPP_RISK_BASE + OPP_RISK_PER_AGG * agg) + OPP_RISK_FLAT * agg:
				continue
			var score = val - risk - OPP_ETA_COST * (d / max(speed, 1.0))
			if score > best_score:
				best_score = score
				best_value = val
				best_risk = risk
				best_pos = t[TG_POS]
				best_src = t[TG_POS]
				best_kind = "target"
	if goal_enable != 0.0:
		for r in rewards:
			if r.size() < 2:
				continue
			var rv = _opp_reward_value(r)
			if rv < GOAL_MIN_VALUE or _opp_reward_held(r):
				continue
			var aim = _opp_aim_point(r, p0, speed)
			var d2 = p0.distance_to(aim)
			# A fleeing prey legitimately leads the chase past the legacy item
			# range (intercept time x its speed), so moving rewards get the
			# special-target bound; static rewards keep the v2.5 GOAL_RANGE.
			# If even the AIM is beyond the bound, fall back to the current
			# position when that is still chaseable, else skip.
			var moving = r.size() > 5 and typeof(r[R_VEL]) == TYPE_VECTOR2 \
					and r[R_VEL].length() > 0.001
			var rmax = OPP_TARGET_MAX if moving else GOAL_RANGE
			if d2 > rmax:
				aim = r[R_POS]
				d2 = p0.distance_to(aim)
			if d2 > rmax or d2 < GOAL_DONE_R:
				continue
			var risk2 = _opp_route_risk(p0, aim, threats, speed, body_radius, mitigation)
			if risk2 > rv * (OPP_RISK_BASE + OPP_RISK_PER_AGG * agg) + OPP_RISK_FLAT * agg:
				continue
			var score2 = rv - risk2 - OPP_ETA_COST * (d2 / max(speed, 1.0))
			if score2 > best_score:
				best_score = score2
				best_value = rv
				best_risk = risk2
				best_pos = aim
				best_src = r[R_POS]
				best_kind = "reward"
	if best_kind == "":
		return false
	_opp_on = true
	_opp_kind = best_kind
	_opp_value = best_value
	_opp_risk = best_risk
	_opp_ticks = OPP_TICKS
	_goal_on = false
	_bounty_on = false
	if best_kind == "target":
		_opp_pull = clamp(OPP_PULL_BASE + OPP_PULL_PER_VALUE * best_value,
				OPP_PULL_MIN, OPP_PULL_MAX)
		_bounty_on = true
		_bounty_pos = best_pos
		_bounty_desired = desired_t
		_opp_desired = desired_t
	else:
		_goal_on = true
		_goal_pos = best_pos
		_goal_value = best_value
		_goal_frac = clamp(best_value / 9.0, 0.5, 1.6)
		_opp_goal_scale = clamp(best_value / 9.0, 1.0, OPP_GOAL_SCALE_MAX)
		_opp_src = best_src
		_opp_desired = 0.0
	return true


# Arm / maintain / release the committed item goal (see the GOAL_* block).
# The pull is a separate cost term in _cost, and this function only decides
# WHICH reward deserves the commitment and WHEN to drop it: calm neighbourhood
# to acquire, a live body closing in to abort, arrival / disappearance /
# timeout to release. Value 0 is a no-op (--arb-goal=0).
func _update_goal(p0: Vector2, threats: Array, rewards: Array) -> bool:
	if _goal_ticks > 0:
		_goal_ticks -= 1
		var still = false
		for r in rewards:
			if r.size() > 0 and r[R_POS].distance_to(_goal_pos) < 30.0:
				still = true
				break
		if not still:
			_goal_on = false
			_goal_ticks = 0
			_goal_cooldown = GOAL_COOLDOWN
			return false
		var gd = p0.distance_to(_goal_pos)
		if gd < GOAL_DONE_R:
			# Arrived: the pickup's own taken bonus collects it this frame or
			# next; release so the next item can be chosen.
			_goal_on = false
			_goal_ticks = 0
			_goal_cooldown = 10
			return false
		if _nearest_body_dist(p0, threats) < GOAL_ABORT_R:
			_goal_on = false
			_goal_ticks = 0
			_goal_cooldown = GOAL_COOLDOWN
			return false
		return true
	if _goal_cooldown > 0:
		_goal_cooldown -= 1
		return false
	if _nearest_body_dist(p0, threats) < GOAL_SAFE_R:
		return false
	var best_u = 0.0
	var best_pos = Vector2.ZERO
	var best_val = 0.0
	for r in rewards:
		if r.size() < 2:
			continue
		var v = float(r[R_VALUE])
		if v < GOAL_MIN_VALUE:
			continue
		# A held zone (revive) is not an item you walk over and consume.
		var held = r.size() > 3 and float(r[R_RIM]) > 0.0 \
				and not (walk_enable != 0.0 and r.size() > 4 and float(r[R_WALKON]) > 0.0)
		if held:
			continue
		var d = p0.distance_to(r[R_POS])
		if d > GOAL_RANGE or d < GOAL_DONE_R:
			continue
		var u = v / (1.0 + d / GOAL_FALLOFF)
		if u > best_u:
			best_u = u
			best_pos = r[R_POS]
			best_val = v
	if best_u <= 0.0:
		return false
	_goal_pos = best_pos
	_goal_value = best_val
	_goal_frac = clamp(best_val / 9.0, 0.5, 1.6)
	_goal_ticks = GOAL_COMMIT
	return true


# Beam for the second ply: the top K PRIMARY headings by first-ply score,
# skipping ZERO (standing is not a rollout -- see the guard in choose) and
# de-duplicated by angle so the beam does not spend four evaluations on
# neighbouring 15-degree bins that price nearly the same first move. Returns
# indices into cands. size(K * DIRS * K) at worst (K=4: ~384 integer/float
# compares) -- trivial next to one extra _cost pass.
func _plan_beam_indices(cands: Array, scores: Array, limit: int) -> Array:
	var out = []
	var min_dot = cos(TAU / DIRS * PLAN_DEDUPE_BINS)
	for _k in range(limit):
		var pick = -1
		var pick_score = 1e18
		for i in range(DIRS):
			var dup = false
			for j in out:
				if cands[i].dot(cands[j]) > min_dot:
					dup = true
					break
			if dup:
				continue
			if scores[i] < pick_score:
				pick_score = scores[i]
				pick = i
		if pick < 0:
			break
		out.push_back(pick)
	return out


func _cost(d: Vector2, p0: Vector2, speed: float, body_radius: float, far: Vector2,
		rewards: Array, targets: Array, chargers: Array,
		weapon_range: float, prefers_still: bool, current_hp: float) -> float:

	var v = d * speed
	# Walls do not reject a move, they cancel the component that would cross
	# them -- the engine resolves a blocked step by sliding. Clamping models
	# that exactly, and it matters most when cornered: a bot that is merely
	# penalized for facing a wall will not slide along one to escape.
	var p_end = p0 + v * horizon
	p_end.x = clamp(p_end.x, body_radius, far.x - body_radius)
	p_end.y = clamp(p_end.y, body_radius, far.y - body_radius)
	# THE DODGE SIMULATION MUST USE THE VELOCITY THE WALL PERMITS. p_end is
	# clamped, but the threat pass used to integrate with the raw v -- so a
	# candidate aimed INTO a wall was priced as if it dodged at full speed for
	# the whole horizon, when it actually stops on contact. The bot walked
	# into walls believing it was dodging, and mom collected (87% of her hits
	# at edge < 150, on a bot that thought it was moving). With the effective
	# velocity, into-wall headings lose their phantom dodge value and lateral
	# ones keep full speed, so the swerve along the wall wins the vote by
	# itself. Away from walls v_eff == v exactly; --arb-swerve=0 reverts.
	var v_eff = v
	if wall_swerve != 0.0:
		v_eff = (p_end - p0) / horizon
	var total = 0.0

	var room = room_cap
	var enc_sum = Vector2.ZERO
	var enc_w = 0.0
	var enclose_sq = ENCLOSE_RADIUS * ENCLOSE_RADIUS
	# Crowd runway (see FAR_T): our position FAR_T out along this bearing,
	# wall-clamped like p_end, against the threats extrapolated as far.
	var far_room = ROOM_FAR_CAP
	var far_sq = ROOM_FAR_CAP * ROOM_FAR_CAP
	var p_far = p0 + v_eff * FAR_T
	p_far.x = clamp(p_far.x, body_radius, far.x - body_radius)
	p_far.y = clamp(p_far.y, body_radius, far.y - body_radius)
	var want_far = w_room_far > 0.0 and d != Vector2.ZERO
	# Crowding may be felt further out than enclosure is; scan to whichever
	# reaches further so raising room_cap past ENCLOSE_RADIUS is not a no-op.
	var scan_sq = max(enclose_sq, room_cap * room_cap)

	var trade_sum = 0.0          # standing's pooled cost from killable bodies
	var blast_sum = 0.0          # explode_trade: pooled cost of killable bodies in the blast
	var blast_max = 0.0          # ...and the single largest of them (the hit that detonates)
	var blast_n = 0              # bodies the blast kills
	var hurt_sum = 0.0           # damage dive: pooled cost of bodies the blast only HURTS
	var hurt_max = 0.0
	var hurt_n = 0
	var blast_sq = ENGAGE_BLAST * ENGAGE_BLAST

	for i in range(_p_pos.size()):
		# --- Expected damage: analytic closest approach over the whole path ---
		# t_start defers the threat's motion, which is what makes a charge's
		# wind-up tractable: the dasher is frozen for a known 0.4 s, so the far
		# end of its lane is genuinely safe and we need not give up that ground.
		# The danger window is [t_start, t_end], not [t_start, horizon]. For a
		# pillar those differ by most of its width: it is armed for 0.14 s and
		# the horizon is 0.8 s, so scanning to the horizon charges us for
		# walking over ground that has already gone cold.
		var t_start = _p_start[i]
		var span = _p_end[i] - t_start
		if span > 0.0:
			var w = _p_pos[i] - (p0 + v_eff * t_start)
			var rel = _p_vel[i] - v_eff
			var t = 0.0
			var denom = rel.length_squared()
			if denom > 0.000001:
				t = clamp(-w.dot(rel) / denom, 0.0, span)
			var miss = w + rel * t
			var d2 = miss.length_squared()
			# Squared-distance reject first: most threats are clearly clear, and
			# skipping their sqrt is what pays for the wider action space.
			if d2 < _p_soft[i]:
				var hit = _taper(sqrt(d2), _p_rad[i])
				if hit > 0.0:
					# Floored, not just discounted: a slow bullet can now be scanned
					# out to SCAN_MAX, where the plain linear form would go
					# negative and pay us to stand in front of it. The floor is
					# also what makes this a distance floor rather than a hard
					# cutoff -- a far-off shot stays cheap but never free.
					var when = t_start + t
					var discount = max(1.0 - TIME_DISCOUNT * when / horizon, MIN_DISCOUNT)
					if d == Vector2.ZERO and _p_aimed[i] and aimed_full != 0.0:
						# STANDING against something aimed at us: the discount's
						# premise -- "a later frame can still dodge this" -- is
						# exactly what the stand refuses to do, so the hit is
						# certain and prices at full. Without this a 200 px/s
						# Abyss bullet 300 px out cost a Soldier's stand ~4 against
						# a 16-point floor; both w5 deaths were bullets taken at
						# mv=(0,0) with two seconds of warning.
						discount = 1.0
					# The standing candidate prices killable contact bodies at
					# a discount (see FIRE_STILL_KILL): a stand that SHOOTS the
					# approacher is not the same stand that receives it. Their
					# costs also POOL into the damage-trade budget below rather
					# than summing unbounded -- a whole crowd of killable trash
					# can only bill the stand up to the budget, because most of
					# that crowd will be dead before it collects.
					var cost_i = (_p_still[i] if d == Vector2.ZERO else _p_coef[i]) * hit * discount
					if d == Vector2.ZERO and _fire_still and _p_kill[i] > trade_killable_min:
						trade_sum += cost_i
					elif _explode_trade and _engage > 0.0 and _p_kill[i] >= EXPLODE_KILLABLE_MIN \
							and _p_future[i].distance_squared_to(p_end) < blast_sq:
						blast_sum += cost_i
						blast_n += 1
						if cost_i > blast_max:
							blast_max = cost_i
					elif _damage_dive and _engage > 0.0 and _p_kill[i] > 0.0 \
							and _p_future[i].distance_squared_to(p_end) < blast_sq:
						# a contact body (_p_kill > 0) the blast will not kill
						hurt_sum += cost_i
						hurt_n += 1
						if cost_i > hurt_max:
							hurt_max = cost_i
					else:
						total += cost_i

		# --- Where this leaves us ---
		# One pass serves both terminal terms: the offset to the threat's future
		# position gives crowding, and its direction gives enclosure.
		if _p_mark[i]:
			continue    # a spawn marker takes up no room and blocks no heading
		if want_far:
			var offf = _p_room_far[i] - p_far
			var dff = offf.length_squared()
			if dff < far_sq:
				var edge_far = sqrt(dff) - _p_rad[i]
				if edge_far < far_room:
					far_room = edge_far
		var off = _p_room[i] - p_end
		var off_sq = off.length_squared()
		if off_sq < scan_sq:
			var dist = sqrt(off_sq)
			var edge = dist - _p_rad[i]
			if edge < room:
				room = edge
			if off_sq < enclose_sq and dist > 1.0:
				enc_sum += off / dist    # unit vector without a second sqrt
				enc_w += 1.0

	# Crowding: how much room is there at the end of the move. This one term
	# replaces gap-seeking and the pocket heuristics -- a direction that ends
	# boxed in is expensive whether or not anything is currently aimed at us.
	if room < room_cap:
		var room_cost = w_room * (1.0 - max(room, 0.0) / room_cap)
		if _stand_ok and d == Vector2.ZERO:
			room_cost *= FIRE_STILL_CROWD    # the stand thins the crowd it sits in
		elif _explode_trade and _engage > 0.0:
			room_cost *= EXPLODE_CROWD       # the dive WANTS the crowd it ends in
		total += room_cost
	if want_far and far_room < ROOM_FAR_CAP:
		total += w_room_far * (1.0 - max(far_room, 0.0) / ROOM_FAR_CAP)

	# Enclosure: threats massed on one side leave an escape, threats spread
	# evenly around us do not. The mean unit direction is long when they are
	# all one way and near zero when they surround us -- which is exactly the
	# blindness that made the old field controller need a separate
	# encirclement detector.
	# Walls, per axis. The cost ramps with WALL_POWER rather than linearly: the
	# problem is not being in the outer third of the arena, it is being pinned
	# with nowhere left to give, so the last stretch must cost far more than
	# the approach. Counting both axes makes a corner roughly double a wall.
	var wx = min(p_end.x, far.x - p_end.x)
	var wy = min(p_end.y, far.y - p_end.y)
	if wx < WALL_CAP:
		total += w_wall * 0.5 * pow(1.0 - wx / WALL_CAP, WALL_POWER)
	if wy < WALL_CAP:
		total += w_wall * 0.5 * pow(1.0 - wy / WALL_CAP, WALL_POWER)

	# Predictive wall avoidance: price the bearing's RUNWAY (see const block).
	# Quadratic ramp so a bearing with 2.4 s of room is a whisper and one with
	# 0.5 s shouts; standing still has no bearing and pays nothing here --
	# refusing to move is already priced by the threat terms.
	if w_predict > 0.0 and d != Vector2.ZERO:
		var run_t = _runway(p0, v, body_radius, far)
		if run_t < predict_secs:
			var short = 1.0 - run_t / predict_secs
			total += w_predict * short * short

	# v2.6.0: open-floor potential (see the W_SPACE block). Priced at the END
	# position, quadratic in the wall band but reaching SPACE_CAP so the bot
	# does not drift toward the edge before the wall term can see it.
	if w_space > 0.0:
		var sp_edge = min(wx, wy)
		if sp_edge < SPACE_CAP:
			var sp_short = 1.0 - sp_edge / SPACE_CAP
			total += w_space * sp_short * sp_short

	# Escape ALONG the wall, not off it. Only while the pin-escape mode is
	# active: the radial exit is where the herding swarm stands, the lateral
	# one is usually open, and no other term can tell them apart. Rewards the
	# candidate's component parallel to the NEAREST wall, ramped by proximity
	# measured at the CURRENT position -- the pin is where we are, not where
	# the candidate ends. The wrong tangent sense (into a corner's second
	# wall) is not special-cased: that bearing dead-ends and points into
	# threats, so the surviving terms veto it; this reward just breaks the
	# radial-vs-nothing tie toward lateral motion.
	if _escaping and w_tangent > 0.0 and d != Vector2.ZERO:
		var near_v = min(p0.x, far.x - p0.x)     # nearest vertical wall
		var near_h = min(p0.y, far.y - p0.y)     # nearest horizontal wall
		var near_w = min(near_v, near_h)
		if near_w < TANGENT_RADIUS:
			var along = abs(d.y) if near_v <= near_h else abs(d.x)
			total -= w_tangent * (1.0 - near_w / TANGENT_RADIUS) * along

	if trade_sum > 0.0:
		# The damage trade: killable-crowd contact bills the stand at most this
		# much. Uncapped, ten 90%-killable bodies still summed past any reward
		# and the bot fled forever; capped, the stand pays a bounded fee and the
		# volley thins the crowd that was charging it. Shrinks with the bar.
		total += min(trade_sum, current_hp * trade_share)
	if blast_sum > 0.0:
		# The explosion trade: the pile in the blast costs ONE hit, not N.
		total += min(blast_sum, blast_max)
	if hurt_sum > 0.0:
		# The damage dive: bodies that survive the blast bill at most two hits
		# -- but only when the bar can take them and the blast is worth it.
		var worth = _blast * float(blast_n + hurt_n)
		if _hp_ratio >= DAMAGE_DIVE_HP and worth >= DAMAGE_DIVE_MIN:
			total += min(hurt_sum, hurt_max * DAMAGE_DIVE_HITS)
		else:
			total += hurt_sum

	# A wall is an enclosure the same way a body is: it deletes escape headings.
	# Threats alone cannot express "backed against a wall with the swarm on the
	# open side" -- their directions all point one way, which reads as SAFE by
	# the coherence measure. Feeding the blocked headings in as pseudo-threats
	# is what makes being pinned score as being surrounded, and it is the same
	# trick the old field controller used to stop its gap-seeker being fooled.
	if wx < ENCLOSE_RADIUS or wy < ENCLOSE_RADIUS:
		var walls = [
			[Vector2(-1.0, 0.0), p_end.x], [Vector2(1.0, 0.0), far.x - p_end.x],
			[Vector2(0.0, -1.0), p_end.y], [Vector2(0.0, 1.0), far.y - p_end.y]]
		for wl in walls:
			var wd = wl[1]
			if wd >= ENCLOSE_RADIUS:
				continue
			# A near wall blocks a whole arc, not a single bearing.
			var weight = (1.0 - wd / ENCLOSE_RADIUS) * WALL_ENCLOSE_ARC
			var n = wl[0]
			enc_sum += n * weight + n.rotated(0.7) * weight + n.rotated(-0.7) * weight
			enc_w += 3.0 * weight

	if enc_w >= float(ENCLOSE_MIN):
		var enc_cost = w_enclose * (1.0 - enc_sum.length() / enc_w)
		if _stand_ok and d == Vector2.ZERO:
			# same reasoning as the room share above; ungated this would halve
			# the very term the escape uses to find the open side
			enc_cost *= FIRE_STILL_CROWD
		elif _explode_trade and _engage > 0.0:
			enc_cost *= EXPLODE_CROWD
		total += enc_cost

	# Latent dashes: a charger sitting on a nearly-expired cooldown is a threat
	# that has not been declared yet. It cannot launch at all from outside its
	# range, so the cheapest answer is usually to leave the launch window --
	# which is what the old controller spent three standoff constants encoding.
	if not chargers.empty():
		var inv_hp = 1.0 / max(current_hp, 1.0)
		for c in chargers:
			var ready = c[C_READY]
			if ready >= horizon:
				continue
			var rng = c[C_RANGE]
			if p_end.distance_squared_to(c[C_POS]) > rng * rng:
				continue    # outside its launch range: it never fires at us
			var dmg = c[C_DAMAGE]
			var lethal = 1.0 + lethality * min(dmg * inv_hp, 1.0)
			total += dmg * w_latent * lethal * (1.0 - ready / horizon)

	# --- Opportunity: damage prevented by killing things ---
	# Weapons fire on their own, so the only lever movement has is WHICH things
	# are in range. Each target carries the damage it is expected to do to us if
	# left alive, discounted by how killable it actually is -- so a 4 HP charger
	# outranks an 880 HP boss we will not kill this second, and an egg outranks
	# both because everything it hatches is future damage too.
	# Fight-room gate (see _fight_room): a candidate ending inside the wall
	# band earns neither the kill reward nor the engage pull.
	var fight_ok = true
	if _fight_room > 0.0:
		var end_edge = min(min(p_end.x, far.x - p_end.x), min(p_end.y, far.y - p_end.y))
		fight_ok = end_edge >= _fight_room

	var kill_gain = 0.0
	for t in targets:
		if not fight_ok:
			break
		var dist = p_end.distance_to(t[TG_POS])
		if dist > weapon_range + ACQUIRE_BAND:
			continue
		# Full credit in range, tapering outside it. Without this taper there is
		# no gradient at all toward a fight the bot is not already in.
		var reach = 1.0
		if dist > weapon_range:
			reach = 1.0 - (dist - weapon_range) / ACQUIRE_BAND
		kill_gain += t[TG_VALUE] * reach
	if kill_gain > 0.0:
		# Soft saturation: diminishing returns, but never a flat line, so the
		# term still separates candidates when the screen is full.
		var dps_pay = w_dps * (1.0 - exp(-kill_gain / KILL_SOFT))
		if _fire_still:
			# Soldier's weapons DO NOT FIRE while moving, and pricing a moving
			# candidate as if they did is what made the bot kite itself to
			# death: fleeing "in range" earned the same reward as standing, the
			# scorer saw kiting as free DPS, nothing died, and the wave ground
			# it down. So the payout follows the mechanic -- standing collects
			# double (the kit's +50% damage and +50% attack speed while still),
			# a moving candidate keeps only a sliver, which is not a firing
			# reward at all but the approach gradient: without it, nothing
			# would ever pull the bot into range to take its stand.
			var pay = dps_pay * (FIRE_STILL_STAND if d == Vector2.ZERO else FIRE_STILL_MOVE)
			if d == Vector2.ZERO and _stand_ok and pay < fire_floor:
				# The scaled payout alone measured as no stillness at all
				# (~8-12% still-frames, same as the control): trash waves carry
				# tiny kill_gain, so doubling it yields ~3 -- less than the
				# room term's standing wander pressure, and the bot strolled
				# while its guns were silent. Standing with ANYTHING actually
				# shootable from here (true weapon range, not the acquire
				# band) is worth a flat floor that beats wander and still
				# loses to every live threat.
				var wr_sq = weapon_range * weapon_range
				for t in targets:
					if p_end.distance_squared_to(t[TG_POS]) <= wr_sq:
						pay = fire_floor
						break
			total -= pay
		else:
			total -= dps_pay
			if prefers_still and d == Vector2.ZERO:
				# Structure characters that PREFER standing but whose damage
				# does not stop when they walk: standing is just where their
				# damage term pays out twice.
				total -= dps_pay

	# --- Standoff / kite (v2.3.0, see the W_KITE block) ---
	# Price how close this candidate ENDS to the nearest target. Nothing here
	# pays a bonus for being OUTSIDE the ring: the kill/acquire terms above
	# already pay for being in weapon range, so a pure cost forms a well at
	# kite_r instead of a repulsion field. Damage is what makes a hit matter, so
	# the ring widens with the HP deficit (_kite_r, resolved in choose()). Skip
	# the whole term when _kite_r == 0 (w_kite=0 control, melee builds, or no
	# weapon), which is also why this costs nothing on the control arm.
	if _kite_r > 0.0 and not targets.empty():
		var nd_sq = 1e18
		for t in targets:
			var ksq = p_end.distance_squared_to(t[TG_POS])
			if ksq < nd_sq:
				nd_sq = ksq
		if nd_sq < _kite_r * _kite_r:
			total += w_kite * (1.0 - sqrt(nd_sq) / _kite_r)

	# Standing income (Streamer, see world_view stand_income): the stand earns
	# the tick for the whole horizon; any move forfeits the part of the current
	# second already stood -- the "every twitch resets the tick" rule.
	if _stand_income > 0.0:
		if d == Vector2.ZERO:
			total -= _stand_income * horizon
		elif last_dir == Vector2.ZERO:
			total += _stand_income * (_stand_progress + stand_commit)   # breaking a stand
		else:
			total += _stand_income * _stand_progress

	for r in rewards:
		# Attracted rewards (drops, food) are taken at the attract rim, so the
		# distance that matters is to the rim; a felled reward (tree, r[R_ATTRACTED]
		# false) still has to be reached. A HELD reward (r[R_RIM] = its own rim,
		# e.g. a dead scapegoat's revive zone) pays its value to every move
		# that ENDS inside the rim, so standing in it keeps earning and
		# stepping out costs the same -- that is what makes the bot stay the
		# three seconds a revive takes.
		#
		# v2.5.0 WALK-ON rewards (r[R_WALKON] = 1, world_view's DLC evolution items):
		# the game only collects these when the pickup AREA is stepped over
		# them, and the old 4-tuple path read their rim as "held" -- so the
		# cost happily parked the bot on the rim, paying itself every frame
		# without ever consuming the item (closed-loop sim reproduction).
		# Walk-on is one-shot: keep the closing gradient all the way to the
		# item (rim NOT subtracted from d0/d1, so there is still a gradient
		# inside the rim) and pay `pickup_taken` on the move that crosses the
		# rim. --arb-walk=0 restores the 2.4.0 held reading exactly.
		var is_walk = walk_enable != 0.0 and r.size() > 4 and float(r[R_WALKON]) > 0.0
		var held = not is_walk and r.size() > 3 and float(r[R_RIM]) > 0.0
		var gain = 0.0
		var d1 = 0.0
		if is_walk:
			# one-shot walk-on: raw distances, gradient goes all the way in
			var wrim = float(r[R_RIM])
			var wd0 = p0.distance_to(r[R_POS])
			d1 = p_end.distance_to(r[R_POS])
			var wclosed = (wd0 - d1) / max(speed * horizon, 1.0)
			gain = w_pickup * r[R_VALUE] * wclosed \
					/ (1.0 + max(wd0 - wrim, 0.0) / PICKUP_FALLOFF)
			if d1 <= wrim and wd0 > wrim:
				gain += w_pickup * r[R_VALUE] * pickup_taken       # stepped onto the item
		else:
			var rim = float(r[R_RIM]) if held \
					else (_pickup_radius if (r.size() < 3 or r[R_ATTRACTED]) else 0.0)
			var d0 = max(p0.distance_to(r[R_POS]) - rim, 0.0)
			d1 = max(p_end.distance_to(r[R_POS]) - rim, 0.0)
			var closed = (d0 - d1) / max(speed * horizon, 1.0)   # -1..1, share of the move spent approaching
			gain = w_pickup * r[R_VALUE] * closed / (1.0 + d0 / PICKUP_FALLOFF)
			if held:
				if d1 == 0.0:
					gain += w_pickup * r[R_VALUE]                  # inside the zone: keep earning
			elif d1 == 0.0 and d0 > 0.0:
				gain += w_pickup * r[R_VALUE] * pickup_taken       # this move collects it
		# v2.10.0: reward attraction is an objective pull too -- while a body is
		# inside its taper band the pull is damped (see PULL_SAFE) and the
		# contact/crowding terms decide the heading; otherwise the economy
		# layer's (now deadline-correct) value would still drag the bot through
		# the body with the no-commitment path (probe Q).
		total -= gain * _pull_scale

	# -- v2.5.0: committed item goal pull (see the GOAL_* block) --
	# A persistent, ETA-scaled pull toward the reward chosen in choose().
	# It exists because the per-step reward above only sees one 0.8 s hop:
	# an item two seconds away never wins a frame against a single body, so
	# without a commitment the bot only ever collects loot it passes. The
	# weight is deliberately in the same HP unit and modest (max ~15 at a
	# 9-value item) so a live lane still vetoes the detour.
	if _goal_on and d != Vector2.ZERO:
		var gd0 = p0.distance_to(_goal_pos)
		var gd1 = p_end.distance_to(_goal_pos)
		var gclosed = clamp((gd0 - gd1) / max(speed * horizon, 1.0), -1.0, 1.0)
		# v2.7.0: the unified planner scales the committed pull by the reward's
		# value (opp=0 keeps the exact v2.6.1 weight, _opp_on is false then).
		var gscale = _opp_goal_scale if _opp_on else 1.0
		total -= w_goal * _goal_frac * gscale * _pull_scale * gclosed / (1.0 + gd0 / GOAL_FALLOFF)

	# -- v2.6.0: bounty approach pull (see the BOUNTY_* block) --
	# Direction-alignment reward toward the special target, ramped by how far
	# outside firing range we still are, so it stops pulling the moment the
	# normal target/DPS terms can take over. No threat terms are discounted:
	# the acquisition gate is what keeps this a calm-neighbourhood decision.
	if _bounty_on and d != Vector2.ZERO:
		var bv = _bounty_pos - p0
		var bd = bv.length()
		if bd > 1.0:
			var align = d.dot(bv / bd)
			var ramp = clamp((bd - _bounty_desired) / 320.0, 0.0, 1.0)
			# v2.7.0: value-scaled pull for the unified planner; opp=0 keeps
			# the exact v2.6.1 BOUNTY_PULL constant (_opp_on is false then).
			var bpull = _opp_pull if _opp_on else BOUNTY_PULL
			total -= bpull * _pull_scale * align * ramp

	# --- Character anchor ---
	# Priced at the candidate's END position. Between the two radii every
	# candidate scores the same zero and the anchor exerts no force at all,
	# which is what keeps dodging free inside the band; outside it, the
	# candidate that ends nearer the band is linearly cheaper.
	if _anchor_on:
		var from_anchor = p_end.distance_to(_anchor)
		if _anchor_radius > 0.0:
			var strayed = from_anchor - _anchor_radius
			if strayed > 0.0:
				total += _anchor_w * min(strayed / ANCHOR_NORM, ANCHOR_CAP)
		if _anchor_inner > 0.0:
			var intruded = _anchor_inner - from_anchor
			if intruded > 0.0:
				total += _anchor_w * min(intruded / ANCHOR_NORM, ANCHOR_CAP)
		# Orbit (see _orbit_w): direction pricing while outside the band
		if _orbit_w > 0.0 and _orbit_from > 0.0 and d != Vector2.ZERO:
			var radial = p0 - _anchor
			var dist = radial.length()
			var out_frac = clamp((dist - _orbit_from) / ANCHOR_NORM, 0.0, 1.0)
			if out_frac > 0.0 and dist > 1.0:
				var ru = radial / dist
				var outward = d.dot(ru)                      # +1 straight away from home
				var along = abs(d.dot(Vector2(-ru.y, ru.x)))  # kiting around it
				total += _orbit_w * out_frac * (outward - 0.5 * along)

	# --- Contact seeking ---
	# Cost for ENDING far from the nearest thing worth touching, which makes
	# closing the distance the cheaper candidate. Capped, so one straggler
	# across the arena cannot drag the bot through everything in between.
	if _engage > 0.0 and fight_ok and not targets.empty():
		var near_sq = 1e18
		var in_blast = 0    # blast_sq is declared at the top of the threat loop
		for t in targets:
			if _engage_cluster and t.size() > TG_BOSS and t[TG_BOSS]:
				continue    # a boss is never part of the pile worth diving into
			var dsq = p_end.distance_squared_to(t[TG_POS])
			if dsq < near_sq:
				near_sq = dsq
			if dsq < blast_sq:
				in_blast += 1
		if _engage_cluster:
			# Reward PER BODY inside the blast at the END position (see
			# ENGAGE_CLUSTER_CAP), plus a reduced pull toward the nearest body
			# so a pile can get started.
			total -= _engage * min(float(in_blast), ENGAGE_CLUSTER_CAP)
			if near_sq < 1e17:
				total += _engage * cluster_near * min(sqrt(near_sq) / ENGAGE_NORM, ENGAGE_CAP)
		else:
			total += _engage * min(sqrt(near_sq) / ENGAGE_NORM, ENGAGE_CAP)

	# --- Standing still as a mechanical penalty ---
	if _never_still and d == Vector2.ZERO:
		total += NEVER_STILL_COST

	# -- v2.5.0: breakout commitment (see the BREAKOUT_* block) --
	# A pure direction reward in the same HP unit: the mode has already
	# decided WHICH line leaves the ring (pursuit rollout), and this is what
	# makes every frame vote for it instead of re-litigating the same
	# least-bad local move. Contact bodies are simultaneously discounted in
	# choose(); bullets, dashes and telegraphs are not, which is what keeps
	# the escape a run-through and not a tank.
	if _breakout_active and d != Vector2.ZERO:
		var pull = BREAKOUT_CORNER_PULL if _breakout_reason == "corner" else BREAKOUT_PULL
		total -= pull * d.dot(_breakout_dir)

	# --- Continuity ---
	# One hysteresis term in the arbiter does the job that five separate commit
	# timers did in the field controller, and it cannot deadlock: a threat that
	# actually appears outscores the bonus immediately.
	if last_dir != Vector2.ZERO and d != Vector2.ZERO:
		var agree = d.dot(last_dir)
		total -= w_hyst * agree
		if agree < -0.5:
			total += W_REVERSE * (-agree)
	elif last_dir == Vector2.ZERO and d == Vector2.ZERO:
		# Stillness is a HEADING and gets the same stickiness as any other, or it
		# is the one choice the bot can flicker out of for free. That flicker is
		# not cosmetic: Streamer's income needs a full unbroken second standing
		# and every twitch resets the tick, while Soldier and Engineer lose a
		# firing window to a step they had no reason to take.
		total -= w_hyst
	elif prefers_still and last_dir != Vector2.ZERO and d == Vector2.ZERO:
		# The other half of tap-moving. Mid-dodge, the hysteresis reward above
		# hands every keep-going candidate ~w_hyst that STOPPING does not get, so
		# a stand-still character pays a tax on the very move its kit is built
		# around -- the dodge stretches a body-length past where the threat
		# cleared, and Soldier spends that distance not firing. Pricing the stop
		# level with continuing lets the tap end the instant the threat term no
		# longer demands motion; while one does, 15-65 beats 1.2 regardless.
		total -= w_hyst

	return total


# 1.0 inside contact, tapering smoothly to 0 at radii * HIT_MARGIN. The taper
# is what gives the argmax a gradient: without it every clear direction ties
# and the choice is decided by noise.
func _taper(dist: float, radii: float) -> float:
	if dist <= radii:
		return 1.0
	var soft = radii * HIT_MARGIN
	if dist >= soft:
		return 0.0
	var x = 1.0 - (dist - radii) / (soft - radii)
	return x * x * (3.0 - 2.0 * x)
