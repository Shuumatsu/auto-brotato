# AutoBattler · Brotato 自动走位 Mod

**操作交给 AI，决策留给你。** 波次内自动走位/闪避/捡材料，商店、升级、开箱、下一波全部手动。

*Auto-move and dodge during waves. Every build decision stays yours.*

![preview](workshop/preview.png)

[![release](https://img.shields.io/github/v/release/Shuumatsu/auto-brotato?label=release)](https://github.com/Shuumatsu/auto-brotato/releases/latest)
[![license](https://img.shields.io/badge/license-MIT-blue)](mod/LICENSE)
[![Brotato](https://img.shields.io/badge/Brotato-1.2.0.1-4caf50)](https://store.steampowered.com/app/1942280/Brotato/)
[![Steam Workshop](https://img.shields.io/badge/Steam-Workshop-1b2838)](https://steamcommunity.com/sharedfiles/filedetails/?id=3834096920)

## 它做什么

- ✅ 自动躲子弹、冲锋、AOE 预警，自动捡材料/食物/树
- ✅ 从实时 build 数据推导角色行为，不需要逐角色手写表
- ✅ 默认开启，`Shift + Space` 随时接管；HUD 显示状态
- ✅ 只装 2 个最小扩展：**不会替你买、刷、锁、升级、开箱、点下一波**
- ✅ 单人 Brotato 1.2.0.1 实机验证

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
