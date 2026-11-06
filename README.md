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
- ✅ **DLC 适配（v2.4.0）**：默认主动交战诅咒怪（DLC1）与机械/异变进化怪（DLC2），主动踩进化物品
- ✅ 远程 build 保持射程边缘风筝，不再贴脸（v2.3.0）
- ✅ 每帧不只贪心一步：2 步前瞻规划 + 受击后临时提高警戒（v2.3.0）
- ✅ 从实时 build 数据推导角色行为，不需要逐角色手写表
- ✅ 默认开启，`Shift + Space` 随时接管；HUD 显示状态
- ✅ 只装 2 个最小扩展：**不会替你买、刷、锁、升级、开箱、点下一波**
- ✅ 单人 Brotato 1.2.0.1 实机验证

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
