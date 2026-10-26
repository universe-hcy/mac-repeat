# Repeat.app：后续工作交接

面向接手的 agent。先读「现状」，再按顺序做「待办」（A 需要用户配合，B 是主要工作）。所有结论都在本机实测过（macOS 26，arm64，2026-10-26）。

## 现状

### 文件
| 路径 | 内容 |
|---|---|
| `~/Applications/Repeat/Repeat.jar` | 上游 Repeat v5.7（https://github.com/repeats/Repeat），Java 后台 + 网页界面（http://127.0.0.1:65401） |
| `~/Applications/Repeat/config.json` | Repeat 配置（全局快捷键、任务列表） |
| `~/Applications/Repeat/repeat.log` | 后台日志（每次 App 启动后台时清空） |
| `~/Applications/Repeat/data/source/manual/` | Repeat「manual」编译器每次编译生成的步骤文件 |
| `~/Applications/Repeat/RepeatApp/main.swift` | 原生 App 唯一源码（约 2480 行） |
| `~/Applications/Repeat/RepeatApp/main.swift.bak-before-todoB` | 做待办 B 之前的源码备份（目录不是 git 仓库） |
| `~/Applications/Repeat/hotkeys.json` | 快捷键绑定列表（待办 B） |
| `~/Applications/Repeat/RepeatApp/build.sh` | 编译出 `~/Applications/Repeat.app`：签名、注册 `.repeat` 文档类型 |
| `~/Documents/Repeat 录制/` | 默认的录制文件目录（`.repeat`） |

构建：`cd ~/Applications/Repeat/RepeatApp && ./build.sh`。构建前先退出 App（`osascript -e 'quit app "Repeat"'`），等 `pgrep -f "Repeat.jar|Repeat.app/Contents"` 没有输出再继续。

### 架构（main.swift）
- `Backend`：调用 Repeat 的 HTTP 接口。`disableReplayHotkeys()` 把 Repeat 自带的 F11/F12 回放快捷键改绑到 F23/F24（Java 键码 0xF00A/0xF00B）。**不能直接清空**：空的 key chain 会让 F9 录制也失效（实测）。
- `Step` / `RecordingFormat`：录制的数据模型和两种编码。
  - 原生格式：`version=1.0` 加每行一个 JSON，交给 Repeat 编译。
  - 中文格式：`.repeat` 文件里每行一句中文，例如「按下 Control 键」「鼠标移动到 (x, y)」「等待 N 毫秒」。旧的原生格式文件也能读。
- `RecordingCleaner`：录完后的清理。
  - 去掉 F9/F10 的按键（Java 键码 120/121）。
  - 修正左键松开被记成右键的掩码（4096）。
  - 去掉不成对的松开事件；把停止录制的那次点击连同之前的鼠标轨迹裁掉。
  - 末尾补上所有仍处于按下状态的键和鼠标键的松开。
- `Keys` / `KeyRecorder`：键位表，以及 App 自己的键盘录制（见下文「已完成」）。
- `Player`：**用 CGEvent 自己播放**，按 `Keys.macCode` 把 Java 键码映射成 mac 键码，自己维护修饰键 flags。Repeat 自带的播放（java.awt.Robot）在本机会重复输入（"hi" 变成 "h h ii"，实测；Repeat 单独运行也一样）。
- `Recordings`：通过 Repeat 的 manual 编译器导出最近一次录制（`exportLast`），编译步骤（`load`），添加为任务（`addCurrentAsTask`，任务名转成拼音，因为 Repeat 网页显示中文会变成 "??"）。
- `AppDelegate`：
  - 主窗口：状态行、录制/播放按钮、次数、速度、中文步骤列表、打开/保存、添加为任务、高级界面（WKWebView 加载原网页）。
  - 菜单栏图标。
  - 后台生命周期：启动 java；等日志出现 "Initialization finished" 才算就绪；退出时先 clean-unused-sources 再 exit。
  - 快捷键：F10 播放/停止由 App 处理（NSEvent 全局和本地监听）；Esc 中止；F9 由 Repeat 处理。

### 权限
App 的 bundle id 是 `local.repeat.app`，用稳定的签名要求做 ad-hoc 签名，所以重新构建不会让授权失效。目前只授了「辅助功能」（TCC 里 `kTCCServiceAccessibility=2`）。Java 子进程继承这个权限。App 的键盘 tap 只靠这个权限也能工作（实测）。

## ✅ 已完成：录到 Control 等所有修饰键（2026-10-26）
采用「App 自己录键盘、替换 Repeat 录到的键盘步骤、保留 Repeat 的鼠标步骤」的方案。
- `Keys`：统一的键位表（Java 键码 ↔ mac 键码 ↔ 中文名）。Java 没有键码的键用私有码 `0x10000 + mac 键码`：右 Shift/Control/Option/Command、Fn、小键盘回车/等号；表外的键显示为「Mac键码N」，也能播放。新增小键盘 0–9 和运算符、F13–F20、Insert/Help、英数/かな。名字匹配时忽略大小写和空格。
- `KeyRecorder`：listen-only 的 `CGEvent` tap，运行在单独线程，只在录制期间启用（F9 松开、点「录制」、或检测到录制开始时启用；3 秒内没有真正开始录制就停掉）。**只授「辅助功能」就能创建（实测）**；创建失败时会请求「输入监控」，状态行给出橙色提示，录制回退到 Repeat 录到的键盘步骤。修饰键按 device bit 区分左右；CapsLock 每次状态变化记一次点按（按下加松开）。
- `RecordingCleaner.replacingKeys`：用两边都录到的按键算出时间差（取中位数），对齐 App 和 Repeat 的时间轴后合并。`forRepeat`：「添加为任务」时把右侧修饰键转成通用键；Fn 等 Repeat 没有的键会弹框提示「忽略并添加 / 取消」。
- `RecordingCleaner`：CapsLock 不成对的松开（来自 Repeat 的钩子）当作点按处理。
- `Player`：修饰键改为发送 `flagsChanged`，带左右 device bit；CapsLock 用 IOKit（`IOHIDSetModifierLockState`）切换系统状态。flags 根据当前按住的键计算，左右同时按住、松开一侧时 flags 仍然正确。

验收（注入模拟真实键盘的 flagsChanged 事件，TextEdit）：
- F9 录制左右 Control/Option/Command/Shift、Fn、CapsLock，以及 Control+A、右 Control+E、Command+Shift+←：主窗口里每个键的按下和松开都在，名字正确，F9 已过滤。
- 把这段录制在新文档里按 F10 播放，结果与录制时相同（"xabcy"，最后全选）。手写的中文文件（用右侧修饰键）和旧原生格式文件（含小键盘 1）都能播放。播放后 `CGEventSource.keyState` 显示没有修饰键卡住，CapsLock 处于关闭状态。
- 含 Fn 的录制「添加为任务」时会弹出提示。
- 未测：用真实硬件按键录制（尤其是真实 Fn/🌐 键，它可能触发表情符号面板）；在其他应用（游戏等）里播放修饰键。
- 模型测试：把 `// MARK: - App` 之前的部分截出来，和测试用的 main.swift 一起编译（`KeyRecorder.isDown` 也能单独测）。

## 待办（按优先级）

### 待办 A：用户确认已完成的功能（只需用户配合，不改代码）
修饰键录制和快捷键绑定都是用**模拟事件**测试的，下面几项需要用户用真实键盘确认。不要自己注入事件代替。
1. 用真实键盘按 F9 录制：左右 Control/Option/Command/Shift、Fn/🌐、CapsLock，以及 Control+A、Command+Shift+Z 等组合键。确认主窗口里每个键的按下和松开都在、名字正确。
   - 真实的 Fn/🌐 键松开时可能弹出表情符号面板或切换输入法（取决于「系统设置 → 键盘 → 按下 🌐 键时」的设置）。如果播放 Fn 也会触发这些，可以考虑在 `RecordingCleaner` 里去掉**单独按下的** Fn（Fn 和别的键一起按的组合保留），或者在主窗口提示。
2. 在用户常用的 App 里播放含修饰键的录制，确认能正常工作。
3. 用真实键盘在「绑定快捷键」表单里录入快捷键，并在常用 App 里按下触发播放。

### ✅ 待办 B：App 自己给录制绑定快捷键（2026-10-26 完成）
实现（main.swift）：
- `Hotkey`（mac 键码 + ⌃⌥⇧⌘ 位，显示成「⌃⌥1」；`problem` 校验：禁止 F9/F10/Esc、单独修饰键；除 F 键外必须含 ⌃ 或 ⌘，因为 ⌥A 会输入 å）。
- `HotkeyBinding`（快捷键、文件路径、次数、速度），存 `~/Applications/Repeat/hotkeys.json`；每次触发都重新读文件（`loadSteps`）。
- `GlobalHotkeys`：Carbon `RegisterEventHotKey`，`isTaken` 检测被其他应用占用（系统快捷键如 ⌘空格 检测不到）。
- 录制期间**不注销**快捷键：按下会被吞掉并忽略（状态行提示），`RecordingCleaner.removingHotkeys` 再去掉录制器看到的主键和只为它按下的修饰键。
- 触发：`hotkeyPressed` → `play(steps, name:, count:, speed:, trigger:)`；录制、播放、Repeat 任务运行中一律忽略并在状态行提示（4 秒，`notify`）。`Player` 开始前等快捷键的键和修饰键松开（最多 3 秒，读 `.hidSystemState`）。
- 界面：主窗口「绑定快捷键…」（未保存先要求保存；已绑定的文件则修改原绑定）；`BindingEditor` 表单（`HotkeyField` + `HotkeyPanel` 把所有按键包括 ⌘S、Esc 交给输入框；编辑期间注销全部快捷键，F10 监听也暂停）；「快捷键」窗口（`HotkeysWindowController`：添加/修改/删除/在主窗口打开，文件不存在显示红色）；菜单栏图标、文件菜单（⌘B 绑定、⌘K 快捷键）、窗口菜单都有入口。文件丢失时状态行橙色提示。
- 「添加为任务」按用户决定**降级保留**：从主窗口移除，只在「文件 → 添加为 Repeat 任务（不推荐）…」，点后先弹框推荐改用绑定快捷键。

验收（注入模拟事件，TextEdit，均通过）：
- ⌃⌥1 播放 "hello" 一次，快捷键本身没有漏给 TextEdit，之后 `keyState` 无修饰键卡住。**结论：CGEvent 模拟的按键会触发 `RegisterEventHotKey`**。
- 播放中连按两次快捷键：不叠加；Esc 能中止快捷键触发的播放。
- 录制里含有自己的快捷键（⌃⌥2）：播放时被忽略，不会循环。
- F9 录制中按 ⌃⌥1：不触发播放，录制结果里只有 A/B/C，没有 ⌃⌥1。
- 绑定表单：⌘S 被录成快捷键（没有弹保存框），编辑中按已绑定的快捷键不会触发播放；绑定后重启 App 仍然有效；文件改名后「快捷键」窗口显示红色「文件不存在」，按快捷键状态行提示。
- 测试注意：本机当前输入法是**拼音**，TextEdit 里读到的是未上屏的拼音（如 "he l"），Esc 会清掉它。判断时看字母次数即可，不要擅自切换用户输入法。
- 未测：用真实键盘录入快捷键；和其他应用快捷键冲突的提示（`isTaken`）。

原始设计（留作参考）：
**问题**：「添加为任务」后，任务由 Repeat 回放（在高级界面里运行，或用 Repeat 绑定的快捷键、手势触发）。Repeat 的回放器（java.awt.Robot）在本机会重复输入（"hi" 变成 "h h ii"），含键盘操作的录制没法用。App 自己的 `Player`（CGEvent）没有这个问题，已经实测。
**结论**：不采用「监听 Repeat 的任务触发、改由 App 播放」的方案。Repeat 没有这类回调，只能轮询 `is-running-compiled-task` 后再中止，Repeat 自己的回放仍会先跑一部分。改为下面的方案。

设计：
1. **数据**：一个「快捷键列表」，每条包含：录制文件路径（`.repeat`）、快捷键（键码加修饰键）、次数、速度。存在 `~/Applications/Repeat/hotkeys.json`（或 UserDefaults）。只引用文件，不复制内容：触发时重新读文件，用户改了文件就立即生效。文件丢失时在状态行提示。
2. **全局快捷键**：用 Carbon 的 `RegisterEventHotKey`。这个接口不需要额外权限，会吃掉这个按键（不会传给前台 App），也不会和 Repeat 的钩子冲突。
   - 禁止绑定 F9、F10、Esc，以及没有修饰键的普通字母和数字；和已有绑定冲突时提示。
   - 用户在设置里录入快捷键：可以用一个 NSTextField 子类监听 keyDown/flagsChanged，显示成「⌃⌥1」这样的形式。
3. **触发**：调用现有的 `startPlayback` 流程（把它改成接受 `[Step]`、次数、速度参数）。正在录制或播放时忽略触发，或者在状态行提示。Esc 照常能中止。
4. **录制时过滤**：录制期间按下的已绑定快捷键不应该被录进去。现在 `RecordingCleaner.hotkeyCodes` 只过滤 F9/F10。需要把已绑定的快捷键也传进去，过滤它的主键，以及只为这次快捷键按下、又在它之后松开的修饰键。比较简单的做法：录制期间暂时注销所有绑定（`UnregisterEventHotKey`），停止后再注册回来。
5. **防止自己触发自己**：播放的录制里如果含有某个已绑定的快捷键，可能会触发另一次播放。播放期间要忽略所有快捷键触发（第 3 点已经包含这一条）。需要实测：CGEvent 模拟的按键会不会触发 `RegisterEventHotKey`。
6. **界面**：
   - 主窗口：在「保存…」旁边加一个「绑定快捷键…」按钮，未保存的录制先要求保存。
   - 新开一个「快捷键」窗口，列出所有绑定（快捷键、录制名称、次数、速度），可以删除和修改。菜单栏图标和「文件」菜单里加入口。
   - 把「添加为任务…」降级：可以移到「高级界面」相关菜单里，或者在提示框里说明推荐改用「绑定快捷键」。是否删除这个功能，先问用户。
7. **验收**：
   - 给一个打字录制（例如输入 "hello"）绑定 ⌃⌥1。在 TextEdit 里按下，输入一次 "hello"，没有重复，没有修饰键卡住（用 `CGEventSource.keyState` 检查）。
   - 播放期间再按快捷键不会叠加播放。
   - 录制期间按快捷键不会被录进去。
   - 重启 App 后绑定仍然有效。

### 待办 C：小问题
1. **只录点击的选项**：在主窗口加一个复选框「只录点击，不录鼠标轨迹」（Repeat 原本有 `record-mouse-click-only` 设置，但不建议改 Repeat 的设置）。在 App 里清理即可：删掉 `.move`，但保留每次鼠标按下、松开之前的最后一个 `.move`（用来定位）。被删掉的移动之间的 `.delay` 要合并，保证总时长不变。
   - 拖拽（按下和松开之间的移动）要保留，至少保留按下和松开时的位置。
   - 显示：`RecordingFormat.timeline` 已经会把连续移动合成一行。
2. **App 图标会糊**：现在是把 60×60 的 logo 放大生成的。在 `build.sh` 里改为用 Swift 或 Core Graphics 脚本画一个 1024×1024 的图标（例如圆角矩形背景加 SF Symbol「record.circle」或「repeat」），再用 `sips` 缩放出 iconset。
3. ~~任务名不能用中文~~：待办 B 完成后任务功能已降级为「不推荐」，这一项不做（仍用拼音绕过）。

### 已知限制（不属于 bug，必要时在界面或文档里说明）
App 的播放器在系统层面模拟键盘鼠标，对大多数 App 都有效。但下面这些情况无能为力或需要用户配合：
- 用原始输入或有反作弊的游戏，可能不认模拟事件；
- 密码框等开启了「安全输入」的地方，系统会拦下模拟按键；
- 界面加载慢时，播放太快会点空：建议降低速度，或手动在 `.repeat` 文件里加大「等待 N 毫秒」；
- 录制的是屏幕绝对坐标，窗口位置变了以后，点击位置会偏。
- 已绑定的快捷键会被本 App 全局吞掉：录制里如果有意包含这个组合键，播放时它不会传给目标应用。
- 系统保留的快捷键（如 ⌘空格）可以绑定成功但不会触发，检测不到。

## 测试方法（踩过的坑）
- **不要在用户玩游戏或操作电脑时注入鼠标键盘事件**，先问用户。之前测试时前台有游戏窗口，干扰了结果。
- 读写 TextEdit 内容用辅助功能接口（AXTextArea 的 `kAXValueAttribute`），不要靠截图或 ⌘A 加删除：录制里的点击会把光标放到奇怪的位置。
- **模拟真实修饰键**：先发 `CGEvent(keyboardEventSource:virtualKey:keyDown:)`，再把 `type` 改成 `.flagsChanged` 并设置 `flags`，按下时带上对应 flag，松开时 flags 为空。直接发修饰键的 keyDown，和真实键盘的行为不一样。
- Repeat 后台接口（POST）：
  - `internals/action/start-record`、`stop-record`
  - `internals/menu/tools/generate-source`：返回页面里有 `manually-build-task-id`
  - `internals/action/manually-build/constructor/build`，参数 `{"id": …}`
  - 最新生成的文件就是这次录制：`ls -t data/source/manual/*.manualbuild | head -1`
- 点击 App 里的按钮：用辅助功能接口找按钮（AXButton 的 title）再执行 `AXPress`。注意：「高级界面」窗口关闭后仍在 AX 树里，按标题找按钮时要限定在主窗口（标题以 "Repeat" 开头的那个窗口）。
- NSEvent 的 `keyCode` 只能在键盘事件上读取，在鼠标事件上读取会抛异常，导致点击全部失效（已修过，`handleHotkey` 开头有判断）。
- 网络或定时器回调里不要调用 `NSAlert.runModal()`，曾经导致崩溃。用 `info()`，它会以 sheet 形式弹出。
- 模型逻辑（`RecordingFormat` / `RecordingCleaner`）可以单独测：把 main.swift 中 `// MARK: - App` 之前的部分截出来，和测试用的 `main.swift` 一起用 `swiftc` 编译。
