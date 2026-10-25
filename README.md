<div align="center">

<img src="docs/icon.png" width="120" alt="清醒 Qingxing"/>

# 清醒 Qingxing

**macOS 菜单栏防睡眠小工具**

**合盖不休眠 · 关屏不中断 · 按电源条件生效**

简体中文 ｜ [English](README.en.md)

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-blue)
![Architecture](https://img.shields.io/badge/arch-arm64%20(Apple%20Silicon)-green)
![Swift](https://img.shields.io/badge/Swift-5-orange)
![License](https://img.shields.io/badge/License-MIT-blue)

</div>

---

## ✨ 功能特性

- 🌙 **合盖继续工作** —— 合上盖子（扣盖）Mac 照常运行，屏幕自动关闭，任务不断
- 🌑 **关屏继续工作** —— 盖子开着、屏幕熄灭，系统保持唤醒，下载 / 编译 / 跑任务不中断
- ☀️ **屏幕常亮** —— 屏幕和系统都不进入睡眠
- ⚡ **生效条件可选** —— **始终 / 仅插电源时 / 仅用电池时**，插拔电源自动切换（本项目与同类工具的核心差异）
- 🎯 **App 触发** —— 指定 App（终端编译、Docker、下载器、AI 助手…）运行时自动保持唤醒，全部退出后自动恢复
- 🔑 **免密模式（可选）** —— 一次性安装白名单特权助手后，切换合盖模式、电池自动保护都不再需要管理员密码
- 🛡️ **电池保护** —— 用电池且电量低于阈值（10–30% 可调）时自动关闭全部防睡眠模式，防止放包里耗尽电量
- 🔍 **启动自检** —— 检测上次异常退出留下的残留设置（闲置睡眠被改为"永不"）并自动修复
- ⚙️ **SwiftUI 设置面板** —— macOS 系统设置风格，所有功能可视化配置
- ↩️ **一键恢复 macOS 默认** —— 所有设置还原，正常睡眠回归
- 🇨🇳 纯中文界面 · 零第三方依赖 · 不联网 · 无常驻守护进程

## 📦 安装

只需 Command Line Tools（`swiftc`），**无需 Xcode 工程**：

```zsh
git clone https://github.com/baiiiii521/Qingxing.git
cd Qingxing
./build.sh          # 产出 dist/Qingxing.app
open dist/Qingxing.app
```

建议把 `Qingxing.app` 拖到「应用程序」文件夹后再开启"登录时自动启动"。

首次运行有中文欢迎说明；切换"合盖继续工作"时会弹**一次**系统管理员密码框（原理见下）。

## 🚀 使用

点击菜单栏 🌙 / ☕ 图标即可快捷开关；完整配置在 **⚙️ 设置…**（或按 ⌘,）：

<img src="docs/panel.png" width="520" alt="设置面板"/>

| 功能 | 说明 |
|---|---|
| 🌙 合盖继续工作 | 扣盖不休眠，合盖后屏幕自动关闭、任务继续 |
| 🌑 关屏继续工作 | 盖子开着，屏幕可熄灭但系统不睡 |
| ☀️ 屏幕常亮 | 屏幕和系统都不睡 |
| ⏻ 一键：立即关屏并继续工作 | 自动打开"关屏继续工作"并立刻熄屏 |
| ⚡ 生效条件 | 始终 / 仅插电源时 / 仅用电池时，拔插电源自动切换 |
| 🎯 App 触发 | 设置面板中添加 App（从 /Applications 选择），运行即自动保持唤醒 |
| 🔑 免密模式 | 设置面板一键安装/卸载，切换合盖模式不再要密码 |
| 🛡️ 电池保护 | 低电量（阈值可调）自动恢复睡眠，附启动自检 |
| ↩️ 恢复 macOS 默认 | 关闭全部模式并清除 pmset 设置 |
| 🚀 登录时自动启动 | 系统登录项（SMAppService） |

图标状态：🌙 = Mac 可正常睡眠；☕ = 有模式生效中。菜单顶部实时显示当前电源、电量百分比与生效中的模式。

> 💡 **选哪个？** 挂机下载、人不在电脑前 → 只开"关屏继续工作"（免密码，退出即恢复）；要把 Mac 合盖当主机 / 装包里跑任务 → 开"合盖继续工作"（其本身就包含关屏继续工作的效果）。两者可同时开启，互不冲突。

## 🔧 工作原理

| 模式 | 实现 | 权限 | 生效方式 |
|---|---|---|---|
| 合盖继续工作 | `pmset disablesleep`（内核 SleepDisabled 标志，按 `-c` / `-b` / `-a` 分电源写入） | 需一次管理员授权 | 系统级、持久（重启仍生效） |
| 关屏继续工作 | IOKit 断言 `PreventUserIdleSystemSleep` | 无需权限 | App 退出自动失效 |
| 屏幕常亮 | IOKit 断言 `PreventUserIdleDisplaySleep` | 无需权限 | App 退出自动失效 |

`caffeinate` / IOKit 断言只能阻止"闲置休眠"，**挡不住合盖**——合盖走的是硬件触发的内核路径，修改 `SleepDisabled` 是目前唯一免内核扩展的可靠方案（Sleepless、Owly 等项目采用同一路线）。

"生效条件"：断言类模式由 IOPS 电源通知实时挂载 / 释放；合盖模式映射为 pmset 对应电源配置，开启时自动记录原闲置睡眠时长并临时设为 `sleep 0`（macOS 26/27 上电池场景需要），关闭时自动还原。

**免密模式的技术方案**：安装时一次性授权写入两样东西——`/usr/local/bin/qingxing-privileged`（70 行不到的白名单 shell 助手，只接受 `lid-on/lid-off/sleep-set/ping` 四个子命令，参数严格校验）和 `/etc/sudoers.d/qingxing`（一条仅允许当前用户免密执行该助手的规则，`visudo -c` 校验后才落盘）。之后 App 通过 `sudo -n` 调用助手，切换合盖模式、电池自动保护全程无密码。助手里没有任何通配命令，无法借它执行白名单之外的任何操作；随时可在设置中一键卸载。

## 🆚 与现有工具对比

| | Qingxing | [Sleepless](https://github.com/Aboudjem/Sleepless) | [Owly](https://github.com/Aarontaken/owly) | [StayAwake](https://github.com/TY-teo/StayAwake) | [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake) | [Amphetamine](https://apps.apple.com/app/amphetamine/id937984704) |
|---|---|---|---|---|---|---|
| 合盖不休眠 | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| 关屏继续工作（屏幕可熄） | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **按电源条件生效（仅插电 / 仅电池）** | ✅ | ❌ | ❌ | ❌ | ❌ | ⚠️ 部分 |
| App 触发自动唤醒 | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| 电池阈值自动保护 | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| 免密切换 | 可选安装 | 需装 sudoers | 需装 sudoers | 需 sudoers | ❌ | 天生免密 |
| 中文界面 | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ |
| 开源 | ✅ MIT | ✅ | ✅ | ✅ | ✅ | ❌ |

## ⚠️ macOS 26 / 27 注意事项

- 新系统 `pmset -g custom` 不再列出 `disablesleep`，判断状态需读 `pmset -g` 的 `SleepDisabled`（live 值），本项目已适配
- 多方报告：新系统**电池供电**时仅设 `disablesleep` 可能仍被睡眠策略覆盖，需配合 `sleep 0`，本项目开启合盖模式时自动处理；若个别机型电池合盖仍睡眠，插电使用最可靠（[Apple 社区讨论](https://discussions.apple.com/thread/256305994)）
- 合盖运行时散热变差、电池持续耗电，请自行权衡

## 🛠 构建与开发

```zsh
./build.sh                              # 编译 + 生成图标 + 打包 + ad-hoc 签名
swiftc test_core.swift -o t && ./t      # 核心逻辑自测（无需任何权限）
```

```
├── main.swift          # 应用主体：菜单栏、菜单、设置面板窗口、电池保护、自检
├── Core.swift          # 电源监控（含电量）· IOKit 断言 · pmset 封装 · 免密特权组件 · 通知
├── Triggers.swift      # App 触发：指定 App 运行时自动保持唤醒
├── SettingsPanel.swift # SwiftUI 设置面板（macOS 系统设置风格）
├── Info.plist          # LSUIElement=1，纯菜单栏应用，不占 Dock
├── gen_icon.swift      # 图标生成（CoreGraphics 画咖啡杯）
├── build.sh            # 一键构建
├── test_core.swift     # 核心逻辑自测
└── docs/               # 截图等文档资源
```

- 产物为 arm64（Apple Silicon）；需要 Intel 可在 `build.sh` 给 `swiftc` 加 `-arch x86_64`
- 查看运行状态：`pmset -g assertions`（断言）、`pmset -g | grep SleepDisabled`（合盖开关）

## 🧹 卸载与恢复

1. 菜单 → ↩️ 恢复 macOS 默认（或手动 `sudo pmset -a disablesleep 0`）
2. 退出 App（菜单 → 退出），删除 `Qingxing.app` 即可；断言类模式随进程退出自动失效

## ❓ FAQ

**为什么"合盖继续工作"要输管理员密码？**
它修改的是系统级电源管理设置（`pmset disablesleep`），与在终端执行 `sudo pmset ...` 是一回事，只在开关时弹一次。嫌麻烦可在设置中安装免密组件。

**拔掉电源会发生什么？**
取决于你选的生效条件：断言类模式实时自动挂载 / 释放；合盖模式按 pmset 对应电源配置生效。

**免密组件安全吗？**
它不是放开权限的 sudoers 通配规则：助手上限 4 个子命令、参数逐个校验（profile 只能 a/b/c、分钟数 0–240），sudoers 只放行这一个脚本。安装/卸载都在设置面板一键完成，装了什么、放行了什么完全透明。

**App 退出了，设置还在吗？**
断言类模式立即失效（安全）；合盖模式是持久设置，重启也生效——用"恢复 macOS 默认"一键还原。

## 🙏 致谢

本项目站在前人验证过的技术路线上，感谢：[Sleepless](https://github.com/Aboudjem/Sleepless) · [Owly](https://github.com/Aarontaken/owly) · [StayAwake](https://github.com/TY-teo/StayAwake) · [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)

## 📄 License

[MIT](LICENSE) © 2026 baiiiii521
