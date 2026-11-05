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
