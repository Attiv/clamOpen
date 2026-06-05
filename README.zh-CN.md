# ClamOpen 开盖合盖

<p align="center">
  <img src="docs/icon-clamopen.png" width="120" alt="ClamOpen 图标">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/icon-restore.png" width="120" alt="恢复内置屏 图标">
</p>

<p align="center">
  <b>外接显示器在线时，盖子开着也只用外接屏</b><br>
  —— 等效合盖，但无需真的合上盖子。
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a>
</p>

---

ClamOpen 是一个常驻菜单栏的小工具：在连接外接显示器时，**真正关闭 MacBook 内置屏**（背光熄灭、停止渲染），而**盖子保持打开**。效果等同合盖（clamshell），但你仍能用摄像头、Touch ID、键盘，散热也更好。

## 为什么需要它

macOS 只在**合盖**时才关闭内置屏。如果你想开着盖子（为了摄像头、Touch ID、内置键盘，或单纯散热），系统没有原生开关。ClamOpen 就是这个开关。

## 功能

- 🖥️ 菜单栏一键开 / 关内置屏
- 🤖 **自动模式** —— 接外接屏自动关内置、拔掉自动恢复
- 🔋 **电源管理** —— 一键优化休眠设置，防止夜间频繁唤醒耗电（禁用 TCP Keep Alive、网络唤醒等）
- 🛟 **防崩溃恢复** —— 独立的「恢复内置屏」App，即使主程序挂了、屏幕全黑，也能用 Spotlight 盲打救回
- 🔒 **安全优先** —— 没有外接屏时拒绝关闭内置屏；拔线 / 退出自动恢复
- 🪶 仅菜单栏（无 Dock 图标）、无后台守护进程、不永久改动系统

## 实现原理

ClamOpen 通过 **CoreGraphics / SkyLight 的私有符号**关闭内置屏：

```c
CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);
```

放在标准的显示器重配置事务里调用：

```swift
var config: CGDisplayConfigRef?
CGBeginDisplayConfiguration(&config)
CGSConfigureDisplayEnabled(config, builtinDisplayID, false)   // false = 禁用
CGCompleteDisplayConfiguration(config, .forSession)
```

- `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` 是**公开**的 CoreGraphics 接口。
- `CGSConfigureDisplayEnabled` 是真正干活的**私有**符号。通过
  `dlsym(RTLD_DEFAULT, "CGSConfigureDisplayEnabled")` 在运行时取得（它就在 CoreGraphics / SkyLight
  内），因此**不需要链接私有框架**，也不需要任何 entitlement。
- 之后内置屏的 `CGDisplayIsActive == false`：背光关闭、不再渲染 —— 视觉上和合盖一致，但盖子开着。
- `forSession` 作用域表示设置只在**当前登录会话**有效；因此**注销或重启一定会恢复内置屏**。

这与 [Lunar](https://lunar.fyi)、[BetterDisplay](https://github.com/waydabber/BetterDisplay) 等工具
用的是同一套底层机制。（Apple Silicon 上还有更彻底的“软断开”能释放 framebuffer；ClamOpen 用的
`CGSConfigureDisplayEnabled` 路径在 Intel 与 Apple Silicon 上都可用。）

> 已在 macOS 26.5.1（Intel）实测：禁用返回 `CGError 0`，内置屏变为非活动；重新启用后恢复正常。

## 安全与恢复

关闭内置屏后**又拔掉外接屏**，理论上会让你没有任何可见画面。ClamOpen 用多重**相互独立**的机制防止这种死局：

- 没有外接屏在线时，**拒绝**关闭内置屏。
- 拔掉外接屏时，通过三重独立触发**自动恢复**内置屏：底层
  `CGDisplayRegisterReconfigurationCallback`（拔线瞬间）、AppKit 屏幕参数通知、1.5 秒看门狗轮询。
- **退出 App 自动恢复**。
- Intel 上若内置屏偶发在最低亮度被点亮，看门狗会在 1.5 秒内重新关闭。

### 万一屏幕全黑

以下任意一条都能救回内置屏：

1. **Spotlight 盲打（全黑也能用）**：按 `⌘ 空格`，输入「恢复内置屏」，回车。全程不用看屏幕。
2. **拔掉外接屏** —— 自动恢复。
3. **合盖再开盖** —— 系统重新枚举显示器。
4. **注销 / 重启** —— `forSession` 作用域保证恢复。

> 已实测：主程序**未运行**时，单独启动「恢复内置屏」App 即可把被关闭的内置屏恢复为 active。

## 从源码构建

要求：macOS 12+，Xcode / Swift 5.9+。

```bash
git clone https://github.com/Attiv/clamOpen.git
cd clamOpen
./build_app.sh        # 生成图标、编译并打包两个 App
```

产物：

- `ClamOpen.app` —— 菜单栏主程序
- `恢复内置屏.app` —— 独立急救恢复程序

或仅编译：`swift build -c release`

## 安装

把 **`ClamOpen.app`** 和 **`恢复内置屏.app`** 都拖进 `/Applications`。急救 App 放进去后，Spotlight
才能在全黑时被你盲打搜到（强烈建议）。首次运行若被 Gatekeeper 拦截（本地 ad-hoc 签名），右键点
App →「打开」即可。

开机自启：系统设置 → 通用 → 登录项 → 添加 `ClamOpen.app`。

## 使用

### 显示器控制

1. 接上外接显示器。
2. 点菜单栏图标 →「关闭内置屏（只用外接）」。
3. 想恢复 →「恢复内置屏」，或开启「自动」模式。

### 电源管理（防止夜间耗电）

**问题症状**：MacBook 晚上休眠一晚，第二天早上电池耗尽。

**原因**：macOS 默认启用 TCP Keep Alive，导致系统在休眠时每分钟唤醒一次维护网络连接，造成电池快速耗尽。

**解决方法**：

1. 点菜单栏图标 → 「电源管理」（如果检测到耗电问题会显示 ⚠️ 标记）
2. 查看当前电源设置
3. 点击「应用省电设置」，输入管理员密码
4. 完成后，系统会禁用以下功能：
   - TCP 保活（防止频繁唤醒）
   - 网络唤醒
   - 靠近唤醒
   - 调整待机延迟为 1 小时

**不影响正常使用**：打开盖子、按键盘、点触控板等正常唤醒方式完全不受影响。

**验证效果**：第二天早上打开终端运行：
```bash
pmset -g log | grep -E "DarkWake" | tail -20
```
查看夜间唤醒次数是否明显减少。

## 项目结构

```
Sources/ClamOpen/      菜单栏主程序
  ├── DisplayController.swift   显示器控制（私有接口调用）
  ├── PowerManager.swift         电源管理（休眠优化）
  ├── AppDelegate.swift          应用主逻辑
  └── main.swift
Sources/ClamRestore/   独立急救恢复工具
make_icon.swift        程序化图标生成
build_app.sh           构建并打包两个 .app
Info*.plist            Bundle 元数据
scripts/               开发 / 验证脚本（探针、开关测试、禁用）
```

## 兼容性

- 实测：macOS 26.5.1，Intel（UHD 630 + Radeon Pro 5500M）。
- `CGSConfigureDisplayEnabled` 路径在 Intel 与 Apple Silicon 上均可用。
- 私有接口可能随系统更新变化；截至撰写在上述系统稳定可用。

## 免责声明

ClamOpen 使用了 Apple 私有接口。它不需要特殊 entitlement，也不会永久改动系统（设置仅当前会话有效），但私有接口不受 Apple 支持、可能随版本变化。请自行承担使用风险。

## 许可证

MIT —— 见 [LICENSE](LICENSE)。
