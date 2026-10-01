# App 图标 / Logo（单一源，改这块前必读）

**全 App 只有一个 logo 源：`tools/AppIcon.png`。** 换 logo 改这一个文件即可全局生效，别在别处硬编码/自绘 logo。

传导链：
- `build.sh` 用 `sips` 把 `tools/AppIcon.png` 缩成整套 iconset → `iconutil` 打包 `AppIcon.icns`（Dock / Finder / 系统设置 / 通知 / 授权列表全用它）。
- App 内所有 logo 显示点都读 `NSApp.applicationIconImage`（= 运行时的 `AppIcon.icns`），不各自画：
  - 主窗口 header：`MainWindow.swift` `AppLogoMark`（`draw` 里画 `applicationIconImage`）
  - 会话 tab / popover 的 statsHeader：`Components.swift` `logoView.image = NSApp.applicationIconImage`
- ⚠️ `LogoBadge`（VS 蓝块 / asterisk 铜块）是**来源徽章**（区分 VSCode 组 / 桌面版组），**不是** App logo，换 logo 时别动它。菜单栏那颗是状态计数**文字**，也不是 logo。

**一步换 logo**：`./tools/set-logo.sh <图片> [--no-trim] [--no-build]` —— **默认 auto-trim**（检测四角同色 → 裁掉纯色/透明边框到图标 bbox，白底/黑底/任何单色都行；四角不一致的真实图像则不裁）→ 补正方形 + 加 macOS 圆角（22.37% 半径）→ 覆盖 `tools/AppIcon.png` → rebuild + `lsregister -f` + 刷 Dock。`--no-trim` 关闭裁边（图本身已是贴边圆角图标时用），`--no-build` 只更图不重建。手动做也行：替换 `tools/AppIcon.png` 后跑 `./build.sh`。也有封装好的 `/set-logo` skill（`.claude/skills/set-logo/`，给张图自动裁+放对地方+重建）。

- `tools/AppIcon-original.png` = 最初带黑边的原图备份；`tools/make-icon.swift` = 早期用 Core Graphics 画图标的脚本（已不参与 build，留作参考）。
