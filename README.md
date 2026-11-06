# AutoBattler · Brotato 自动走位 Mod

**操作交给 AI，决策留给你。** 波次内自动走位/闪避/砍树/吃果子/捡材料，商店、升级、开箱、下一波全部手动。

*Auto-move and dodge during waves. Every build decision stays yours.*

![preview](workshop/preview.png)

[![release](https://img.shields.io/github/v/release/Shuumatsu/auto-brotato?label=release)](https://github.com/Shuumatsu/auto-brotato/releases/latest)
[![license](https://img.shields.io/badge/license-MIT-blue)](mod/LICENSE)
[![Brotato](https://img.shields.io/badge/Brotato-1.2.0.1-4caf50)](https://store.steampowered.com/app/1942280/Brotato/)
[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-1b2838)](https://steamcommunity.com/sharedfiles/filedetails/?id=3834096920)

## 它做什么

- ✅ 自动躲子弹、冲锋、AOE 预警；静场自动砍树、受伤后去吃果子、顺手捡材料
- ✅ **高价值目标全覆盖 + 实时攻击 CD 同步（v2.8.0，第五轮试玩反馈）**：Boss/精英分开定价（50/30），物品箱/传奇箱/进化物品/掉落怪/树按显式价值表进入机会层（20/34/20/12/7）；fire_still 角色的 tap-move 改成“有武器 ready 才停 1 帧”的实时 CD 同步，走位速度与开火节奏同时改善。`--arb-cov` / `--arb-tapcd`（`=0` 精确 v2.7.0）；`--arb-dpsref=2` 为实验性 killability 候选
- ✅ **统一机会规划（v2.7.0，第四轮试玩反馈）**：特殊目标/产出不再被“安全窗 + 距离衰减”层层关掉——Boss/精英、生成器蛋、诅咒/进化怪与普通怪分离定价，按“价值 − 路线风险”决定值不值得去；远处特殊目标可见半径扩到 900/1400/1600px（按 `--arb-agg`），逃跑掉落怪按实测速度拦截。`--arb-opp` 总开关（`=0` 精确 v2.6.1）、`--arb-agg` 风险档
- ✅ **贴身/碰撞修复（v2.6.1，第三轮试玩反馈）**：不再“场上没几只怪却贴着怪打转”——修复追击者在拥挤项里被按直线速度“穿身投影”的问题；同时给蓄力前的定身怪补上接触价，并让接触距离不再低估精英/Boss/DLC 非圆形碰撞体
- ✅ **规划能力（v2.5.0）**：**合围前主动突围** + **高价值物品目标承诺**（DLC 进化果/受伤果子/树），并修好“走到进化物品旁却不捡”的拾取语义
- ✅ **空间规划 / 特殊目标（v2.6.0）**：不再被一点点挤到地图边缘（贴墙带提前撤离 + open-floor 势场）；会主动去处理特殊目标（精英/Boss、生成器蛋、诅咒/进化怪）和特殊产出（物品箱、掉落怪）
- ✅ **DLC 适配（v2.4.0）**：默认主动交战诅咒怪（DLC1）与机械/异变进化怪（DLC2），主动踩进化物品
- ✅ 远程 build 保持射程边缘风筝，不再贴脸（v2.3.0）
- ✅ 每帧不只贪心一步：2 步前瞻规划 + 受击后临时提高警戒（v2.3.0）
- ✅ 从实时 build 数据推导角色行为，不需要逐角色手写表
- ✅ 默认开启，`Shift + Space` 随时接管；HUD 显示状态
- ✅ 只装 2 个最小扩展：**不会替你买、刷、锁、升级、开箱、点下一波**
- ✅ 单人 Brotato 1.2.0.1 实机验证

### v2.9.0 经济目标层 + 结构性重构（review-v3，第六轮）

这一版把“走路目标”从“生存成本最小化 + 资源弱正则”改为**按获取途径定价的经济目标**，并做了一轮证据驱动的结构重构（详见 [docs/REVIEW-v3.md](docs/REVIEW-v3.md)）。

| 问题 | 修复 |
|---|---|
| 经济项只是生存打分的 tie-breaker，且准入是“附近有怪就一票否决”的硬闸门 | **统一经济规划器**（`--arb-econ`，默认开）：每个资源按获取途径分类——`AUTO_AT_HORN`（金币/普通果子/物品箱/变异果/机械部件：**波末自动吸取本来就会付钱**，波内绕路只在有 pickup 触发效果时才有价值）、`LOST_AT_HORN`（机械果/异变果/Veteran 的果子：不捡就永远失去，全值 + 波末 deadline）、`MID_WAVE_ONLY`（临时 stat/衰减 buff/吃果爆炸：**波末吸取不触发**，只能波内主动吃）、`TREE`（未倒的树波末被销毁且不掉落 → 期望收益 + 波末紧迫）与特殊目标（沿用 v2.7 价值表）。风险准入从二元闸门改为**连续风险预算** `score = value − risk_weight(hp)·route_risk − eta_cost`（HP 越低风险权重越高，保留硬 HP 地板）。资源视野从 900px 扩到全图（最多 60 个候选）。 |
| 满血果子被定价为 **-0.8（负成本主动回避）**；受伤果子按 `2.5×min(12,missing)` 定价，比真实治疗高约 10x；Vampire 等负治疗 build 被赋予幽灵治疗价值 | 治疗改为游戏真实公式 `max(0, 3 + consumable_heal)` 并 clamp 到 missing HP；Vampire(-100)/Golem(no_heal) 不再有幽灵治疗；满血永久 stat（Farmer/Glutton/Extra Stomach）改为“**提前 1 波**”的小正值（波末吸取同样触发，故不做高价值绕路）；Penguin（临时 regen）/Cauldron（衰减 buff）/Chef·Glutton·Spicy（吃果爆炸）等 **mid-wave-only** 效果给波内正值；Druid 的 `stats_on_fruit` 33% luck roll、金币 pickup 触发（Lucky/Baby Elephant 伤害、Buccaneer/Blunderbuss 装填、Cute Monkey 治疗、Metal Detector 翻倍、材料增值、Bag 箱金、武器级装填）纳入定价。 |
| 物品箱/传奇箱被当成“一个 item choice”做波内绕路 | 箱子的 item choice 在**波末自动吸取时同样结算**，波内绕路不增加资源；波内价值只剩即时治疗（普通箱 3 / 传奇箱 100，受伤时是救命价值）与 Bag 的箱金。 |
| 树在波末会真正损失却没有紧迫性 | 树价值 = 3 materials（受 `gold_drops` 修正）+ 期望消耗品（80% 果/20% 箱）+ 树机制（Explorer/Survivor 的 `trees`、`one_shot_trees`/`tree_turrets`），波末按 ETA 提升；Cryptid 的活树每棵波末 +12 materials → 砍树定价为负、不去砍。 |
| 两个 3k 行单体、tuple 契约靠魔数、`--arb-*` 分散解析、旧势场控制器残骸 | `steering/contract.gd` 单一 tuple/枚举契约（`R_POS..R_TAG`、special class、econ flags）；`steering/config.gd` 唯一 `--arb-*` 解析器（96 key；旧 `--arb-sweep`/`--arb-orbit` 语义保留，新增 `--arb-bladeunion/--arb-sweepmat/--arb-orbitscan/--arb-orbitw` 细分）；新增 `steering/economy.gd`（纯定价）与 `steering/econ_planner.gd`（纯规划）；`player_movement_behavior.gd` 356→123 行（删除 85 个死 const/31 个死 var 与旧力场 telemetry）。`--arb-econ=0` = **精确 v2.8.0** 控制臂（不写新 tuple 字段、不走新规划器）。 |

> v2.9.0 新增开关：`--arb-econ`（默认 1；0 = 精确 v2.8.0）。经济调参键（默认即游戏数据推导值）：`--arb-econhpfloor/--arb-econrisk/--arb-econriskhp/--arb-econmarg/--arb-econeta/--arb-econdeadline/--arb-econboost/--arb-econcap/--arb-econsweep/--arb-econrange/--arb-econcands/--arb-econxp`。完整控制臂列表见 [docs/TECHNICAL.md](docs/TECHNICAL.md)。
>
> 验证：离线验收体系已迁移到 **tracked `tests/`**（`GODOT_BIN=... bash tests/run_all.sh`，clean clone 可复现）：解析门禁（mod 全部 .gd）+ planner 470/0 + falsifier 2476/0 + gate 32/0 + world_view 固定参考 32/0 + 闭环 sim 74 条断言。经济层：`--arb-econ=0` 控制臂与冻结 v2.8.0 的 tuple/profile/方向逐值等价（5 场景），`--arb-econ=1` 的方向由游戏数据期望表 46/46 条断言覆盖（18 builds × 6 类中可离线执行部分）；**tracked `tests/econ`（闭环经济 sim）与真机 A/B 仍待补**（宿主资源耗尽中断了闭环验证；v2.5+ 默认值均无真机校准数据，详见 REVIEW-v3 的剩余风险）。

### v2.8.0 高价值目标全覆盖 + 实时攻击 CD 同步（第五轮试玩反馈）

| 问题 | 修复 |
|---|---|
| 高价值目标“覆盖不全” | v2.7 只给特殊**怪物**建了价值表，**产出**仍是旧“顺路价”，而且 Boss 和精英共用一个 class（都是 30）。v2.8 **覆盖层**（`--arb-cov`）：Boss = class 1 **50**、精英 = class 4 **30**（× `--arb-bounty`），生成器蛋 40、诅咒/进化 18 不变；产出按显式价值表进机会层——普通物品箱 **20**、传奇箱 **34**、进化消耗品 **20**、掉落怪 **12**、树 **7**，统一 `max(原价值, 表值)`，拉力随价值缩放。治疗果子保留 raw food 价值；毒果/复活圈/金币有意排除；`--arb-opp=0` 时 reward 元组逐字节不变。 |
| fire_still（移动不能开火）角色走位与输出节奏不够好 | **实时攻击 CD 同步**（`--arb-tapcd`）：v2.7 是固定“走 2 帧/停 2 帧”，完全不看武器状态；现在 world_view 暴露 `fire_wait_frames`（当前武器 `_current_cooldown` 最小值），movement behavior 只在**有武器 ready 的那一帧**停 1 帧——游戏在 movement==ZERO 的第一帧发射所有 ready 武器、站桩 +50% 加成同帧生效——其余时间正常走。无武器/旧 loadout/hop/脱困时回退旧节拍。预期同时提高移动速度与 DPS。 |
| killability 用旧 `weapon.stats` 估算，对成长型 build 偏低（opt-in） | **`--arb-dpsref=2`**：用 `weapon.current_stats`（含攻速/%伤害/多发/射程后的真实 stats）估 `damage×nproj×60/cooldown`；`0` = 静态参考、`1` = 现状。因暂无真机 A/B，**默认仍为 1**，仅作为已实现的对照候选。 |

> v2.8.0 新增 2 个开关（默认开）：`--arb-cov`（高价值覆盖层；`0` = **精确 v2.7.0** 价值/class 语义）与 `--arb-tapcd`（实时 CD 同步 tap；`0` = **精确 v2.7.0** 固定 2 走/2 停）。**15 个开关全 0 = v2.4.0 精确行为**（13 + `--arb-cov=0 --arb-tapcd=0`）；**精确 v2.7.0 = `--arb-cov=0 --arb-tapcd=0`**；**精确 v2.6.1 = `--arb-opp=0 --arb-cov=0 --arb-tapcd=0`**（`tapcd` 是 movement 层开关，与机会层独立）；`--arb-dpsref` 默认 1（`0` = 静态参考 / `2` = `current_stats` 实验档）。完整控制臂列表与逐项回退见 [docs/TECHNICAL.md §三](docs/TECHNICAL.md)。
>
> 离线验收：`check_gd` **3 个真源文件 PASS**（movement behavior 已加入解析门禁）；`planner-selftest` **470/0 PASS**（+独立 falsifier 2476/0）；离线门禁 **32/0 PASS**（新增 G1：tag 传奇箱 1.65s 拾取 / `item_min` 26.6px，`cov=0`/control/no-tag 仍 0 拾取；F1 185.6px/1.67s 不退化；E2c `last_opp_value==50`）；Lead 单帧探针 **32/32（world_view）+ 26/26（arbiter）PASS**（覆盖值/class/tag/`fire_wait_frames`/dpsref）；闭环 sim 14 场景无退化（`opp_v34_tagged` 3.6s→2.9s）。基线 v2.7.0：`planner-selftest` 355/0、门禁 27/0。真机 A/B 待跑。

### v2.7.0 统一机会规划（第四轮试玩反馈）

| 问题 | 修复 |
|---|---|
| 特殊目标/特殊产出“看到了也不去” | v2.6 的机会层被**四道栅栏**层层关掉：(A) world_view 只发 `weapon_range+220px` 内（典型 620–680px）的 target，`--arb-bounty` 承诺的 900px 根本收不到；(B) 二元安全门（附近 300/320px 内有身体就一票否决，且方向无关）在真实波次里几乎一直关着机会层；(C) 拉力太小且随距离衰减，争不过一只怪 10–40 的接触价；(D) 特殊目标沿用可杀性定价，厚血 Boss/精英折减后可能比杂兵还“不值钱”。v2.7 把 (B)(C)(D) 换成一个**价值 − 路线风险**规划器：显式价值表（Boss/精英 30、生成器蛋 40、诅咒/进化 18，× `--arb-bounty`）；用同一套威胁模型沿直线路线估算期望伤害，`allowed = value×(0.10+0.20×agg)+2×agg` 内才承诺；目标拉力按价值放大到 14–34。 |
| 远处的特殊目标“看不见” | world_view 对 special（Boss/精英、生成器蛋、诅咒/进化）单独放可视半径：`--arb-agg` 0/1/2 → 900/1400/1600px，只取最近 8 个；普通 target 的旧可见半径不变，`--arb-opp=0` 时 targets/threats/rewards 与 v2.6.1 逐字节一致。 |
| 承诺/靠近不够“敢” | 承诺 100 帧（60fps 下约 1.67s）；HP 地板 0.55/0.35/0.20（agg 0/1/2），承诺中低于地板×0.7 才放弃，目标消失/到达也释放（15 帧冷却）；新增“分段速度 close-in”候选，接近时不因全速过冲而停在射程外；reward 拉力按价值 ×1–2。 |
| 逃跑的掉落怪（loot alien）追不上 | world_view 记录每只掉落怪的实测速度，作为 reward 第 6 字段（旧代码只读前 2 项，`opp=0` 时仍发旧元组）；默认价值 8；arbiter 做 2 次不动点拦截瞄准（预测点速度按自身 95% 封顶），从“追尾”变成“抄近路”。 |

> v2.7.0 新增 2 个开关（默认开）：`--arb-opp`（统一机会层总开关；`=0` **精确回到 v2.6.1**：旧 `_update_goal`/`_update_bounty`、旧拉力、无 target close-in）与 `--arb-agg`（风险档 `0` 保守 / `1` 默认 / `2` 激进；只在 `opp=1` 时有意义）。**13 个开关全 0 = v2.4.0 精确行为**：v2.5 的 5 个 + v2.6 的 3 个 + v2.6.1 的 3 个 + v2.7 的 2 个；完整控制臂：`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0 --arb-space=0 --arb-bounty=0 --arb-boxes=0 --arb-roomtrack=0 --arb-windup=0 --arb-hitbox=0 --arb-opp=0 --arb-agg=0`（`agg` 在 `opp=0` 下不生效，写 0 只为完整列出）。（v2.7.0 之前各段写的“v2.4.0 控制臂”，在 v2.7 下还需要再加 `--arb-opp=0`；v2.8.0 起完整控制臂为 **15 个开关**，另需 `--arb-cov=0 --arb-tapcd=0`，见上。）
>
> 离线验收：`planner-selftest` → **355 checks / 0 fails**（含 38 条 `opp=0` 与冻结 v2.6.1 逐值一致断言）；离线门禁 → **27 checks / 0 fails**（F1：默认臂 1.67s 进入 274px 射程边缘、target_min 185.2px，agg=0/control 停在 800px；F2 合围下默认臂存活/血量不退化；E2b 必死路线不承诺、E2c 侧身怪允许承诺）；闭环 sim：特殊目标遮挡 S1/S2 分别在 1.77/1.78s 进入射程，逃跑掉落怪拦截 **11.3s → 2.8s（4.04×）**；真机 A/B 待跑。

### v2.6.1 贴身/碰撞修复（第三轮试玩反馈）

| 问题 | 修复 |
|---|---|
| 有时候场上只有一只怪，bot 却贴着它打转、反复吃接触伤害（简单局面里最明显） | **拥挤项改追击投影**：`room` / `roomfar` 原来用敌人**当前速度直线外推**；一个朝你冲的怪若比 horizon 距离还近，就会被投影“穿过你跑到身后”，于是“往远处跑”反而被算成更拥挤、“绕圈/迎面穿过”反而更空——成了稳定的贴身轨道。现在对**比自己慢、确实能甩掉**的这类追击者按**“追着你、到接触距离为止”**投影（和第二层追击预测同一个 cap），逃开才真正变便宜；比玩家快的怪物保持 2.6.0 行为（本来就甩不掉，避免慢速角色人群局回归）。`--arb-roomtrack=0` 精确回到 2.6.0 |
| 蓄力（wind-up）中的定身怪可以随便穿过去 | 蓄力时敌人只以“未来冲锋走廊”形式计价，走廊从起冲才开始；那 0.3–0.5s 定身期间身体有接触伤害却不计威胁（20px 处穿过定价 0.00，普通行走怪 17.42）。现在把定身身体按一次性接触威胁补上，起冲瞬间失效、交给走廊。`--arb-windup=0` 回退 |
| 精英/Boss/DLC 大体型怪的接触距离被低估 | 接触伤害实际由敌人 **Hitbox** 判定，而计价一直用（通常更大的）Hurtbox 半径；普通小怪因此偏保守没问题，但精英/Boss 和 DLC2 腕龙（brachiosaurus）（胶囊形 Hitbox：真实 148–212px vs 模型 41px）会被低估，存在一条“零接触价”的贴近带。圆形碰撞体取 Hurtbox/Hitbox 较大者；非圆形 Hitbox（如腕龙胶囊）改用保守外接圆（约 234px，仍比真实最大 212px 保守），带偏移/缩放一并计入，**只会提前避让、不会更晚**。`--arb-hitbox=0` 回退 |

> v2.6.1 新增 3 个开关（`--arb-roomtrack` / `--arb-windup` / `--arb-hitbox`，默认全开）；三个全 0 + v2.6/v2.5 全部开关 0 = v2.4.0 精确行为（A/B 控制臂，闭环逐帧一致）。

### v2.6.0 空间规划 / 特殊目标

| 问题 | 修复 |
|---|---|
| 久战会被一点点挤到地图边缘、丧失走位空间 | **贴墙带撤离**：靠近墙（<150px）且 4 只以上敌人贴身时，复用 1.6s 追击 rollout 选“回开阔地”的路线并承诺撤离（不通过人群硬挤）；另有 **open-floor 势场**（380px 内轻微向开阔地收）防止从场地中央被“每一步都局部正确”地挤到边上。`--arb-breakout=0` / `--arb-space=0` 可分别回退 |
| 不主动打特殊怪物（精英/Boss、生成器蛋、诅咒/进化怪） | **赏金目标**：安全窗口内（附近 300px 无身体接触）把 900px 内的特殊目标纳入“-arb-bounty”承诺接近，进入射程后交给正常开火/风筝逻辑；靠太近、血太低或目标消失会放弃。`--arb-bounty=0` 回退 |
| 不捡特殊产出（物品箱/掉落怪） | 物品箱按“一个物品选择”定价（普通 5 / 传说 10，不再只按回血 3 点）；逃跑掉落怪价值 4→6 且纳入目标承诺。`--arb-boxes=0` / `--arb-bounty=0` 回退 |

> v2.6 新增 2 个开关；与 v2.5 的 5 个开关一起全 0 时 = v2.4.0 精确行为（A/B 控制臂）。

### v2.5.0 规划能力（合围前突围 / 高价值物品）

| 问题 | 修复 |
|---|---|
| 肉眼看到“马上要被包围”，bot 不提前规划 | **预判突围**：把追击者投影到 1.8s 后，算“现在还能过人、1.8s 后缺口就没了”的合围前兆；进入突围模式后用 16 方向 × 1.6s 追击 rollout 选逃逸线并承诺跑出去（接触价打折，子弹/冲锋/AOE 仍全价）。`--arb-breakout=0` 精确回退 |
| 不会规划去捡高价值物品 | **目标承诺**：安全窗口内按 `价值/ETA` 选目标（进化物品/受伤果子/树）并持续拉过去，而不是只吃路过的；`--arb-goal=0` 回退 |
| 走到进化物品旁却不捡 | **walk-on 拾取语义修复**：v2.4 的 45px rim 被当成“held 复活圈”（站圈里刷分、不消费），现在按一次性拾取；另加“落在目标上的分段速度”候选，修掉最后一个 horizon 步内全速过冲→停住的问题。`--arb-walk=0` 回退 |
| 波末的进化果来不及捡 | meca/mutant fruit 波末不会自动吸走，world_view 现在按剩余波时给价值乘 1→4 的紧迫度；`--arb-waveend=0` 回退 |
| 2 步前瞻按直线外推追击者 | 第二层改为**追击预测**（朝第一动作终点转向）；`--arb-pursuit=0` 回退 |

> 五个开关全 0（`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0`）= v2.4.0 精确行为，方便 A/B 与回退。

### v2.4.0 DLC 适配（诅咒怪 / 进化物品）

| 问题 | 修复 |
|---|---|
| 遇到诅咒怪（DLC1）只风筝不打 | 被诅咒敌人默认 **×3 目标价值**（更愿意把它保持在武器射程内打掉），可调：`--arb-curse=3`；需要避开时用负数（`--arb-curse=-1` → 不主动靠近、威胁伤害 ×2） |
| 不打机械/异变进化怪（DLC2），拿不到它们的进化掉落 | 进化敌人默认 ×2.5 目标价值；`--arb-evolved=2.5`，负数同样进入回避姿态 |
| 进化物品（机械果实/异变果/异变基因/机械部件）躺在原地不捡 | 按 DLC 进度定价并**走到物品上**拾取（这些消耗品不会被吸引圈收走）；只捡当前进化方向可用、且游戏允许拾取的；`--arb-evo=1.0` 缩放价值，`0` 精确回到 2.3.0 |
| 未知/毒果等非治疗消耗品被当成食物 | 非治疗消耗品不再按“掉血治疗”定价（毒果不会再被主动吃）；治疗类（普通果实/物品箱）行为不变 |

> 三个开关同时为 0（`--arb-curse=0 --arb-evolved=0 --arb-evo=0`）时与 2.3.0 行为逐值一致，便于 A/B 回退。

### v2.3.0 策略升级

| 问题 | 修复 |
|---|---|
| 远程英雄老是贴脸 | 新增 standoff 项：把敌人保持在射程的 75%（掉血时更远），旧行为可用 `--arb-kite=0` 精确回退 |
| 不砍树 / 不吃果子 | 普通 role 也给树一个静场价值；受伤时果子价值 ×2.5（`--arb-tree=0` / `--arb-food=0` 回退） |
| 单步贪心不够聪明 | `choose()` 增加 2 步前瞻（beam 4 × 8 方向），用同一套威胁模型/代价函数；`--arb-plan=0` 精确回退 |
| 受击后反应迟钝 | 单次掉血 ≥12% 触发 2 秒警戒期（威胁权重 +25%）；`--arb-adapt=0` 回退 |

> 一句话：从“操作员”变成“指挥官”。

## 安装

- **Steam Workshop（推荐）**：[订阅这里](https://steamcommunity.com/sharedfiles/filedetails/?id=3834096920)
- **GitHub / 本地版**：从 [Releases](https://github.com/Shuumatsu/auto-brotato/releases) 下载**单个 zip**；
  它已经包含 Mod 本体 + 预览图 + Workshop 描述，Steam 版放进已订阅的工坊 item 目录即可，
  步骤见 [安装文档](docs/TECHNICAL.md)。

## 操作

| 场景 | 行为 |
|---|---|
| 波次中 | 不操作即可，角色自动走位 |
| `Shift + Space` | 关闭 / 恢复自动走位 |
| 升级三选一、商店、开箱、下一波 | 完全手动 |

## 开发 / 发布

```bash
./build.sh          # 开发用 Mod zip: dist/AutoBattler-<version>-fork.zip
./build_release.sh  # 发布用单文件整包: dist/AutoBattler-v<version>.zip
```

- 自动 benchmark / 参数标定：[calibration/README.md](calibration/README.md)
- GitHub Actions 构建与 Release：push `vX.Y.Z` tag 自动发布
- 详细原理、适配机制、验证记录、CI/CD：[docs/TECHNICAL.md](docs/TECHNICAL.md)

## 致谢

走位 AI 来自开源项目 [BOTato](https://github.com/boardengineer/botato)（by boardengineer / Pasha，MIT License，见 [mod/LICENSE](mod/LICENSE)）。
本仓库只做瘦身、默认开启、配置/HUD、自动 profile 与打包。
