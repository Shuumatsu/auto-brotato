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
> `~/Library/Application Support/Steam/steamapps/workshop/content/1942280/3598984651/AutoBattler-2.2.2-fork.zip`
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
3. 把构建好的 `dist/AutoBattler-2.2.2-fork.zip` 复制进该目录（loader 会加载该目录内**所有** zip）。

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
3. 选择 `dist/AutoBattler-2.2.2-fork.zip` 作为 mod 包，按工具提示创建/更新一个 Workshop item
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

## 六、验证状态（诚实说明）

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
├── build.sh                     # 构建 dist/AutoBattler-2.2.2-fork.zip
├── dist/
│   └── AutoBattler-2.2.2-fork.zip
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
- **release.yml**：push tag（`v2.2.2` 这种格式）或在 Actions 页面手动 `Run workflow` 时：
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
