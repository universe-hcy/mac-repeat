# mac-repeat

[Repeat](https://github.com/repeats/Repeat)（v5.7）的 macOS 原生前端。用 Swift / AppKit 写成，单个源文件，中文界面。

Repeat 本身是 Java 后台加网页界面的键鼠录制回放工具。在 macOS 上直接用它有几个问题：回放会重复输入（"hi" 变成 "h h ii"），录不到右 Control、Fn、CapsLock，左键松开被记成右键，网页界面显示中文会乱码。本项目**不修改 Repeat 的代码和 jar**，只在外面包一层原生 App：录制仍交给 Repeat，播放、键盘录制、文件格式和快捷键改由 App 自己负责。

## 目录

| 文件 | 内容 |
|---|---|
| `main.swift` | App 全部源码 |
| `build.sh` | 编译出 `~/Applications/Repeat.app`，签名，注册 `.repeat` 文档类型 |
| `TODO.md` | 开发记录：现状、架构、待办、测试方法 |

## 构建与运行

需要 macOS 13+（arm64）、Xcode 命令行工具（`swiftc`）、Java（`/usr/bin/java`）。

1. 从 [Repeat 的 Releases](https://github.com/repeats/Repeat/releases) 下载 v5.7 的 `Repeat.jar`，放到 `~/Applications/Repeat/Repeat.jar`（仓库里不包含它）。
2. 把本仓库放在 `~/Applications/Repeat/RepeatApp/`，运行：
   ```bash
   cd ~/Applications/Repeat/RepeatApp && ./build.sh
   ```
   如果 App 正在运行，先退出：`osascript -e 'quit app "Repeat"'`。
3. 打开 `~/Applications/Repeat.app`，在「系统设置 → 隐私与安全性 → 辅助功能」里允许它。App 会自动在 `~/Applications/Repeat/` 下启动 Repeat 后台（`java -jar Repeat.jar`），退出时一并关闭。

路径是写死的：数据目录 `~/Applications/Repeat/`，录制文件默认存到 `~/Documents/Repeat 录制/`。

## 和原版 Repeat 相比的改动

### 新增：原生 App 外壳
- 原生主窗口：状态行、录制/播放、次数、速度、当前录制的中文步骤列表、打开/保存。
- 菜单栏图标；Dock 里只有一个图标（Java 进程以 `apple.awt.UIElement` 启动）。
- 管理后台生命周期：启动 Java；等日志出现 "Initialization finished" 才算就绪；退出时先清理未使用的编译文件再退出。
- 原网页界面保留为「高级界面」窗口（WKWebView），支持网页里的 alert/confirm/prompt。
- 稳定的 ad-hoc 签名（固定 designated requirement），重新构建后不用重新授权。

### 播放：不用 Repeat 的回放器
- Repeat 用 `java.awt.Robot` 回放，在 macOS 上会重复输入。App 改用 `CGEvent` 自己播放：Java 键码映射成 mac 键码，自己维护修饰键 flags。
- 修饰键以 `flagsChanged` 发送，带左右 device bit，和真实键盘一致；CapsLock 用 IOKit 切换系统状态。
- 支持次数、速度（0.5×–4×）；Esc 随时中止；结束或中止后释放所有按住的键和鼠标键。
- Repeat 自带的回放快捷键 F11/F12 被改绑到 F23/F24（键盘上没有的键），相当于停用。不能直接清空：空的 key chain 会让 F9 录制失效。这是唯一一处对 Repeat 配置（`config.json`）的修改。

### 录制：清理和补全
- 录制仍由 Repeat 完成（F9 开始/停止），停止后通过它的 manual 编译器导出步骤。
- App 用自己的键盘事件 tap（只在录制期间启用）重新录键盘，替换 Repeat 录到的按键，保留 Repeat 的鼠标步骤；两边的时间轴用共同按键的时间差中位数对齐。这样能录到右侧修饰键、Fn、CapsLock、F13–F20、小键盘等 Repeat 录不到的键。
- 录完自动清理：去掉 F9/F10 和已绑定的快捷键；修正左键松开被记成右键；去掉不成对的松开；裁掉停止录制的那次点击和之前的鼠标轨迹；末尾补齐所有仍按住的键。

### 文件格式：中文 `.repeat`
- 每行一句中文，可直接编辑，例如：
  ```
  按下 Control 键
  鼠标移动到 (512, 300)
  按下 鼠标左键
  等待 120 毫秒
  ```
- 也能读 Repeat 原生格式（`version=1.0` 加每行一个 JSON）。
- 注册为文档类型：Finder 双击打开，支持「打开最近使用」。

### 快捷键绑定
- 任意 `.repeat` 文件可以绑定全局快捷键（Carbon `RegisterEventHotKey`，不需要额外权限），并设置次数和速度。按下后由 App 播放；每次都重新读取文件。
- 绑定存在 `~/Applications/Repeat/hotkeys.json`。有「快捷键」窗口管理所有绑定。
- 录制、播放中按快捷键会被忽略，不会叠加，也不会被录进去；播放的录制里含有快捷键也不会自己触发自己。
- 这一功能取代了 Repeat 的「任务 + 快捷键」用法。「添加为 Repeat 任务」仍保留在「文件」菜单里（不推荐：任务由 Repeat 回放，会重复输入；任务名会被转成拼音，因为 Repeat 网页显示中文会乱码）。

## 已知限制
- 有反作弊或使用原始输入的游戏可能不认模拟事件；密码框等「安全输入」会拦下模拟按键。
- 录的是屏幕绝对坐标，窗口移动后点击会偏；界面加载慢时请降低速度或加大等待。
- 已绑定的快捷键会被全局吞掉，录制里含有它时播放不会传给目标应用；系统保留的快捷键（如 ⌘空格）绑定后不会触发，也检测不到。

## 许可证
Copyright 2026 universe-hcy。本项目以 [Apache License 2.0](LICENSE) 发布。

## 致谢
录制和编译功能来自 [repeats/Repeat](https://github.com/repeats/Repeat)（Apache License 2.0）。本仓库不包含 Repeat 的源码和 `Repeat.jar`，只在运行时调用它；`build.sh` 构建时从 jar 中取出 Repeat 的 logo 生成 App 图标，这个图标不包含在仓库里。
