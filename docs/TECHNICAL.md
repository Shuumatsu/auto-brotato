> 本文是详细技术文档（原理/安装细节/验证记录/开发与 CI）。项目主页请见 [../README.md](../README.md)。

# Brotato 自动走位 Mod：操作交给 AI，决策留给你

给 **Brotato（土豆兄弟）** 的本地 Mod：**波次内自动走位、自动闪避、自动捡材料**，但**所有决策仍然由你来做**——

- 升级三选一
- 商店购买 / 刷新 / 锁定 / 卖出
- 开箱、消耗品 take/discard
- 点"下一波"继续
- 角色 / 武器 / 初始武器 / 难度选择

这些界面**一个都没有被改动**（这个 fork 从代码层面就没有装任何自动决策扩展）。你仍然掌控 build，AI 只负责让你活着。

> 一句话：从"操作员"变成"指挥官"。你按暂停做 build 决策，AI 负责走位。

---

## 一、方案对比：为什么是现在这个做法

Brotato 的玩法决定了自动操作其实**只需要接管移动**：武器会自动瞄准开火，材料靠走近拾取，玩家唯一的持续输入就是移动。所以问题不是"写一个完整 AI 玩家"，而是"把移动输入换成 AI 决策"。

| 方案 | 做法 | 自动程度 | 决策是否保留 | 工作量 / 风险 | 评价 |
|---|---|---|---|---|---|
| **A. 现成 BOTato** | 订阅/安装开源自动战斗 Mod（MIT，作者 boardengineer/Pasha） | 走位 + 可选自动商店/自动升级 | 可保留，但依赖配置（autoshop 一旦打开会连锁自动升级/开箱/购买/GO） | 低 | 上游创意工坊页面已被下架；且其"只走位"完全依赖一个布尔配置，不是结构保证 |
| **B. 本仓库：BOTato 走位核心瘦身 fork（已实现）** | 复用 BOTato 的 MIT 走位 AI（Arbiter/WorldView），只保留 **2 个**最小扩展 | 仅走位 | ✅ 结构保证（自动决策代码已物理删除） | 中低 | 装完即用、无额外依赖、决策界面零改动、可一键卸载 |
| **C. 从零写一个走位 AI** | 自己 hook 移动，写"危险场 + 吸引场 + 避弹"评分 | 仅走位 | ✅ | 高 | 前期能走，后期弹幕/冲锋怪/精英怪会迅速暴毙；BOTato steering 是长期 telemetry 调出来的，重写不划算 |
| **D. 外部屏幕识别 + 模拟输入** | Python 截屏 + OpenCV + 模拟输入 | 仅走位 | ✅ | 中高 | 脆弱、延迟高、分辨率/窗口模式敏感、读不到游戏状态，不推荐 |

本仓库采用 **方案 B**：把 BOTato 的 AI 核心原样保留，只做"仅走位 + 默认开启 + 去依赖 + 本地打包"。

### 关键实测事实（先说清楚，避免踩坑）

1. **游戏已更新到 Brotato 1.2.0.1**（Godot 3.7.dev，内置 godot-mod-loader 6.3.0）。
   本 Mod 已在该版本真实启动游戏、实跑第 1 波并自动清波（验证记录见 §五）。
2. **Steam 版的 ModLoader 只从"已订阅创意工坊 item 目录"加载 zip**：
   `<Brotato>/mods/` 和 `~/Library/Application Support/Brotato/mods/` 在 Steam 版**都不会被加载**。
   所以本仓库的安装方式与普通"把 zip 丢进 mods 文件夹"不同（见下一节）。
3. 上游 BOTato 的"只走位"依赖 `ENABLE_AUTOSHOP=false`；一旦该值变 true（改配置/装面板依赖），
   会连锁自动升级、自动开箱、自动买/刷/锁/自动 GO。**本 fork 直接删除了这些代码**，
   所以"决策永远手动"是结构保证，而不是配置承诺。

---

## 二、安装（Steam / macOS）

> **当前状态（2026-11 实测后）**：本 Mod 已安装到你的游戏里：
> `~/Library/Application Support/Steam/steamapps/workshop/content/1942280/3598984651/AutoBattler-2.6.0-fork.zip`
> （借用了 Mod Options 的工坊 item 目录）。测试用的 harness 已删除，其它 8 个 Mod 已恢复，
> 测试前的 run 存档已还原。启动游戏即可生效；卸载/重装用 `./install.sh`。

### 方法 A：本地注入（最快，可逆；脚本自动）★ 先用这个试

```bash
cd auto-brotato
./install.sh
```

脚本会：
1. 自动定位 Brotato 安装目录；
2. 找到你已安装的创意工坊 mod 目录（默认挑第一个，例如 Mod Options 的 `3598984651`）；
3. 把构建好的 `dist/AutoBattler-2.6.0-fork.zip` 复制进该目录（loader 会加载该目录内**所有** zip）。

然后**从 Steam 启动 Brotato**即可。

```bash
./install.sh --list              # 列出候选工坊目录
./install.sh --item 3598984651   # 指定放进某个工坊 item 目录
./install.sh --remove            # 卸载（删除所有工坊目录里的这个 zip）
```

> 注意：这是本地 workaround。该创意工坊 item 被 Steam 更新/校验时，多出来的 zip 可能被清掉；
> 重跑 `./install.sh` 即可。不会破坏原 mod 文件。

### 方法 B：上传为自己的创意工坊 item（永久，推荐长期使用）

游戏目录里自带 Blobfish 的 `GodotWorkshopUtility.app`：

1. 启动 Steam（需登录拥有 Brotato 的账号）；
2. 打开 `<Brotato>/GodotWorkshopUtility.app`；
3. 选择 `dist/AutoBattler-2.6.0-fork.zip` 作为 mod 包，按工具提示创建/更新一个 Workshop item
   （可见性选"私有/不公开"也可以，自己订阅即可）；
4. 上传后在 Steam 创意工坊订阅该 item，正常启动游戏。

首次上传需同意 Steam Workshop 法律条款；上传的是 MIT fork，请保留 zip 内的 `LICENSE-BOTato-MIT.txt`
和作者致谢。

### 方法 C：非 Steam 版（GOG / Epic / 离线版）

```bash
./install.sh --non-steam
```

或手动把 zip 放进 `<Brotato>/mods/`（只有非 Steam build 的 loader 会扫描该目录）。

### 卸载

```bash
./install.sh --remove
```

删除存档无关：mod 只写 `user://auto-battler-fork.cfg`（开关状态），不碰存档。

---

## 三、使用

| 操作 | 效果 |
|---|---|
| 波次进行中 | 不操作即可：角色自动走位/闪避/捡材料 |
| **Shift + Space** | 随时开关自动走位（状态持久化；左上角 HUD 显示 `AUTOPILOT: ON/OFF`） |
| 升级三选一 / 开箱 | 游戏停下来等你选，AI 不会替你点 |
| 商店 | 完全手动：买、刷、锁、GO 都是你 |
| 波次结束 | 你决定何时点"下一波" |
| 角色 / 武器 / 难度选择 | 原版手动 |

- 配置文件：`~/Library/Application Support/Brotato/auto-battler-fork.cfg`（`user://auto-battler-fork.cfg`），
  只有 `ENABLE_AUTOBATTLER` 一项；删掉即恢复默认（开启）。
- 高级调参（可选，在 Steam 启动选项里加参数）：`--arb-every=2`（降决策频率、省性能）、
  `--arb-every=0`（自适应）、`--arb-charprofile=0`（关闭角色特化）。可用键名见
  `mod/mods-unpacked/Pasha-AutoBattler/steering/arbiter.gd` 的 `apply_overrides()`。
- v2.3.0 新开关：`--arb-kite=<W>`（远程保持距离，0=关）、`--arb-tree=<M>`（默认树价值倍数，0=关）、
  `--arb-food=<M>`（受伤时果子价值倍数，0=关）、`--arb-plan=<0|1>`（2 步前瞻，0=纯贪心）、
  `--arb-adapt=<0|1>`（受击后临时警戒）。同一批键也可以写进
  `user://auto-battler-overrides.json`。
- v2.4.0 DLC 开关（**带符号**，正=主动交战、负=回避、0=关闭即 2.3.0 精确行为）：
  - `--arb-curse=<V>`（默认 `3.0`）：诅咒怪（DLC1）目标价值 ×V；负数进入回避姿态
    （目标价值 0、该敌人威胁伤害 ×(1+|V|)，如 `-1` → ×2）。
  - `--arb-evolved=<V>`（默认 `2.5`）：机械/异变进化怪（DLC2）同上。
  - `--arb-evo=<M>`（默认 `1.0`）：进化物品拾取价值倍数，`0` = 完全回到 2.3.0
    （所有消耗品仍按食物定价、不主动捡进化物品）。
  - 例：`--arb-curse=6 --arb-evolved=4` 更激进；`--arb-curse=-1` 见到诅咒怪就躲。
- v2.5.0 规划开关（默认全开，**=0 为精确回退**）：
  - `--arb-breakout=0`：关闭"合围前预判突围"。默认会预测 1.8s 后的合围、用 1.6s 追击 rollout
    选逃逸线并承诺跑出去；`0` = v2.4.0 行为。
  - `--arb-goal=0` / `--arb-goalw=W`：关闭/缩放"高价值物品目标承诺"（进化果、受伤果子、树；
    按 价值/ETA 选目标并持续拉过去，而不是只吃路过的）。
  - `--arb-pursuit=0`：第二层前瞻改回常速度外推（默认按追击者会转向来外推）。
  - `--arb-walk=0`：关闭 walk-on 拾取语义（回到 v2.4.0 的 held-rim 读法，仅用于 A/B 对照）。
  - `--arb-waveend=0`：关闭波末进化果紧迫度（meca/mutant fruit 在波末不自动吸走，默认按剩余
    波时把价值放大 1→4 倍）。
  - 精确 v2.4.0 控制臂：`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0`。
- v2.6.0 空间/机会开关（默认全开，=0 为精确回退）：
  - `--arb-space=0`：关闭 open-floor 势场（380px 内向开阔地轻微收，防止被逐步挤到边缘）。
  - `--arb-bounty=0`：关闭特殊目标赏金接近（精英/Boss、生成器蛋、诅咒/进化怪）与掉落怪价值提升。
  - `--arb-boxes=0`：物品箱回到 2.5.0 的“只按回血定价”。
  - 精确 v2.4.0 控制臂（7 开关）：`--arb-breakout=0 --arb-goal=0 --arb-pursuit=0 --arb-walk=0 --arb-waveend=0 --arb-space=0 --arb-bounty=0 --arb-boxes=0`。
- 若发现角色不动：先看 HUD 是否 `ON`；再确认 mod 是否被加载
  （`~/Library/Application Support/Brotato/logs/modloader.log` 里应有 `Pasha-AutoBattler`）。

---

## 四、工作原理

- Brotato 使用 [godot-mod-loader](https://github.com/GodotModding/godot-mod-loader)，Mod 通过
  **script extension（GDScript 继承 + 覆盖）** 替换部分游戏脚本。
- 玩家移动的唯一入口是 `res://entities/units/movement_behaviors/player_movement_behavior.gd`
  的 `get_movement()`；玩家的 `unit.gd` 每帧调用它。
- 本 fork **只安装 2 个扩展**：
  1. `player_movement_behavior.gd`：开关打开时返回 BOTato `Arbiter` 算出的移动向量，
     关闭时调用原版输入逻辑；
  2. `main_menu.gd`：在标题界面创建 `/root/AutobattlerOptions` 单例（配置 + 热键 + HUD）。
- `Arbiter` 每帧对 24 个方向 + 原地站 + 8 个半步 hop 打分，综合：敌人接触危险、子弹弹道预测、
  AOE/冲锋预警、生命值、武器射程、材料/金币/箱子/树/蛋吸引、地图边缘、包围圈逃逸等；
  `steering/world_view.gd` 负责从 `EntitySpawner`/`Main`/`EnemyProjectiles` 等实时读游戏状态。
- 商店/升级/开箱/继续**没有安装任何扩展**，因此决策流程与原版完全一致。
- 性能：作者实测空场 0.2ms/帧、100+ 威胁 8–12ms/帧；后期卡顿可用 `--arb-every=2` 降频。

---

## 五、自适应角色 profile（2.2.0 新增，档 2 落地）

之前 BOTato 的"角色适配"是一张 **61 行手写角色表**（`CHARACTER_PROFILES`），每个角色一行
参数，属于 ad-hoc。2.2.0 起默认改为 **`--arb-profile=auto`：从游戏里可测量的 build traits
实时推导行为参数**，不再按角色名查表：

| 推导出的参数 | 测量来源 |
|---|---|
| `fire_still`（移动时不能开火） | `can_attack_while_moving` 效果（Soldier 类角色为 0） |
| `still`（偏好站桩/偏好移动） | 站桩类效果（`temp_stats_while_not_moving`、`effect_stat_while_not_moving`、站桩金币等）与移动类效果 |
| `caution` / `lethality` | 最大生命、护甲、闪避（有效血量）、lifesteal/HP 回复、是否接触收益型 |
| `pin`（卡角逃逸） | `fire_still` 或低血量无回复的脆弱 build |
| `engage*`（主动接触） | lifesteal / HP 回复 / 受击爆炸（`explode_on_hit`）等"挨打有收益"的机制 |
| `anchor` / `orbit` | 场上结构物/炮塔/宠物；无输出/和平主义类效果 |
| `dps`（击杀收益） | 是否真的持有武器（从 `RunData` 读，避免首帧空数组误判） |
| `gold` / `gold_mode` | 采集 stats、金币类效果；`dmg_when_pickup_gold`→enemy_gated、`reload_when_pickup_gold`→metered、炮塔→builder |
| `food` | `explode_on_consumable`→bomb、`no_heal`→none、`consumable_stats_while_max`→full_hp |
| `tree_value` | `one_shot_trees` / `tree_turrets` / `living_tree` / 每树加属性等效果 |

- **模式**：`--arb-profile=auto`（默认，忽略旧表）/ `table`（旧行为，便于 A/B）/
  `merge`（推断优先，旧表补缺）；`--arb-charprofile=0` 仍是完全关闭角色逻辑的对照开关。
- 接口不变：推导结果仍是原来的 row 字段，`arbiter.gd` 一行没改。
- **v1 已知局限**：经济/食物/树已按机制推导（2.2.1），但仍未覆盖所有冷门角色被动；
  极端/特殊 build 仍可能需要 `--arb-*` 微调。游戏内完整验证待下一轮 benchmark。


## 五点五、v2.3.0 策略升级（多步规划 / 风筝 / 机会项 / 自适应）

2.2.x 的走位是一个**单步贪心**：每物理帧对约 29 个候选方向做一次 0.8 秒解析预测，取代价最小。
它解释了 2.2.x 能被观察到的一类"不聪明"：远程角色贴脸、静场不砍树、掉血不吃果子。

### 1. 远程 standoff（风筝）

旧代价函数里，击杀收益在武器射程内是**平的**——站在 50px 和 380px 得分一样，
没有任何项奖励"保持在射程边缘"，所以远程 build 会被击杀收益一路拉近。
v2.3.0 增加一个 standoff 项：对候选的**终点位置**计算到最近目标的距离，
在 `kite_frac × weapon_range`（默认 0.75）环内按距离收费，环外不收费；
掉血时环放大（`--arb-kitehp`，旧 field controller 的 `KITE_HP_FACTOR` 语义）。
配合原有的击杀收益，形成"在射程边缘"的势井，而不是排斥场。
全近战/无武器 build 的 `kite_frac = 0`，该项完全不生效；`--arb-kite=0` 为精确控制臂。

### 2. 机会项：树与果子

- **砍树**：树被砍掉会掉 consumable + 材料（`main.gd::_on_neutral_died → spawn_loot`），
  但旧推理只在角色带"树木机制"时给 `tree_value`，普通角色是 0，树永远进不了评分。
  v2.3.0 给所有非 cryptid 角色一个小的默认树价值（静场时才会去砍，威胁项仍能否决）。
- **吃果子**：旧代价里食物只是 tie-breaker（量级 1-5），远小于威胁项 15-65；
  掉血时也不会为果子转向。v2.3.0 把"受伤时的果子"提升为机会项：
  `food_mult × min(FOOD_MAX, missing_hp)`（默认 2.5，上限 30），全血时仍不浪费（`bank` 语义）。
  波次结束时游戏会自动吸取剩余 consumable，所以全血不吃不亏。

### 3. 2 步前瞻（receding-horizon，2-ply）

单步贪心"每 0.8 秒局部正确，加起来可能走进死角"（源码注释里大量 pin/herding 补丁就是证据）。
v2.3.0 在初次 sweep 后，对角度分散的前 K（默认 4）个第一动作各做一层展开：
威胁按 0.8 秒推进到**下一个决策点**（`_advance_threats`），在推进后的世界里
用同一套 `_cost` 再评 8 方向 + 站立，取最便宜的接续，`total = score1 + γ·cost2`
（γ=0.6）。planner 只当第一动作的 tie-breaker，不改变威胁模型本身。
保护：`--arb-plan=0` 精确回退贪心；威胁数 >90 或威胁为空或贪心冠军是"站立"时跳过；
`_prepare()` 写的 13 个 prepared 数组与标志用引用保存/恢复，planner 结束后主流程状态不变。

### 4. 受击自适应

单次决策内 `hp_ratio` 掉 ≥12% 时，进入 `--arb-adaptsecs`（默认 2 秒）警戒期，
威胁权重 ×(1+0.25)，与 caution/pin 共用同一组 saved 权重并一起恢复；
room/wall/dps 不动（避免受伤后变中心蹲）。`--arb-adapt=0` 回退。

### 5. 性能

2 步前瞻带来约 36 次额外 `_cost` 评估（beam 4 × (8+1)），headless 实测约 2.4×：
20/60/90 威胁下 plan0 = 0.42/1.08/1.55ms → plan1 = 1.07/2.69/3.87ms。
>90 威胁自动跳过规划；仍嫌慢可用 `--arb-plan=0`、`--arb-beam=2/3` 或 `--arb-planthreats` 降阈值。

## 五点六、v2.4.0 DLC 适配（诅咒怪 / 进化物品）

玩家反馈：bot 遇到**被诅咒的敌人**（DLC1 Abyssal Terrors）只风筝不打；新 DLC
（Primal Dread）的**进化物品**（机械果实/异变果/异变基因/机械部件）躺在原地不捡。

### 1. 诅咒怪 / 进化怪为什么“不打”

游戏侧（`_research/game-1.2.0.1/recovered/`，Brotato 1.2.0.1 反编译核实）：
- 诅咒怪 = 普通敌人 + `boost()`：`hp_boost = 200 + 2*min(curse,300)`（百分比 → **至少 3 倍血**）、
  `damage_boost = 50`（+50%）、`speed_boost = 75`（+75%），并加一圈
  `Utils.CURSE_COLOR = ca61ff` 描边（`curse_enemy_effect_behavior.gd:9`），掉材料 +33%。
- 进化怪 = `Enemy._is_meca / _is_mutant`，随 |evolution| 增长：meca HP +52%~+650%、damage +25%~+50%、
  speed +5%~+25%；mutant HP +27%~+745%、damage +15%~+80%、speed +5%~+25%
  （`evolution_scene_effect_behavior.gd`，magnitude 上限 300），加 `MECA_COLOR/MUTANT_COLOR` 描边，材料 +33%，
  且机械/异变敌人分别掉落机械部件 / 异变基因类进化物品。

旧版 world_view 把它们当普通敌人定价，于是出现**双向错误**：血量变大 → `_kill_value` 的
killability 折减（目标价值下降）；伤害/速度变大 → 接触威胁权重上升。结果是“不值得打 + 更危险”
→ arbiter 后撤 → 武器只自动瞄准射程内最近敌人，射程外就不开火 → 玩家看到“不打”。
离线合成测试（真实 `arbiter.gd` + world_view 公式构造 tuple）：近战 range=140、单只诅咒怪在 280px 时，
目标价值 ×1 → 0.8 秒后距离被拉到 378px（跑）；×2 以上 → 拉到 126px（主动接近）。
所以**目标价值倍率是有效且可调的杠杆**。

### 2. 实现（只改 `world_view.gd`，`arbiter.gd` 一行未改）

- **检测**：诅咒 = `unit.has_outline(Utils.CURSE_COLOR)`（描边存活期间不消失，也是玩家看到的标记）；
  进化 = `Enemy._is_meca/_is_mutant`（用 `"x" in unit` 防御式读取）。
- **交战/回避姿态**（带符号开关，见 §三）：
  - `V > 0`：该敌人的 targets 价值 ×V（更愿意把其保持在武器射程内 = “打它”）；威胁伤害不动。
  - `V < 0`：**非 Boss** 敌人的 targets 价值 = 0（不主动靠近），同时该敌人的接触/冲锋/蓄力威胁伤害
    ×(1+|V|)（更早躲）。
  - Boss/精英：不做 target 价值倍率、不清零（避免为了打精英贴脸）；但回避侧的威胁伤害缩放对 Boss 同样生效。
- **进化物品**：单独奖励类，不再按 `_food_value`（掉血治疗）定价。
  - 分类：`Keys.consumable_meca_fruit_hash / mutant_fruit / mutation_fruit / meca_parts_hash`，
    另有 id 字符串与 effect key（`stat_evolution` / `meca_parts`）后备。
  - 资格：必须通过 `RunData.can_pick_up_consumable`（游戏自己的阵营锁/进化阈值），
    非 dual 角色只捡**不跨越 0 点**的方向（evolution>0 只捡机械果实，<0 只捡异变果，=0 两者皆可）。
  - 拾取方式：这些消耗品**不会被吸引圈收走**（`can_attract_consumable_data` 排除两种果实，
    吸引区也仅收有治疗效果的物品），必须踩上去。而且机械/异变果实的
    `attracted_at_end_of_wave = false`——**波次结束也不会被自动吸走，波内不踩就留在地上随场景消失**
    （mutation fruit / 机械部件是 true，波末会吸）。因此奖励用 **held rim=45px**
    （玩家拾取圈半径 32px，物品半径 ~10px）：arbiter 会对“终点进入拾取圈”给全额奖励，
    rim=0 时只剩线性梯度、bot 会停在圈边。
  - 价值（可 `--arb-evo` 缩放）：机械/异变果实 6、异变基因（mutation fruit）9、机械部件 6
    （对比：loot alien 4、树 3、受伤果实最高 30）。
  - 顺带修正：**非治疗消耗品不再被当食物**——毒果（`ConsumableDamageEffect`）不会再被主动吃；
    普通果实/物品箱（有 `ConsumableHealingEffect`）行为不变。
- 控制臂：`--arb-curse=0 --arb-evolved=0 --arb-evo=0` 时 threats/targets/rewards 与 2.3.0 逐值一致
  （离线 fake 世界对照测试 + A/B 的 control 臂）。
- 遥测：每秒最多一行 `BOTLOG DLC wave=.. cursed=N evolved=N evo_ground=M curse=.. evolved=.. evo=..`，
  证明 bot 确实“看到”了 DLC 内容。

### 3. 真机 A/B（v2.4.0）

方法：真实游戏自动开局（Steam，Brotato 1.2.0.1，DLC 物品集全开）。harness 强制
`always_curse=true`（所有非 Boss 敌人被诅咒，压力测试）、`evolution_consumables_drop_mult=20`
（进化消耗品掉率 ×20）、`Engine.time_scale=3`+物理帧补偿；对比 `control`（三开关全 0 = 2.3.0 行为）、
`dlc`（新默认 3.0/2.5/1.0）、`dlc_strong`（6.0/4.0）、`avoid`（curse=-1，仅第 1 轮）、
以及旧 2.3.0 构建（批次对照）。详细原始数据/日志在 `_research/dlc-bench/`。

**Round 1（Danger 6 / wave 4 / n=3 每场景每臂，24 局；环境过凶，除个别外全部死亡）**

| 臂 | 角色 | cursedKilled | hp_frac | evo_picked | nearE | 存活 s |
|---|---|---|---|---|---|---|
| control | knight | 38 | 0.92 | 11 | 137 | 22 |
| dlc | knight | 37 | 1.00 | 19 | 110 | 21 |
| dlc_strong | knight | 82 | 0.85 | 32 | 110 | 32 |
| control | ranger | 6 | 0.74 | 1 | 137 | 15 |
| dlc | ranger | 8 | 0.83 | 0 | 131 | 13 |
| avoid | knight/ranger | 42 / 6 | 0.94 / 0.85 | 9 / 3 | 144 / **204** | 24 / 13 |

**Round 2（Danger 3 / wave 3 / n=3 每场景每臂，18 局，主判据）**

| 臂 | 清波 | 掉血 | minHP | nearE (knight/ranger) | cursedKilled (knight/ranger) | evo_picked 合计 |
|---|---|---|---|---|---|---|
| control | 6/6 | 2.17 | 4 | 165 / 126 | 58 / 31 | **32** |
| **dlc（默认）** | **6/6** | 4.50 | 1 | **121** / 128 | 56 / 32 | **66（+106%）** |
| dlc_strong | 4/6 | 5.50 | 2 | 122 / 153 | 54 / 28 | 63 |

结论（方向性，样本小）：
1. **进化物品拾取修复有效**：默认档波内拾取量 32→66（两角色均上升），清波率不变。
2. **诅咒怪交战更主动**：近战 Knight 的 `nearE` 165→121px（更愿意贴近打），代价是掉血 2.3→5.3
   —— 打“至少 3 倍血 +50% 伤害 +75% 速度”的诅咒怪本就要付出代价，这也是需要回避开关的原因；
   远程 Ranger 的 `nearE` 不变（继续风筝），但同样会顺路捡进化物品。
3. **默认值 3.0/2.5 合适**：更激进的 6/4 在 D3 出现 2/6 死亡，不回退清波率的意义上更差；需要更激进的
   玩家可自行 `--arb-curse=6 --arb-evolved=4`。
4. **回避姿态有效**：`avoid`（curse=-1）把 nearE 137→204px、掉血 6.17→5.17、最低 HP 1→2。
5. 旧 2.3.0 构建与 `control` 同量级，说明批次/构建无系统差异。

> 局限：样本小（每臂 6 局）、单波 30s、`always_curse` 压力场景，绝对数值不可外推；`evolved` 敌人实机
> 难触发（新开局 evolution=0），该分支与诅咒共用机制，由离线 297 条断言覆盖。存档跑前备份、跑后恢复
> 并校验 sha256 一致；其它 mod 由 benchmark 自动恢复。


## 五点七、v2.5.0 规划能力（合围前突围 / 高价值物品）

玩家反馈（本轮唯一需求来源）：“感觉缺乏规划，肉眼能看到要被包围，但当前策略不会提前规划；也不会规划去拣取高价值物品。”

### 1. 结论：不完全是“局部贪心”的固有缺陷

打分+argmin 的框架没变（它本来就是为了避免势场求和在包围时互相抵消）；缺的是三样东西：

1. **时间尺度**：代价函数只看 0.8s，2-ply 实际有效 ~1.3s，而合围发生在 2–4s。从环内出发，
   任意方向 0.8s 的终点都贴着身体，一阶分差≈0，二阶被 γ=0.6 压掉 → “现在做对每一步，加起来
   走进死角”。长视界的 crowd runway（FAR_T=2.0）只测 min 距离且用直线速度，对称环里所有方向
   一样差；能看 2.5s 墙 runway 的 `W_PREDICT` 默认还是关的。
2. **目标承诺**：物品只以“每步梯度”进入评分（`w_pickup=1.0` × 价值 6–9，距离衰减 320px），
   任何 >0.3s 的绕路都赢不了单只怪 10–40 的威胁价。没有“选中目标→坚持去拿→风险大再放弃”。
3. **动作/奖励语义**：全速 24 方向 + 站立，物品在 1 个 horizon 步（~250px）内时全速方向全部
   过冲、站立得分 0 → 停在半程；v2.4 的 45px walk-on rim 被 arbiter 当成 **held**（复活圈：
   圈内每帧刷分）→ bot 停圈上不消费；meca/mutant fruit 波末不自动吸走，但 `wave_time_left`
   从未用于物品紧迫度。

### 2. 实现（全部默认开启，逐项可回退，5 个开关全 0 = v2.4.0 精确行为）

- **预判突围**（`--arb-breakout`，arbiter.gd）：把接触体按“追击者转向我们、停在接触距离”投影
  1.8s；用 3° 扇区算现在/未来的最大空缺角。现在还能过人（≥0.15 rad）但 1.8s 后缺口消失
  （<0.02 rad）且接触体 ≥6 → 进入 engaged 突围：16 方向 × 1.6s 追击 rollout（墙计入最坏
  间隙），得分 `worst + 0.6*terminal_clearance`；只有 worst ≥ −28px（允许用一次受伤换突围）
  才装填。承诺跑 180 帧上限或直到最近身体 >260px；期间接触权重 ×0.35、room ×0.5、朝逃逸线
  每帧 −60 HP 奖励；**子弹/冲锋/AOE 权重不动**（是“穿过人群”，不是“扛伤害”）。
- **物品目标承诺**（`--arb-goal` / `--arb-goalw`）：无身体距 <320px 时按 `value/(1+ETA/420)`
  选价值 ≥4 的 reward；`_cost` 加持续 pull，拾取/目标消失/身体 <170px/超时释放；物品在 1 个
  horizon 步内时额外评一个“恰好落在目标上”的减速候选（修全速过冲→站立）。
- **walk-on 语义**（`--arb-walk`）：world_view 给 4 种进化消耗品 reward 加第 5 元素 `r[4]=1.0`；
  arbiter 对这类 reward 用一次性拾取语义（全程梯度 + 跨入 rim 的 taken bonus），不再当 held。
- **波末紧迫度**（`--arb-waveend`，world_view）：只对 `attracted_at_end_of_wave=false` 的
  meca/mutant fruit，`eta=dist/speed`，剩余波时 < eta+1.5s 时价值 ×(1→4)。
- **pursuit 第二层**（`--arb-pursuit`）：planner 第二层对 contact/dash 改为朝第一动作终点转向
  推进（常速度投影会把“即将关闭的缺口”算成开着）。
- 性能：包围场景决策耗时约 1.2–1.3×（rollout 只在合围前兆触发；高威胁帧仍有 threat 上限保护）。

### 3. 离线闭环验证（合成世界，真实 `arbiter.gd`）

`_research/planning-v250/sim/`：追击者/远程/子弹/墙，60Hz，control = v2.4.0 行为，30s/局。

| 场景 | control（v2.4） | v2.5 默认 |
|---|---|---|
| ring20_walls（20 只 280 速度追击者，小地图） | **6.3s 死亡**，包围 0.75s | **存活 30s**，hp70 |
| ring14_fast（14 只 270 速度环） | 贴环转圈 nearest≈50px，surrounded 0.48s | 存活 hp88，surrounded 0.32s，3.0s 突围 |
| ring10_open | surrounded 0.55s | surrounded 0，nearest 361px |
| crossfire（10 追击 + 持续弹幕） | surrounded 0.72s | surrounded 0，nearest 79px |
| item_far_safe（650px 外 9 价值 walk-on） | **0 拾取** | **1.9s 拾取** |
| item_far_1slow（1 慢追击者 + 520px 物品） | **15.2s 死亡，0 拾取** | **1.6s 拾取，存活** |
| ring10_faster（敌人 380 > 玩家 320） | 2.8s 死亡 | 4.3s 死亡（无解时诚实不装突围） |

> 门禁/回归由 `_research/planning-v250/gate/`（verify-dev）与 `_research/planner-selftest/`
> 覆盖：控制臂逐帧等价 v2.4、A/B 场景 PASS/FAIL、性能。真实游戏 A/B 需用户同意后跑
> （`calibration/candidates_v250.json`）。

### 4. 已知限制

- 突围针对“人海/合围”，不保证“弹幕墙 + 追击者”的复合陷阱最优；子弹仍全价，可能边跑边吃弹。
- rollout 用“朝当前位置转向 + 常速度”的追击近似，不是完整敌人 AI；已被合围封死时拒绝装填。
- goal 的安全窗口只看身体距离，不看子弹弹道；接近途中仍由每帧威胁项兜底。
- 默认值是 8 个合成场景 + 后续真机 A/B 的方向性结果，不是统计最优；可用 `--arb-*` 微调。

---

## 五点八、v2.6.0 空间规划 / 特殊目标（真实试玩后的第二轮反馈）

玩家反馈（v2.5.0 试玩后）：“策略还是不喜欢攻击或收集特殊的怪物或者产出；而且仍旧缺乏规划，很容易被逼到地图边缘丧失操作空间。”

### 1. 根因

1. **被逼到边缘不是“合围”，是“空间被逐步吃掉”**：v2.5 的 breakout 只在“环状合围预测关闭”时触发；
   单侧压力可以把 bot 从场地中央一步步推到墙带（每一步 0.8s 局部都对），而墙项
   `W_WALL` 只在 220px 内超线性生效、`W_PREDICT` 默认关、pin escape 是事后触发。离线闭环仿真复现：
   角落起手的环形局里，v2.5 默认臂 `edge_min` 一度到 37–59px；30s 后仍贴墙。
2. **特殊怪物/特殊产出没有形成“目标”**：target 只对 `weapon_range+220px` 内的敌人可见，
   1–2 屏外的精英/Boss/生成器蛋/诅咒进化怪根本进不了分；掉落怪价值只有 4（和一次普通击杀
   同量级），物品箱只按回血 3/100→上限 12 定价，满血时几乎为 0。

### 2. 实现（默认开启，逐项可回退）

- **贴墙带撤离**（并入 `--arb-breakout`）：距最近墙 <150px 且 430px 内 ≥4 个身体时，用同一套
  16 方向 × 1.6s 追击 rollout（墙计入）选“回开阔地”的路线，承诺 1.5s；与环状突围不同，
  **不折价接触伤害**（只是撤退，不是硬挤），冷却 2s 防止与墙来回拉锯。
- **open-floor 势场**（`--arb-space`，W=2.5，范围 380px）：在墙项够不到的距离上给一个
  破平局量级的“向开阔地”梯度，阻止“每步局部正确”的漂移；不改变威胁/击杀优先级。
- **赏金接近**（`--arb-bounty`）：附近 300px 无身体、HP>35% 时，对 900px 内带 special tag 的
  target（1=Boss/精英，2=生成器蛋，3=诅咒/进化怪）按 `value/(1+dist/480)` 选一个，持续拉近到
  0.9×武器射程交给正常开火；身体 <180px、HP<24.5% 或目标消失则放弃。world_view 同时把 special
  写进 target 第 4 元素（`bounty=0` 时保持 3 元组 = 2.5.0 精确元组）。
- **特殊产出定价**：物品箱/传说箱按 `max(回血价值, 5/10)`（`--arb-boxes=0` 回退）；掉落怪
  `LOOT_VALUE 4→6`（`--arb-bounty=0` 回退），两者都进目标承诺层。

### 3. 离线验证（合成闭环 + 真实 `arbiter.gd`）

| 场景 | control（v2.4） | v2.6 默认 |
|---|---|---|
| corner_ring（角落起手 14 追击者） | edge_min 58.8，<100px 0.70s | edge_min 60.1，<100px 0.88s；寿命 30s |
| soldier_herd（16 追击者 + 站桩 profile） | **7.8s 死亡** | **存活 30s**，edge_min 161 |
| melee_herd（22 追击者近战） | **4.9s 死亡** | **存活 30s**，edge_min 200 |
| ring20_walls | **5.7s 死亡** | **存活 30s**，edge_min 224 |
| bullet_wall（单侧弹幕 + 8 追击者） | hp_min 40，edge_min 54.7 | **hp_min 80，edge_min 182** |
| near_wall_ring | edge_min 154.9 | edge_min 194.7 |
| 单帧探针（bounty 对 850px 外特殊目标） | 不接近 | 方向对齐 >0.95，且 120px 内有身体时拒绝接近 |
| 贴墙 7 连 crowd 单帧探针 | 无 breakout | 触发 `reason=corner` 撤离 |

> 尚未复现/未覆盖：真实游戏中“被更快的敌人追到墙角”的无解情形；bullet_wall 类复合压力下的
> 长期表现；赏金/箱子在真机的实际收益。验收门禁 `_research/planning-v250/gate/` 19/19 PASS
> （含 v2.6 的 E1–E3 探针），`planner-selftest` 292 checks PASS；真机 A/B 仍待跑。

---

## 六、验证状态（诚实说明）

### v2.6.0 离线验收（2026-11-06，第二轮）

- 新增 v2.6 探针：`_research/planning-v250/gate/run.sh` → **`RESULT checks=19 fails=0 PASS`**
  （A1/B1/B2/C 全绿 + E1–E3：赏金接近/近距离否决/贴墙撤离触发）。
- `_research/planner-selftest/run.sh` → **`RESULT checks=292 fails=0 PASS`**（控制臂已加
  `bounty=0, space=0`，新增 bounty/space 默认与 override 断言）。
- 注意：门禁的 v2.4 参考实现已从 `git HEAD` 改为**固定 commit `751f3c3`**（v2.4.0）——
  HEAD 在发布 v2.5.0/v2.6.0 后已不是 2.4.0 脚本，否则 C 等价检查会误报。
- 真实游戏 A/B 仍需用户同意后跑（`_research/planning-v250/bench.md`）；候选/场景已更新为 7 开关控制臂。

### v2.5.0 离线验收（2026-11-06，合成闭环 + 真实 `arbiter.gd`）

- 冻结源码：`arbiter.gd` sha256 `d0be03c6…`（2328 行）、`world_view.gd` sha256 `f54a3d29…`；
  `check_gd.sh` PASSED，无 SCRIPT ERROR。
- 验收门禁 `_research/planning-v250/gate/run.sh` → **`RESULT checks=14 fails=0 PASS`**（exit 0）：

| 判据 | 默认臂（v2.5 全开） | 控制臂（v2.5 开关全 0 = v2.4.0） | 结果 |
|---|---|---|---|
| A1 ring20_walls（20 只 280 速度追击者，1200×900） | **存活 30s**，hp_min 70，surrounded 0.42s | **6.3s 死亡**，surrounded 0.77s | PASS |
| A2 ring_shooters（9 只含远程 + 弹幕压力） | 存活 30s，hp94，contact 0.43s | 存活 30s，hp94 | PASS（无退化） |
| B1 item_walkon（520px 物品 + 慢追击者） | **1.63s 拾取**，存活 | 15.2s 死亡，**0 拾取**（停在 41.6px） | PASS |
| B2 item_open（650px 物品，0 威胁） | **1.95s 拾取** | 0 拾取（停在 106px，v2.4 过冲缺陷） | PASS |
| C 控制臂等价（3 场景 ×1800 帧） | — | 与 v2.4.0 HEAD **逐帧一致**（方向 + 结束态） | PASS |
| D 性能 | A1 2028us / A2 1261us | A1 1569us / A2 1031us（**1.29× / 1.21×**） | PASS |

- 现有 274 项合成自测扩展后 `_research/planner-selftest/run.sh` → **`RESULT checks=288 fails=0 PASS`**。
- 对照组：把门禁跑在冻结的 v2.4.0 HEAD 上 → `checks=14 fails=3`（A1/B1/B2 默认臂按设计失败）。
- **尚未做真实游戏 A/B**（需要用户同意后启动 Steam）：runbook
  `_research/planning-v250/bench.md`，候选/场景 `calibration/candidates_v250.json` /
  `calibration/scenarios_v250.json`，harness 新增 `brk=/breakouts=/goal=/goal_d=/goals=`
  遥测用于证明功能在真机确实触发。真机结果补录前，v2.5.0 的结论只能按
  “离线合成验收通过 + 无回归信号”理解。


### v2.3.0 策略升级验证（2026-11-06，本地真实游戏 + 自动 harness）

方法：真实游戏自动开局（Steam），`control` = 所有新开关关（精确 2.2.2 行为），
`full` = 2.3.0 默认。指标：清波率、掉血、最低 HP、`nearE/wrange`（每秒最近敌人距离 / 武器射程的中位数）、
决策耗时 `us`、`plan=`/`adapt=` 开关遥测。全部为 Brotato 1.2.0.1、Danger 6/3、Ranger 等起始武器无成长 build；
**样本量小（每臂 3-6 局），以下按"未发现退步 + 方向性信号"理解，不是统计显著结论。**

**1.0x A/B（Ranger，D6 从 wave 3 + D3 wave 1，n=3/场景/臂，共 18 局）**

| 臂 | 清波 | 平均掉血 | 最低 HP | D6 nearE | D3 nearE | 决策 us |
|---|---|---|---|---|---|---|
| control | 6/6 | 2.00 | 4 | 176 | 537 | 391 |
| tactics（弱化版开关） | 6/6 | 2.17 | 4 | 156 | 477 | 419 |
| full（2.3.0 默认） | 6/6 | 2.00 | 5 | 185 | 549 | 726 |

- 清波与掉血无差异；`full` 的最低 HP 略高（5 vs 4），`nearE` 略远（D6 +5%，D3 +2%），在噪声内。
- planner 在 `full` 的 D6 采样点里 **82%** 处于启用状态（8 方向 2-ply），`adapt` 触发约 5% 采样点；
  决策耗时约 **1.9×**（仍远低于 16.7ms 帧预算，威胁数 >90 时自动跳过规划）。

**2.0x 调参 A/B（Ranger，D6 wave3 / D6 wave6 / D3 wave1，n=1/场景/臂，共 9 局）**

| 臂 | 清波 | 平均掉血 | 最低 HP | nearE/wrange | 决策 us |
|---|---|---|---|---|---|
| control | 2/3 | 3.00 | 1 | 0.31 | 433 |
| full（默认） | 2/3 | 1.67 | 4 | 0.55 | 1131 |
| strong（kite30/tree2/food4） | 2/3 | 2.67 | 2 | 0.49 | 968 |

- 方向性信号：默认权重优于"更强 tactics"；把 standoff/树/果子放大反而更差，所以默认值没有再加大。
- 2.0x 是"裸 time_scale"加速，AI 每游戏秒的决策数减半，只用于相对比较（见下"测试加速"）。

**3.0x + 物理补偿确认（Ranger D6 wave6 / Soldier D6 wave3，control vs full，n=3/场景/臂，共 12 局）**

| 场景 | control | full |
|---|---|---|
| Ranger D6 wave6 生存 | 9 / 19 / 19 s（均 15.7s） | 12 / 22 / 19 s（均 17.7s，+2s） |
| Soldier D6 wave3 | 3/3 清波，掉血 9/6/6 | 2/3 清波，掉血 8/9/10 |

- Ranger 的生存秒数方向性变好（+13%），但 Soldier 出现 1 次死亡（n=3，不能区分噪声）。
- **结论：没有发现一致退步，也没有足够样本宣称"明显变强"**；真正能拉开差距的是玩家自己的中后期 build/波次，
  建议用 `--arb-plan=0` / `--arb-kite=0` 做个人 A/B。

**测试加速（harness `user://harness_scenario.json` 的 `"speed"` 字段）**

- 裸加速：`Engine.time_scale = s`。Brotato 自带 debug 菜单用的也是这个；2x 下 30s 波约 15s 实际时间。
  代价：物理 tick 仍是 60/s，**AI 每游戏秒的决策数变成 60/s**（1x 是 60），只适合相对 A/B。
- 补偿加速：`Engine.time_scale = s` 且 `Engine.iterations_per_second = 60*s`（运行时 settable，已验证）。
  每个 tick 推进的**游戏时间仍是 1/60 秒**，AI 决策频率、帧计数常量、子弹碰撞粒度都不变，CPU 随 s 线性增加。
  3x 确认批次用的就是这个模式。>3x 会受 CPU 预算限制（决策耗时 × 帧率），收益递减。


**已完成：真实游戏实测（Brotato 1.2.0.1，2026-11 更新后）**

- 安装方式：把本 zip + 一个临时测试 harness 放进工坊 item 目录；为排除旧 Mod 干扰，测试时
  暂时禁用了其它 8 个 Mod（测试后已恢复），游戏经 Steam 正常启动。
- 测试流程（harness 全自动）：标题界面 → 自动选角（Ranger）→ 自动选武器（Pistol）→
  Danger 0 → 进入第 1 波；AI 全程开启。
- **结果**：第 1 波 20 秒内 AI **19/19 个采样点都在移动**（move_ratio 0.95），
  **HP 保持 7/7 零受伤**，波次清空；`logs/godot.log` 中**没有任何**与
  `Pasha-AutoBattler` / `player_movement_behavior` / `world_view` 相关的脚本错误。
  harness 随后按计划退出（日志：`[HARNESS] RESULT reason=WAVE_CLEARED_TIMER ... move_ratio=0.95`）。
- 这同时验证了：ModLoader 加载、2 个扩展安装、自动走位/闪避/拾取、HUD/配置初始化
  （`[AutoBattler] options ready, autopilot=True`）在新版本上全部正常。

- **自适应 profile（2.2.0）三角色冒烟（2026-11-05，同一环境）**：用直接 `RunData` 构建 run 的
  harness 各跑 1 波 Danger 0，全部清波、0 脚本错误：

| 角色 | 自动推导出的关键参数 | 第 1 波结果 |
|---|---|---|
| Ranger（远程） | `caution:1.6, lethality:4.22` | 清波，move_ratio 0.89，HP 全程 7-8/8 |
| Soldier（fire_still） | `fire_still:true, still:prefer, pin:true, pin_dwell:40, caution:0.99` | 清波，move_ratio 0.89，最低 10/11 |
| Knight（近战/坦） | `caution:1.33` | 清波，move_ratio 0.95，最低 10/11 |

  对照组：同一 harness 早前用错误 profile（误判为"无武器/和平主义"）时 Soldier 第 1 波死亡；
  profile 修正后通过，说明自适应推导是有效的。

**其它已完成的验证：**

1. **反编译并逐 API 核对**（对 1.1.15.4 源码基线）：`_research/api-map.md` 确认核心 hook
   `get_movement() -> Vector2` 签名一致，`world_view` 依赖的 `Main._entity_spawner/_wave_timer/
   _consumables/_active_golds/_births_container`、`EntitySpawner`、`EnemyProjectiles`、
   `ZoneService.current_zone_max_position`、Hitbox/Projectile/Boss 字段、`RunData/Keys/Utils` 等全部存在。
2. **ModLoader 加载冒烟测试**（游戏副本 + pck 本地模式）：zip、manifest、2 个 script extension
   安装成功、无解析错误（`_research/run-smoke2.log`、`run-smoke3.log`）。
3. **核心 steering 运行时单元测试**：Godot 3.6.1 headless 实例化 `Arbiter`，合成威胁/奖励下
   `choose()` 返回正确避敌/拾取方向（`_research/arbiter-test/`）。
4. **上游源码审计**：`_research/audit.md` 确认自动决策入口已在瘦身 fork 中全部删除。

**尚未实测（不影响核心结论）：**

- 升级/商店/开箱界面上的手动交互与 Shift+Space 误触检查（代码已 `set_input_as_handled()`；
  本次测试为全自动 harness，未在升级/商店界面按热键）。
- 第 2 波及以后、其他角色、更高 Danger 的表现。
- 与你那 8 个旧 Mod 同时启用（建议先更新它们；见"其他 Mod 兼容性"）。

**建议首测清单（1–2 分钟）：**

- [ ] 开局后角色自动走位（你按方向键无效，这是预期）。
- [ ] Shift+Space 后恢复手动，再按一次恢复自动；HUD 状态同步。
- [ ] 升级三选一界面：AI 不会替你选；**在升级界面按 Shift+Space 不会误触/误选按钮**。
- [ ] 商店：买/刷/锁/GO 全手动；点"下一波"继续。

若首测遇到报错：把 `~/Library/Application Support/Brotato/logs/modloader.log` 和
`logs/godot.log` 的最后 100 行发我，可按日志定位并修（预期风险集中在不同版本 API 漂移）。

---

## 七、兼容性、风险与回退

- **目标版本**：Brotato **1.2.0.1**（本机实跑验证；Godot 3.7.dev；内置 ModLoader 6.3.0）。
  游戏更新后若失效：删掉 zip 即恢复原版，或等更新适配。
- **其他 Mod 兼容性**：你已安装的 8 个旧 Mod 里，有部分在 1.2.0.1 更新后会出现脚本报错
  （例如 `base_shop.gdc` 解析错误）；那是旧 Mod 自身未适配新版本，与本 Mod 无关，建议逐个更新/停用。
  本 Mod 只动了 `player_movement_behavior.gd` + `main_menu.gd` 两个无冲突扩展点，不依赖它们。
- **与已装 mod 的兼容性**：本 fork 只扩展 `player_movement_behavior.gd` 和 `main_menu.gd`，
  这两个脚本没有被你已装的 8 个 mod 扩展；不会与 DamageMeter/Mod Options 等冲突（审计 §7）。
  上游 BOTato 的自动商店扩展会与 Bronti/DamageMeter 的 `base_shop` 链冲突，本 fork 已删除该扩展。
- **联机/合作（co-op）**：未验证，本 fork 面向单人。
- **成就**：未验证 Mod 是否影响 Steam 成就解锁，介意的话先备份存档。
- **Mod 自身写盘**：只写 `user://auto-battler-fork.cfg`；不写存档、不改游戏安装目录。
- **安装目录风险**：方法 A 会把 zip 写进某个已订阅创意工坊 item 的目录；该 item 更新时可能被清掉，
  重跑脚本即可；不会改动原 mod 文件。
- **性能**：后期高威胁波可能掉帧；`--arb-every=2`（固定降频）或 `--arb-every=0`（自适应）。

---

## 八、目录结构

```
auto-brotato/
├── README.md                    # 项目主页（简短宣传）
├── docs/TECHNICAL.md            # 本文件（详细技术文档）
├── install.sh                   # 安装/卸载（Steam 工坊注入 / 非 Steam mods 目录）
├── build.sh                     # 构建 dist/AutoBattler-2.6.0-fork.zip
├── dist/
│   └── AutoBattler-2.6.0-fork.zip
├── mod/                         # Mod 源码（zip 内容）
│   ├── LICENSE                  # 上游 BOTato MIT 许可
│   ├── README-FORK.md           # 随 zip 分发的说明
│   └── mods-unpacked/Pasha-AutoBattler/
│       ├── manifest.json
│       ├── mod_main.gd          # 只安装 2 个扩展
│       ├── autobattler_options.gd  # 配置 + Shift+Space + HUD
│       ├── extensions/...       # 2 个最小扩展
│       └── steering/            # BOTato 走位 AI（arbiter + world_view）
└── _research/                   # 调研资料（非交付物）
    ├── api-map.md               # 反编译后的 API 映射与兼容性结论
    ├── audit.md                 # BOTato 自动决策审计 + 瘦身方案
    ├── strategy-v230-design.md  # v2.3.0 设计/根因
    ├── planning-v250-design.md  # v2.5.0 设计/根因（本轮）
    ├── planning-v250/           # 闭环仿真 sim/ + 离线门禁 gate/
    ├── decompiled/              # 反编译源码（脚本部分）
    └── run-smoke*.log           # ModLoader 加载冒烟测试日志
```

---

## 九、开发与发布（本地优先）

- **开发/测试使用本地版**：改代码 → `./build.sh` → 把新 zip 放进游戏工坊目录
  （`./install.sh` 或手动复制）→ 重启游戏验证。可随时改、随时重装。
- **Workshop 已发布**：<https://steamcommunity.com/sharedfiles/filedetails/?id=3834096920>
  （ID `3834096920`；之前"仅自己可见"是默认可见性设置，已修正为公开）。
  更新版本时用 `GodotWorkshopUtility` 选新 zip + 填该 Workshop ID 上传。
- **调参 hook**：Mod 启动时会读取 `user://auto-battler-overrides.json`
  （键名同 `--arb-*`，如 `{"proj": 1.25, "contact": 0.7, "room": 9}`），
  供 benchmark 搜索与高级用户微调使用；不影响普通玩家。
- **自动 benchmark / 参数标定**：见 [calibration/README.md](../calibration/README.md)；
  脚本会在本地反复启动游戏、跑固定场景并输出 `calibration/results.csv`。

## 十、CI/CD（GitHub Actions）

工作流（`.github/workflows/`）：

- **build.yml**：push / PR 时构建 zip，校验 zip 结构、manifest 版本与 `build.sh` 一致，上传 artifact。
- **release.yml**：push tag（`v2.3.0` 这种格式）或在 Actions 页面手动 `Run workflow` 时：
  - 构建并校验版本
  - 生成**单个发布整包** `AutoBattler-v<version>.zip`（内含 Mod 本体 + `preview.png` + `description.txt` + README/LICENSE/INSTALL）
  - 创建 GitHub Release，**只挂这一个附件**；SHA256 写在 release notes 里

**CI 不能直接上传 Steam Workshop**：Workshop 上传使用 Steamworks 客户端 UGC API，
需要一台已登录 Steam 的机器；GitHub 托管 runner 没有 Steam 客户端，`steamcmd` 也不支持
发布 Workshop 物品。因此发布流程是：

1. CI 出 GitHub Release（只有**一个**整包 zip）
2. 在 Windows（Steam 已登录）运行 `GodotWorkshopUtility.exe`：选该 zip、填 Workshop ID
   `3834096920`、Upload（预览图从 zip 内解压 `preview.png` 选择）；再把 zip 内的
   `description.txt` 贴到网页描述

如果以后想全自动同步 Workshop，需要 self-hosted Windows runner + GUI 自动化，脆弱且不建议；
更稳的是每次 release 后手动 2 分钟上传。

## 十一、许可与致谢

- 走位 AI、感知/决策核心来自开源项目 **[BOTato](https://github.com/boardengineer/botato)**
  （by boardengineer / Pasha），**MIT License**，见 `mod/LICENSE`。
  本仓库只做：瘦身（删除自动决策/联机/调试层）、默认开启、配置/HUD、打包与文档。
- 游戏本体与 ModLoader 版权归 Brotato 作者（Blobfish）与 Godot Modding 社区所有。
