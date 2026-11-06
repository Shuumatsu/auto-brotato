# AutoBattler v2.9 — 系统性实现质量审查（review-v3）

日期：2026-11-06。审查基线：`e10aae1`（AutoBattler v2.8.0），Brotato 1.2.0.1 / Godot 3.6.1。
交付 commit：`a247503`（tracked tests + CI）、`4d39995`（v2.9.0 代码 + 控制臂 pin）、`2c04983`（文档/审查报告）。

本审查遵循的纪律：

- **文档与注释不作为论据**；所有结论引用可复现命令、运行输出、`.tres`/反编译源码行号或依赖结构。
- 不以“代码现在这么写”证明其合理；代码本身就是审查对象。
- 四个并行审计各自给出 `FINDINGS.md`（含证据命令/脚本、file:line、分级、建议），Lead 独立复跑关键项并复核。

证据目录（本地工作区，均在 gitignored `_research/` 内）：

| 审计 | 报告 | 备注 |
|---|---|---|
| 架构/依赖/接口/死代码 | `_research/review-v3/arch/FINDINGS.md` | 15 条（S1×5/S2×5/S3×4/S4×1）+ 9 个复现脚本 |
| 经济目标行为 | `_research/review-v3/econ/FINDINGS.md` | 8 条（S1×2/S2×3/S3×2/S4×1）+ headless 探针 + 闭环 sim |
| 验证完整性 | `_research/review-v3/verify/FINDINGS.md` | 15 条（S1×2/S2×4/S3×4/S4×5）+ 全量复跑日志 |
| 游戏数据机制 | `_research/review-v3/gamedata/FINDINGS.md` | 12 个 GAP + 114 行效果证据表 + 验收期望 JSON |

---

## 1. 结论摘要

1. **目标函数确实以生存为主、经济为辅，但问题比“生存优先”更具体**：经济项在准入闸门关闭时只有 1.5–7.1 单位（威胁 11.8–65），而闸门是**硬二元**的（单个 body 在线即可拒绝中价值资源，route risk 按直线最坏情况计、无绕行信用）；一旦获准承诺，经济拉又可到 14.8–28.8（与威胁同级）。真正缺陷是“准入形态 + 价值模型错误 + 无全局/时间规划”，不是单纯权重太小。
2. **“满血无视果子/树”部分成立，但正确的修复不是盲目加价值**：普通 build 满血果子的永久 stat 收益在**波末自动回收**时同样触发（game `player.gd:1072-1088`），波内提前吃只提前 1 波生效；真正有波内增量的是 Penguin/Cauldron/爆炸等 **mid-wave-only** 效果、受伤时的即时治疗、gold pickup 触发，以及 **LOST_AT_HORN**（meca/mutant fruit、Veteran fruit）。树是唯一会被波末销毁且不掉落的资源，缺 deadline 规划。crate/legendary 的 item choice 本来就在 horn 到账，v2.8 的波内绕路定价（20/34）在机制上是浪费。
3. **结构性问题成立且可量化**：两个 3k 行 god object、无 schema 的 tuple ABI（8 种元数/51 处裸索引）、57 个 public mutable 输出字段、12 个契约常量镜像、3 个 `--arb-*` 解析器 + 2 旁路（`sweep`/`orbit` 真实冲突）、pmb 84/92 const 死代码、8 个版本从未删函数、45 份源码副本；静态 import 无环，但 world_view⇄arbiter 存在契约/配置双向知识。
4. **验证体系此前不可信**：v2.8 的 world_view 探针宣称 32/32，实际 32/2 FAIL 且脚本仍 exit 0（用 `git show HEAD` 冒充冻结 e933740）；唯一执行 world_view 行为的 dlc-selftest 在 HEAD 上 205 checks/42 fails；全部 harness 位于 gitignored `_research/`，clean clone 无任何离线测试，CI 只打包不测试；用户核心经济行为零有效断言。
5. **已实施修复**（详见 §4）：Step1 结构重构（contract/config 单一化、pmb 死代码清理、harness 可测新模块，行为逐字节等价）；Step3 验证基建（tracked `tests/` + CI、冻结参考修复、原有 470/2476/32 断言全部可复现；clean clone 6 套件全绿）；Step2 经济目标层 v2.9（`economy.gd` + `econ_planner.gd` + `--arb-econ`，默认开，`=0` 精确 v2.8.0 控制臂）——验收见 §4.3。

---

## 2. 用户假设逐条判定（证据）

### 2.1 “现在的目标聚焦于生存？”

**成立，但需要精确化。** 同场景量级（econ F1/F8，headless 探针 `logs/p1_magnitude.log`）：

| 场景 | 经济项 | 生存项（威胁） |
|---|---|---|
| crate@300px，空旷 | per-step 7.13 / commit 16.80 | 0 |
| tree@300px，空旷 | per-step 1.55 / commit 4.08 | 0 |
| gold@300px，空旷 | per-step 1.71 / commit 0 | 0 |
| 单 body@200px（6 dmg 静止） | — | 11.77（同场景生存相关合计 17.89） |
| body 在线上 + crate@400 | per-step 2.81；commit=0（闸门拒绝） | 11.77 |

- 普通拾取项是 tie-breaker；但机会层一旦承诺，拉可达 14.8–28.8（≈威胁同级）。所以准确说法是“**安全窗口内经济可以与威胁同级，窗口外为 0**”。
- 准入是硬闸门：`risk <= value*(0.10+0.20*agg) + 2*agg`（agg=1 → value×0.30+2）；路线风险用直线单次最近接近、全额 damage×ticks，无绕行/闪避信用。实测 crate（表值 20，允许风险 8.0）在 200/300/380 px 有 body 时全部被拒（route_risk=9.60），legendary（34，允许 12.2）才能通过。

### 2.2 “满血几乎无视果子/树？”

**果子：条件成立；树：部分成立，且真正的缺口是波末损失与视野。**（econ F3/F4/F6，gamedata §2/§3/§4）

- 满血果子 reward：generic（未列 food mode）= 不发射（0）；auto 推断普通 kit = **bank → -0.8（负成本主动回避）**；Farmer/Druid 等 full_hp = 6.0；Chef/Glutton bomb 空场 = -1.5。受伤时统一 `2.5*min(12,missing)`，最高 30。
- **机制真相**（游戏数据）：普通 fruit/box 在 horn 由游戏自动回收（`consumable_data.gd:5` 默认 `attracted_at_end_of_wave=true`；`main.gd:1278-1300`），永久 stat（`consumable_stats_while_max`）在 horn 回收时仍触发（`player.gd:1072-1088` 无 cleaning_up 保护）；`temp_consumable_stats_while_max`（Penguin）/`decaying_stats_on_consumable`（Cauldron）/爆炸在 horn **不触发**；meca/mutant fruit 不回收；Veteran 的普通 fruit 不回收；未倒的树在 horn 被 `entity_spawner.gd:702-703` 销毁且 `main.gd:646` 不掉落。
- 治疗真相：fruit heal = `max(0, 3 + consumable_heal)`（`fruit_effect.tres` value=3、`consumable_healing_effect.gd`），当前 `2.5*min(12,missing)` 在 missing=12 时给 30，**高估约 10x**；Vampire（-100）等 build 在 auto 推断下仍被赋予 30 幽灵治疗价值。
- 树：安静场地会主动去（100/300/600px goal/opp 承诺、dot=1.0），body 距树道 60px 即放弃；900px 外不可见；**波末无紧迫性**（未倒的树会真正损失）。树掉落：3 materials（受 gold_drops 修正）+ 必掉 1 consumable（20% 为 item box）；Cryptid 活树每棵波末 +12 materials → 砍树负收益。

### 2.3 “只关注周围一定范围、没有全局观？”

**成立**（econ F5）：consumable/gold/tree 在 `PICKUP_RANGE=900` 硬截断（1000/1300px 资源不可见）；7 个散布资源只发出 5 个；机会层一次只承诺 1 个目标；special target 容量 8（`OPP_SPECIAL_MAX`）；threat 视野 620 / target reach ~620-680，只有 special 有 900/1400/1600。

### 2.4 “拾取行为本身经常带来额外效果？”

**成立且覆盖不足**（econ F7、gamedata §1/§5）：游戏侧 33 类/114 条 pickup 触发 effect；mod 已建模 dmg/reload/harvesting/vacuum/stand-income 等；**未建模**：`heal_when_pickup_gold`（Cute Monkey）、`chance_double_gold`（Metal Detector）、`increase_material_value`（Buccaneer +100%）、`item_box_gold`（Bag +15/箱）、**武器级** `reload_when_pickup_gold`（Blunderbuss）、`stats_on_fruit`（Druid 33% luck）、`decaying_stats_on_consumable`（Cauldron）、`consumable_heal` 实际治疗量、`no_fruit_attracted_end_of_wave`（Veteran）、`trees`/`trees_start_wave`/`gold_drops`。

### 2.5 “重构遗留了结构性问题？”

**成立**（arch FINDINGS 全 15 条，摘要见 §3）。

### 2.6 “是否存在循环依赖？”

静态 import 层**证伪**（preload 图很小且无环：pmb→{arbiter, world_view}，main_menu→options）；但 world_view⇄arbiter 存在**契约/配置双向知识**（同一 tuple schema、枚举值、`--arb-*` key 空间两侧各解析一份），属于语义环而非 import 环。

---

## 3. 缺陷清单（去重后按严重度）

### S1（核心结构/行为错误）

1. **两个 3k 行 god object**：world_view 3125 行/59 函数/7 职责簇（抽取、威胁几何、经济定价、角色策略表+推断、配置、目标估值、遥测）；arbiter 3047 行/29 函数/7 簇（`_cost()` 539 行 11 个策略项、`choose()` 467 行 5 个模式分支）。（arch F-01/F-02）
2. **无 schema 的 tuple ABI**：8 种元数（2/3/4/5/6/7/8/9）、生产者裸字面量、消费者 51 处裸索引、`corridor[3]` 就地补位、可选第 9 字段用 size 判定。（arch F-03）
3. **57 个 public mutable 输出字段**：`gather()` 写 17 个公开字段，shell 读 12 个 + `profile` + `tap_cd`，再以 13 个位置参数喂 `choose()`；`last_scores[24]` 魔数泄漏到 shell。（arch F-04）
4. **契约常量两端镜像**：KIND×5、OPP_TAG×5、OPP/COV×2 + special class 魔数 + 3 条无链接值耦合；当前一致纯属源码巧合。（arch F-05）
5. **配置分片/冲突**：`--arb-*` 由 3 个解析器 + 2 个旁路解析；`sweep` 在 world_view 内解析两次（刀刃并集 vs 材料倍率互相污染）；`orbit` 跨模块同名异义（Boss 挂载弹幕扫描 vs perimeter 环绕权重）。（arch F-06）
6. **机会层硬二元闸门 + 路线风险无绕行信用**（econ F2）。
7. **满血果 -0.8 负成本方向错误**（econ F3）。
8. **v2.8 world_view 探针不可复现**（32/2 FAIL 且 exit 0，HEAD 冒充冻结参考）；**唯一 world_view 行为套件 dlc-selftest 红**（205/42）。（verify V-01/V-02）

### S2（重大缺口）

9. 无全局视野：900px 截断 / 单承诺 / special 容量 8（econ F5）。
10. 波末只有 meca/mutant fruit 有紧迫性；树会真实损失却无 deadline（econ F6）。
11. 价值模型错误：治疗按 missing_hp×2.5（实际 heal=3+modifiers，高估 ~10x）；Vampire 幽灵治疗；Glutton 满血果 -1.5 惩罚；crate/legendary 把 auto-vacuum 的 item choice 当波内绕路理由；Cute Monkey/Bag/Buccaneer/Druid/Cauldron 等触发效果未建模（econ F3/F7、gamedata GAP-01..12）。
12. 全部 harness 在 gitignored `_research/`；clean clone 零离线测试；CI 不跑测试；用户核心行为零有效断言（verify V-03/V-04/V-05）。
13. pmb 旧势场控制器残骸：84/92 const、20/39 var、104/131 声明行无读者（arch F-07）。
14. arbiter 休眠/legacy：`_update_goal/_update_bounty`（135 行）默认不可达、27 个 write-only var、`w_predict=0` 未验证、`CHARACTER_PROFILES` 244 行默认不执行（arch F-08）。
15. 每版永久保留 exact-control-arm：8 个版本从未删除函数，`--arb-*` key 40→60/22→37（arch F-09）。
16. 源码副本/产物漂移：45 份源码副本（arbiter 11/22 stale）、dist 旧包、harness 5 处固定单文件复制（arch F-10）。

### S3/S4

17. 命名/命名空间扁平化（383 个顶层 const、0 enum、同名异义）；telemetry 散落且无消费者；游戏 API 只在一侧隔离；无架构门禁（arch F-11..F-15）。
18. 验证：探针脚本不以 RESULT 为退出条件；历史轮次数字不可复现；470/32 中约一半是自指 invariant；F2 阈值过松；校准未闭环（仅 v2.2–v2.4 真机数据）、CSV 缺列/缺 build provenance（verify V-06..V-15）。

---

## 4. 已实施修复（对应 commit）

### 4.1 Step1 结构重构（行为保持）

- 新增 `steering/contract.gd`（tuple schema/枚举单一事实来源；新增 `R_POS..R_TAG`、`SPECIAL_*`）与 `steering/config.gd`（唯一 `--arb-*` 解析器，合并原 3 解析器 + 2 旁路；修复 `sweep`/`orbit` 冲突，旧 key 语义保持并 WARN；96 key 全部接受）。
- `world_view.gd`/`arbiter.gd` 改用 `apply_config(cfg)`；裸 tuple 索引 51→~0；pmb 356→123 行（删 85 const + 31 var + 死 telemetry/heading 状态）。
- 等价证据：闭环 sim 616 行与 HEAD 基线**逐字节相同**；planner 470/0、gate 32/0、worldview 32/0、dlc 297/0、字段等价 220/0、机械一致性 73/0；性能在噪声内持平。

### 4.2 Step3 验证基建（tracked commit `a247503`）

- `tests/`（93 文件 tracked）：check_gd（覆盖 mod 全部 `.gd` + selftest）、planner（470 + falsifier 2476，冻结 ref 用 `git show` pin）、gate（32）、worldview（32，修复了 HEAD 冒充冻结参考的 bug）、sim（52 次调用 + 74 条机器断言，替换人工 diff）。
- `tests/run_all.sh` 单入口、失败非 0；CI `build.yml` 增加 `test` job（Godot 3.6.1 headless、`fetch-depth: 0`）。
- clean clone（仅 tracked 文件、无 `_research/`）实测 **6 套件全绿**（check_gd 1s / selftest 12s / planner 7s / gate 24s / worldview 1s / sim 321s）。
- 反向验证：`REF_V27_COMMIT=HEAD` → 470/9 FAIL；`GATE_REF=HEAD` → 32/3；`REF_WORLDVIEW_COMMIT=dcb6e39` → 32/1；run_all 正确传播非 0。

### 4.3 Step2 经济目标层 v2.9（`--arb-econ`，默认开；`=0` 精确 v2.8.0）

- 新增 `steering/economy.gd`（纯数据定价：AUTO_AT_HORN/LOST_AT_HORN/MID_WAVE_ONLY/TREE/TRIGGER 分类；heal=min(missing,max(0,3+consumable_heal))；满血永久 stat 只给“提前 1 波”小正值；Penguin/Cauldron/爆炸波内正值；gold pickup-trigger；tree EV/Cryptid 负值；deadline 缩放）与 `steering/econ_planner.gd`（全局候选 + 连续风险预算 + deadline/sweep；旧元组回退 v2.8 路径）。
- world_view 在 econ=1 时写 `R_ECON_FLAGS`、资源 gather 半径扩展至全图、满血果不回退为负成本；arbiter 收到无 flags 旧元组时保持 v2.8 原路径（现有 470/32 不退化）。
- 验收结果（2026-11-06，证据 `_research/review-v3/econ/STEP2-RESULT.md`、`logs/step2/`）：
  1. **控制臂等价**：`--arb-econ=0` 的 world_view 输出对冻结 v2.8.0（`git show e10aae1`）在 5 个
     fake-world 场景下 targets/threats/rewards/profile/决策方向 **逐值 IDENTICAL**（diffs=0）。
  2. **游戏数据方向断言 46/46 PASS**：generic 满血果不再为负、Vampire 受伤果≈0、Glutton 满血果≥0、
     Farmer 正且随波次折减、Penguin/Cauldron 波内正值、meca/mutant/Veteran 标记 `LOST_AT_HORN`、
     box 不产生远距离波内绕路、tree EV 正值 / Cryptid 负值等。
  3. **既有套件不退化**（arbiter 侧）：`check_gd` PASS、planner-selftest 470/0、gate 32/0、
     world_view 固定参考 32/0、dlc-selftest 297/0。**注意**：world_view/gate 的这些 legacy 期望是
     v2.8 行为，需 `--arb-econ=0` 控制臂才能逐值复现；tracked 的 `tests/worldview` 已改为固定
     `econ=0` 控制臂。
  4. **未完成**：闭环经济 sim 的 econ=0 vs econ=1 矩阵（宿主内存耗尽、Godot fork EAGAIN 中断）、
     `tests/econ` 的 tracked 化、性能 ≤1.2×、真机 A/B。当前默认 `--arb-econ=1` 的行为只经过
     单帧 fake-world + 游戏数据方向断言，未经过整波闭环与真机验证。

---

## 5. 验收与剩余风险

本轮的验收分三层：

1. **结构等价层**（已完成）：Step1 的闭环 sim 逐字节 diff=0、字段等价 220/0、全部既有套件 PASS；
   Step3 的 tracked tests clean clone 6 套件全绿 + 5 条反向验证。
2. **经济层单帧/方向层**（已完成）：`--arb-econ=0` 对冻结 v2.8.0 5 场景逐值 IDENTICAL；
   gamedata 期望表 46/46 方向断言 PASS（见 §4.3）。
3. **经济层闭环/真机层**（未完成）：闭环 econ sim 矩阵（收益/生存不退化、auto 资源绕路下降）、
   性能 ≤1.2×、真机 A/B。宿主在运行这些时内存/进程耗尽（swap 32.7/33.8GB、`fork: Resource
   temporarily unavailable`），已按“不伪造结果”原则标注为未验证，而不是删除门槛或改期望变绿。

另：`.github/workflows/build.yml` 的 `test` job 已就位但**尚未在 GitHub runner 首跑**（本地等价验证
= clean clone + 本机 Godot 3.6.1）；CI 首跑后需确认 linux headless 行为一致（尤其 `GODOT_ARGS=""`）。

**2026-11-07 00:30 提交后 Lead 复跑（当前 v2.9.0 工作树）**：

- `tests/run_all.sh` 分套执行：check_gd **targets=10 loaded=10 PASS**、worldview **32/0 PASS**、
  planner **470/0 + falsifier 2476/0 PASS**、gate **32/0 PASS**；
- sim：单场景 `ring14_fast` 的 v28 行与 v27 **逐字段相同**（legacy 路径未受 econ 影响）；
  **完整 52 次调用矩阵未跑完**（宿主 `fork: Resource temporarily unavailable` 中断）；
- `bash build.sh` 同样因宿主 fork 失败未产出 zip（CI 会构建；版本字符串已同步 2.9.0）。

### 已知剩余风险

1. **无真机 A/B**：v2.5–v2.9 默认值均无真机校准数据（仓库最新真机 CSV 只到 v2.4.0）；本次经济目标改动默认 ON，必须由拥有 Steam/游戏环境的人用 `calibration/run_pilot.py` 复核（尤其：普通 build 是否少绕路、受伤时是否敢吃果、波末是否抢 lost 资源、生存不退化）。
2. 经济模型中的价值尺度（heal 每 HP 价值、tree EV、item choice 是否计入银行价值）依赖设计决策，本报告以“经济项 < 单次威胁量级”的保守约定处理，待真机数据校准。
3. dlc-selftest 红套件未迁移（已在 `tests/README.md` 记录红原因）；历史轮次验收数字仍不可复现（harness 未版本化）。
4. 结构重构为分阶段：Step1 完成了 contract/config/死代码；world_view/arbiter 的其余职责拆分（profile/威胁几何/规划器/telemetry）与 tuple→value class 化仍待后续迭代（arch FINDINGS §7 有完整迁移计划 M2–M6）。
5. 冻结参考依赖 git 历史完整（CI 必须 `fetch-depth: 0`）；sim 套件 ~5 分钟，占 CI 大头。
