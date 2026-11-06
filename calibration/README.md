# 自动 benchmark / 参数标定（本地版）

这里的脚本用**本地安装的 Mod**（不依赖 Workshop）反复启动真实游戏，跑固定场景，
收集指标后用搜索算法挑参数。发布才用 Workshop（当前物品被 Steam 移除，见下）。

## 数据流

```
calibration/candidates.json   （候选参数，写入 user://auto-battler-overrides.json）
        + calibration/scenarios.json （角色 + 难度，写入 user://harness_scenario.json）
        ↓
dist/AutoBattler-*.zip + LocalTest-Harness.zip  → 游戏工坊目录
        ↓
Steam 启动 Brotato（每局一个进程）→ [HARNESS] 日志
        ↓
calibration/results.csv（每局 reason / min_hp / move_ratio / duration / profile）
```

- Mod 启动时会读取 `user://auto-battler-overrides.json`（键名同 `--arb-*`，如
  `{"proj": 1.25, "contact": 0.7, "room": 9}`），用于参数搜索；正常玩家也可以用它做微调。
- 测试 harness 只放在 `_research/harness-mod/`，不随 Mod 发布。

## 运行前检查

1. Steam 已登录并在线；游戏通过 Steam 启动（首次可能弹出"踢掉其它会话"提示，需要人点一下）。
2. 关闭正在玩的游戏；脚本会临时禁用其它 8 个 Mod（结束时恢复）。
3. 脚本需要写 Steam/Brotato 用户目录，运行时给足文件权限。

## 跑一次 pilot

```bash
cd /Users/akatsuki/workspace/auto-brotato
python3 calibration/run_pilot.py --repeats 1
# 结果: calibration/results.csv
```

默认 4 个候选 × 3 场景 × 1 次 ≈ 12 局（每局约 35–45 秒，含启动），约 8–10 分钟；
期间会多次自动开合 Brotato 窗口。

## 评估指标（先看这些）

- `reason=WAVE_CLEARED_TIMER` vs `DEATH` / `TIMEOUT`（清波率）
- `min_hp` / `max_hp`（伤害承受）
- `move_ratio`（走位有效性：0 表示几乎不动，1 表示持续移动）
- `duration`（清波时间；太慢说明过于保守）

## 已知限制

- 每局是独立进程，启动开销 ~15s；暂未做单进程多局。
- 难度/角色组合少，统计噪声大；先做 coarse search，再对 top 候选用多 repeat 复核。
- 参数搜索空间先限定在 `proj / contact / dash / room / wall / lethality / horizon` 等连续权重；
  角色 profile 已由 build-trait 自动推导，不在这里手调。

## Workshop 状态

物品 `3834096920` 创建并上传成功（Steam 日志确认），但被 Steam 标记为
"removed from the community because it violates Steam Community & Content Guidelines"
（仅自己可见）。建议申诉/查通知，确认原因前不重复上传；本地开发不受影响。

## Pilot 结果（2026-11-05，Danger 3，第 1 波，n=1/场景）

4 个候选 × 3 角色 × 1 次，共 11 局有效（首局因 Steam 提示 NO_LAUNCH）：

| 候选 | 有效局 | 清波 | 平均掉血 | 最低 HP | 平均 move_ratio |
|---|---|---|---|---|---|
| baseline | 2 | 2 | 1.00 | 10/11 | 0.86 |
| less_contact (contact=0.7) | 3 | 3 | 2.00 | 7/11 | 0.91 |
| more_room (room=9) | 3 | 3 | 1.67 | 7/11 | 0.89 |
| safer_bullets (proj=1.25,contact=0.8) | 3 | 3 | 2.00 | 7/11 | 0.89 |

结论：**pipeline 跑通**（12 局、自动启停、日志解析、Mod 隔离/恢复全部正常），
但 D3 第 1 波太短/太轻，n=1 噪声大，**不足以改默认权重**。下一轮设计：

- 用 `scenarios_hard.json`（Danger 6）放大差异；
- 每个候选至少 3 次 repeat，角色覆盖远程/站桩/近战；
- 只看 `clear` 率 + 平均掉血，必要时看 `calibration/logs/` 里的 profile/错误；
- 胜出候选再用 D0 原场景回归，确认没有“为了活而过度保守”。

结果文件：`calibration/results.csv`；每局日志：`calibration/logs/`。


## 第二轮：Danger 6 wave1（3 候选 × 3 角色 × 2，18 局）

| 候选 | n | 清波 | 平均掉血 | 最低 HP |
|---|---|---|---|---|
| baseline | 6 | 6 | 2.67 | 3 |
| more_room_wall (room=9, wall=20) | 6 | 6 | 2.00 | 5 |
| safer_bullets (proj=1.25, contact=0.8) | 6 | 6 | 2.50 | 5 |

## 第三轮：Danger 6 从 wave 3 开始（3 候选 × 3 角色 × 2，18 局）

| 候选 | n | 清波 | 平均掉血 | 最低 HP | 备注 |
|---|---|---|---|---|---|
| baseline | 6 | 5 | 3.67 | 2 | Soldier 1 次死亡 |
| more_room_wall | 6 | 6 | 4.67 | 5 | Ranger 掉血更少，Knight/Soldier 更多 |
| safer_bullets | 6 | 6 | 3.83 | 3 | 与 baseline 接近 |

结论（重要）：**没有跨角色一致的赢家**——more_room_wall 改善 Ranger，却让 Knight/Soldier 掉血更多；
差异都在单波小样本的噪声范围内。因此 **2.2.1 默认权重保持不变**，不要把这次结果当成调参依据。
真正有意义的下一步是"完整 run（多波）胜率"目标 + 按 archetype 分组参数，而不是单波掉血。

## v2.3.0 策略 A/B（树/果子/远程 kiting/多步规划）

配套设计：`_research/strategy-v230-design.md` §3.4/§4C/§5；遥测来自 harness 的
`extensions/main.gd`（`_research/harness-mod/src/`，打包成 `_research/harness-mod/dist/LocalTest-Harness.zip`）。

### 新增遥测（逐秒 `[HARNESS] t=` 行，追加在原字段后面）

| 字段 | 含义 |
|---|---|
| `us=` | arbiter 单次决策耗时（微秒，`_movement_behavior.last_arb_us`） |
| `nearE=` | 最近活敌人距离 px；场上无活敌时为 `-1`（不进中位数） |
| `wrange=` | 当前远程武器最大射程 px；全近战为 `0` |
| `trees=` | 本局已砍树（neutral 死亡）计数 |
| `fruit=` | 本局已吃 consumable 计数（含箱子；`already_picked_up` 去重） |
| `gold=` | 当前材料 |
| `ground=` | 地上剩余 consumable 数 |
| `plan= / adapt=` | 可选 plan/adapt 状态（1=开，0=关，-1=该 build 未上报） |

`RESULT` 行追加：`trees= fruit= gold= nearE_median= us_avg=`（中位数只统计有敌人的秒；
`us_avg` 为逐秒样本均值，整数微秒）。`run_pilot.py` 的 CSV 末尾新增
`trees,fruit,gold,nearE_median,us_avg` 五列（旧 CSV 仍可读），summary 里额外打印
`nearE/wrange` 中位数（§5 门槛指标）和每候选的 trees/fruit/gold/us 均值。

### 跑法

**前置（必看）**：A/B 前先 `./build.sh` 用新 `mod/` 源码重新生成 `dist/AutoBattler-*-fork.zip`。
`--build` 默认取 `dist/AutoBattler-*.zip` 里最新的 **`-fork`** 包（自动排除 `AutoBattler-v*.zip` 发布整包，
按文件 mtime 取最新）。启动日志里的 `[calib] build: ...` 必须是你刚构建的包；否则三组 override
会被旧 build 忽略、结果全部一样。

```bash
cd /Users/akatsuki/workspace/auto-brotato

# S1+S2（Ranger：D6 wave3 kiting + D3 wave1 economy）：3 候选 × 2 场景 × 3 repeats = 18 局
python3 calibration/run_pilot.py --repeats 3 \
  --scenarios calibration/scenarios_strategy.json \
  --candidates calibration/candidates_strategy.json \
  --out calibration/results_strategy.csv

# S3 回归（Ranger/Soldier/Knight D6 wave3，看 full 是否伤害其它角色）：3 × 3 × 2 = 18 局
python3 calibration/run_pilot.py --repeats 2 \
  --scenarios calibration/scenarios_wave3.json \
  --candidates calibration/candidates_strategy.json \
  --out calibration/results_strategy_s3.csv

# 需要固定某个包时：--build dist/AutoBattler-2.3.0-fork.zip（相对仓库根或绝对路径均可）
```

候选（`candidates_strategy.json`）：`control`（kite/tree/food/plan/adapt 全 0 = 旧行为）、
`tactics`（kite/tree/food=1，plan/adapt=0）、`full`（空 overrides = 新默认）。

时长：每局 = 启动 ~10–15s + 波次 20/30s + 收尾 ~5s，约 45–60s；18 局 ≈ **15–20 分钟**/轮，
两轮全跑 ≈ **30–40 分钟**（含 Steam/ModLoader 加载）。期间会自动多次开关 Brotato 窗口。

### 结果怎么看（design §5.3 门槛）

- `calibration/results_strategy.csv` 每局一行；`status=OK` 才算有效局。失败启动（`NO_LAUNCH`/`NO_LOG`）
  会自动重试一次。
- 脚本结尾的 summary：`trees/fruit` 显著 > control；`full` 的 `nearE/wrange` 中位数应 ≥ control +15%
  （ranged kiting 生效的直接证据）；`dmg`（平均掉血）/`clear` 不能显著变差；`us` < 2× control 且不卡帧。
- 逐秒原始日志在 `calibration/logs/<candidate>_<character>_d<difficulty>_r<repeat>.log`
  （可 grep `plan=`/`adapt=` 确认 full 组确实启用了规划/自适应）。
- 注意：S1 与 S3 都有 Ranger D6 wave3，同一 candidate 的逐秒日志文件名相同（CSV 各自独立）。
  S3 会覆盖 S1 的 ranger D6 r1/r2 原始日志（同一场景/候选，数据等价）；若必须保留 S1 原始日志，
  先 `cp -R calibration/logs calibration/logs_strategy` 再跑 S3。
- n=3/格仍是粗筛：结论只看方向一致且跨 repeat 稳定的差异，单局异常不要当依据。

## v2.3.0 实测结果（2026-11-06）

| 轮次 | 场景 | 臂 | n | 清波 | 平均掉血 | 最低 HP | nearE/wratio | 决策 us |
|---|---|---|---|---|---|---|---|---|
| 1.0x A/B | Ranger D6w3+D3w1 | control | 6 | 6/6 | 2.00 | 4 | 0.382 (D6) | 391 |
| 1.0x A/B | 同上 | tactics | 6 | 6/6 | 2.17 | 4 | 0.339 (D6) | 419 |
| 1.0x A/B | 同上 | full | 6 | 6/6 | 2.00 | 5 | 0.401 (D6) | 726 |
| 2.0x 调参 | Ranger ×3 场景 | control | 3 | 2/3 | 3.00 | 1 | 0.31 | 433 |
| 2.0x 调参 | 同上 | full | 3 | 2/3 | 1.67 | 4 | 0.55 | 1131 |
| 2.0x 调参 | 同上 | strong | 3 | 2/3 | 2.67 | 2 | 0.49 | 968 |
| 3.0x 确认 | Ranger D6w6 | control vs full | 3/臂 | — | 生存 15.7s vs 17.7s | — | — | — |
| 3.0x 确认 | Soldier D6w3 | control vs full | 3/臂 | 3/3 vs 2/3 | 7.0 vs 9.0 | — | — | — |

结论（如实）：**没有一致退步，也没有显著变强**；默认权重（kite10/tree1/food2.5/plan1/adapt1）优于
更强的 tactics 版本（strong 更差），所以没有继续加大。真实差异更可能出现在玩家自己的中后期 build 上，
建议用 `--arb-plan=0` / `--arb-kite=0` / `--arb-tree=0` / `--arb-food=0` 做个人 A/B。
结果文件：`results_strategy.csv`（1.0x）、`results_tune.csv`（2.0x）、`results_final.csv`（3.0x 混合）、
`results_confirm.csv`（3.0x 确认）。

## 测试加速（v2.3.0 harness 新增）

`user://harness_scenario.json` 现在支持 `"speed"` 字段（由 `run_pilot.py` 从 scenarios JSON 原样写入）：

- `"speed": 2.0`（裸加速）：harness 在 Main `_ready` 里设 `Engine.time_scale = 2.0`，
  30s 波约 15s 实际时间。物理 tick 仍 60/s → **AI 每游戏秒的决策数减半**，只适合相对 A/B。
- `"speed": 3.0`（补偿模式）：同时 `Engine.iterations_per_second = 60*s`（运行时 settable），
  每个物理 tick 的游戏时间仍是 1/60 秒，AI 决策频率/帧计数/碰撞粒度与 1x 一致；CPU 随 s 线性增加。
  本仓库 3x 批次用的就是它（日志会打印 `[HARNESS] time_scale=3 physics_fps=180`）。
- 更高倍数（4-6x）harness 允许，但决策耗时 × 物理帧率会吃满 CPU，收益递减；建议 2x 粗筛、3x 确认。
- 单局时长估算：`启动 10–15s + 波次秒数/speed + 收尾 ~5s`，2x 下每局 ~30-40s，3x 下 ~25-35s。

## v2.3.0 驱动脚本修复（实测踩坑）

1. **注入目标动态选择**：ModLoader 只加载 Steam 已订阅 item 里的 zip。旧版硬编码的
   `3598984651`（Mod Options）可能已不再订阅（`appworkshop_1942280.acf` 里没有它），会导致
   "No zipped mods found" → 整个 benchmark 跑空。现在 `pick_mod_item()` 从 acf 的
   `WorkshopItemsInstalled` 里挑第一个已订阅目录，并**永远跳过用户自己的 AutoBattler 工坊物品**
   （否则会加载第二份同名 mod，遮蔽被测 build）。
2. **禁用范围修正**：除了注入目标，**所有**其它 item 的 zip 都要移到 `_disabled_by_calibration/`
   （包括用户已发布的 AutoBattler 整包）；跑完 `restore_mods()` 恢复。
3. **日志名带 start_wave**：`..._d<difficulty>_w<start_wave>_r<rep>.log`，避免 D6 wave3 / D6 wave6
   两个场景互相覆盖逐秒日志；CSV 增加 `start_wave` / `speed` 列。
4. 注入目标是别人的工坊 item：`cleanup_test_mods()` 现在也会删掉注入进去的 `AutoBattler-*.zip`，
   恢复时把原 item 内容放回。

## v2.5.0 规划层 A/B（真机，待跑）

设计/根因：`_research/planning-v250-design.md`；离线门禁：`_research/planning-v250/gate/`；
真机 runbook：`_research/planning-v250/bench.md`。

- 候选：`calibration/candidates_v250.json`（control = 7 个新开关全 0 = v2.4.0 精确行为；
  planning = 出厂默认；可选 no_breakout/no_goal 归因臂）。
- 场景：`calibration/scenarios_v250.json`（D6 wave6 压力组 + D3 wave7 evolution_mult=20 物品组）。
- 命令：
  ```bash
  python3 calibration/run_pilot.py --repeats 3 \
    --build dist/AutoBattler-2.5.0-fork.zip \
    --scenarios calibration/scenarios_v250.json \
    --candidates calibration/candidates_v250.json \
    --out calibration/results_v250.csv
  python3 _research/planning-v250/summarize_v250.py \
    --glob 'calibration/logs/*_v250*.log' --csv-out _research/planning-v250/results_v250.csv
  ```
- 指标：压力组看存活/清波/min_hp + harness 新遥测 `breakouts=`（0 说明功能没触发，不代表没收益）；
  物品组看 `evo_picked` / `goals=` / `goal_d=`。小样本（2 臂 × 4 场景 × 3 repeats = 24 局，
  约 15–18 分钟）只作方向性判断。
