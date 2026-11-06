# Steam Workshop 发布步骤（只需要你点几下）

上传工具已经帮你打开（GodotWorkshopUtility），文件也都准备好了。

## 1. 在 GodotWorkshopUtility 窗口里

| 字段 | 选择/填写 |
|---|---|
| **Mod file**（点 Select Mod） | `workshop/AutoBattler - Movement Autopilot v2.4.0.zip` |
| **Preview image**（点 Select Preview） | `workshop/preview.png` |
| **Workshop ID** | `3834096920`（更新已有物品） |
| **Tags** | 选 `Utilities`，可选再加 `New Mechanics` |
| 然后点 **Upload** | 会创建 workshop item 并上传 zip |

- 若弹出 **Steam Workshop Legal Agreement**：会在 Steam 覆盖层/浏览器打开，需要你本人接受一次。
- 上传成功后窗口 console 会显示 `Workshop item created successfully. Please take note of the generated workshop ID.`，
  以及 `Item successfully uploaded.`。**把那个 Workshop ID 记下来**（后面更新/回填描述要用）。

## 2. 上传后在 Steam 创意工坊页面补充

上传工具只设置标题（来自 zip 文件名）、预览图、标签和内容，**不设置描述和可见性**。请在
Steam 创意工坊页面（Steam 客户端 → 社区 → 创意工坊 → 你的物品 → 编辑）里：

1. 把 `workshop/description.txt` 的内容粘贴到 **Description**（支持 BBCode）；
2. 视需要设置 Visibility（默认 Public；想先私下测试可改 Unlisted/Private，Steam 仍可订阅）；
3. 保存。

完成后告诉我 Workshop ID / 页面链接，我会继续下一步（自动 benchmark + 参数标定）。

## 已知问题（macOS + 同账号 Windows 在线）

如果 Mac 和 Windows 同时登录同一 Steam 账号，Mac 上启动 GodotWorkshopUtility 后
Steam 日志可能出现：

```
Logged In Elsewhere
Upload workshop item ... failed (Failed to initialize build on server (No Connection))
```

这是 Steam 会话层面的冲突，不是网络/Mod 问题；上传工具本身不含登录逻辑。
**建议直接在 Windows 上更新**：

1. 把 `workshop/AutoBattler - Movement Autopilot v2.4.0.zip` 传到 Windows；
2. 在 Windows 的 Brotato 目录运行 `GodotWorkshopUtility.exe`；
3. Select Mod → 该 zip；Workshop ID → `3834096920`；Upload；
4. 在网页编辑物品，粘贴 `workshop/description.txt`。

不要在 Mac 上反复启动/重启上传工具；也不要在弹出的登录页登录。

## 从 GitHub Release 下载时

GitHub 会把附件名里的空格替换成点（如 `AutoBattler.-.Movement.Autopilot.v2.4.0.zip`）。
上传工具会用 zip 文件名当 Workshop 标题，所以**下载后请重命名回**
`AutoBattler - Movement Autopilot v2.4.0.zip` 再选择。
