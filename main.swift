// Native macOS front end for the Repeat Java backend (https://github.com/repeats/Repeat).
// - Starts `java -jar Repeat.jar` in the data directory (unless a backend is already listening)
//   and shuts it down on quit.
// - Main window: record / play / open / save, and the current recording shown as Chinese steps.
// - Recordings are saved as Chinese plain-text `.repeat` files (see RecordingFormat).
// - Repeat's original web UI stays available as the "高级界面" window (task list, hotkeys, …).
// - Recording files can be bound to global hotkeys; this app plays them (see HotkeyBinding).
import Carbon
import Cocoa
import IOKit.hidsystem
import UniformTypeIdentifiers
import WebKit

let dataDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Repeat")
let jarURL = dataDir.appendingPathComponent("Repeat.jar")
let logURL = dataDir.appendingPathComponent("repeat.log")
let configURL = dataDir.appendingPathComponent("config.json")
/// Where Repeat's "manual" compiler writes the step file of every successful compile.
let manualSourceDir = dataDir.appendingPathComponent("data/source/manual")
let recordingsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/Repeat 录制")
let hotkeysURL = dataDir.appendingPathComponent("hotkeys.json")
let playbackSpeeds: [(title: String, speed: Double)] = [("0.5×", 0.5), ("1×", 1.0), ("2×", 2.0), ("4×", 4.0)]
let baseURL = URL(string: "http://127.0.0.1:65401")!

/// macOS virtual key codes of the hotkeys this app watches.
enum HotKey {
    static let record: UInt16 = 101  // F9 — handled by Repeat itself; observed here for timing
    static let play: UInt16 = 109    // F10 — handled by this app
    static let escape: UInt16 = 53   // Esc — Repeat halts tasks; this app also stops its playback loop
}

enum Backend {
    static func get(_ path: String, timeout: TimeInterval = 2, _ done: @escaping (String?) -> Void) {
        send(path, method: "GET", body: nil, timeout: timeout, done)
    }

    static func post(_ path: String, body: String? = nil, _ done: ((String?) -> Void)? = nil) {
        send(path, method: "POST", body: body, timeout: 10) { done?($0) }
    }

    /// Calls back on the main queue with the body on HTTP 200, nil otherwise.
    private static func send(_ path: String, method: String, body: String?, timeout: TimeInterval,
                             _ done: @escaping (String?) -> Void) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.httpBody = body?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let text = ok ? String(data: data ?? Data(), encoding: .utf8) : nil
            DispatchQueue.main.async { done(text) }
        }.resume()
    }

    static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }

    /// Moves Repeat's own replay hotkeys (F11 / F12) to F23 / F24, keys no keyboard has. Its raw
    /// replay records left-button releases with the right-button mask, leaving the left button
    /// stuck down; this app plays cleaned recordings itself (F10). They can't simply be emptied:
    /// an empty key chain breaks Repeat's F9 record hotkey. Only edit while Repeat is stopped.
    static func disableReplayHotkeys() {
        guard let data = try? Data(contentsOf: configURL),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var settings = root["global_settings"] as? [String: Any],
              var hotkeys = settings["global_hotkey"] as? [String: Any] else { return }
        // Java key codes: VK_F23 = 0xF00A, VK_F24 = 0xF00B.
        let unused = ["replay": 0xF00A, "replay_compiled": 0xF00B]
        func binding(_ key: Int) -> [[String: Any]] { [["type": "key_stroke", "key": key, "modifier": 0]] }
        func isUnused(_ name: String) -> Bool {
            let strokes = hotkeys[name] as? [[String: Any]] ?? []
            return strokes.count == 1 && (strokes[0]["key"] as? NSNumber)?.intValue == unused[name]
        }
        guard !unused.keys.allSatisfy(isUnused) else { return }
        unused.forEach { hotkeys[$0.key] = binding($0.value) }
        settings["global_hotkey"] = hotkeys
        root["global_settings"] = settings
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes]) {
            try? out.write(to: configURL)
        }
    }
}

// MARK: - Recording model and file format

/// One step of a Repeat manual-build task. Steps produced by Repeat's recorder get their own
/// case; anything else is kept verbatim as Repeat's JSON line.
enum Step: Equatable {
    case delay(ms: Int)
    case move(x: Int, y: Int)
    case mousePress(mask: Int)
    case mouseRelease(mask: Int)
    case keyPress(key: Int)
    case keyRelease(key: Int)
    case other(json: String)

    var isDelay: Bool { if case .delay = self { return true }; return false }
    var isMove: Bool { if case .move = self { return true }; return false }
}

/// Key codes in steps are Java virtual key codes (what Repeat records and compiles). Keys Java
/// has no code for (right-hand modifiers, Fn, …) get app-private codes `privateBase + mac key code`.
enum Keys {
    static let privateBase = 0x10000

    /// (Java or private code, macOS virtual key code, display name). The first entry of a mac
    /// code is what recording produces; later ones (Help) are accepted for playback only.
    private static let table: [(code: Int, mac: CGKeyCode, name: String)] = {
        var rows: [(code: Int, mac: CGKeyCode, name: String)] = [
            (8, 51, "退格"), (9, 48, "Tab"), (10, 36, "回车"), (16, 56, "Shift"), (17, 59, "Control"),
            (18, 58, "Option"), (20, 57, "CapsLock"), (27, 53, "Esc"), (32, 49, "空格"),
            (33, 116, "PageUp"), (34, 121, "PageDown"), (35, 119, "End"), (36, 115, "Home"),
            (37, 123, "左方向"), (38, 126, "上方向"), (39, 124, "右方向"), (40, 125, "下方向"),
            (44, 43, "逗号"), (45, 27, "减号"), (46, 47, "句号"), (47, 44, "斜杠"), (59, 41, "分号"),
            (61, 24, "等号"), (91, 33, "左方括号"), (92, 42, "反斜杠"), (93, 30, "右方括号"),
            (127, 117, "删除"), (157, 55, "Command"), (192, 50, "反引号"), (222, 39, "引号"),
            (155, 114, "Insert"), (156, 114, "Help"), (240, 102, "英数"), (21, 104, "かな"),
            // Numeric keypad.
            (106, 67, "小键盘 *"), (107, 69, "小键盘 +"), (109, 78, "小键盘 -"), (110, 65, "小键盘 ."),
            (111, 75, "小键盘 /"), (12, 71, "小键盘 Clear"),
            (privateBase + 76, 76, "小键盘 回车"), (privateBase + 81, 81, "小键盘 ="),
            // Right-hand modifiers and Fn.
            (privateBase + 60, 60, "右 Shift"), (privateBase + 62, 62, "右 Control"),
            (privateBase + 61, 61, "右 Option"), (privateBase + 54, 54, "右 Command"),
            (privateBase + 63, 63, "Fn"),
        ]
        let letters: [CGKeyCode] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, mac) in letters.enumerated() { rows.append((65 + i, mac, String(UnicodeScalar(UInt8(65 + i))))) }
        let digits: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        for (i, mac) in digits.enumerated() { rows.append((48 + i, mac, "\(i)")) }
        let keypad: [CGKeyCode] = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92]
        for (i, mac) in keypad.enumerated() { rows.append((96 + i, mac, "小键盘 \(i)")) }
        let fKeys: [CGKeyCode] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, mac) in fKeys.enumerated() { rows.append((112 + i, mac, "F\(i + 1)")) }
        let fKeysHigh: [CGKeyCode] = [105, 107, 113, 106, 64, 79, 80, 90]  // F13–F20 = VK_F13 (0xF000) …
        for (i, mac) in fKeysHigh.enumerated() { rows.append((0xF000 + i, mac, "F\(i + 13)")) }
        return rows
    }()

    static let names = Dictionary(table.map { ($0.code, $0.name) }, uniquingKeysWith: { first, _ in first })
    private static let macCodes = Dictionary(table.map { ($0.code, $0.mac) }, uniquingKeysWith: { first, _ in first })
    private static let codesByMac = Dictionary(table.map { ($0.mac, $0.code) }, uniquingKeysWith: { first, _ in first })
    /// Names are matched ignoring case and spaces ("右control" = "右 Control").
    private static let codesByName = Dictionary(table.map { (normalized($0.name), $0.code) }, uniquingKeysWith: { first, _ in first })

    static func normalized(_ name: String) -> String { name.uppercased().replacingOccurrences(of: " ", with: "") }

    static func name(_ code: Int) -> String {
        if let name = names[code] { return name }
        if let mac = privateMac(code) { return "Mac键码\(mac)" }
        return "键码\(code)"
    }

    static func code(named name: String) -> Int? {
        let key = normalized(name)
        if let code = codesByName[key] { return code }
        if key.hasPrefix("MAC键码"), let mac = Int(key.dropFirst(5)), (0..<128).contains(mac) { return privateBase + mac }
        if key.hasPrefix("键码"), let code = Int(key.dropFirst(2)) { return code }
        return nil
    }

    static func macCode(_ code: Int) -> CGKeyCode? { macCodes[code] ?? privateMac(code) }
    static func code(mac: CGKeyCode) -> Int { codesByMac[mac] ?? privateBase + Int(mac) }

    private static func privateMac(_ code: Int) -> CGKeyCode? {
        (privateBase..<privateBase + 128).contains(code) ? CGKeyCode(code - privateBase) : nil
    }

    /// The code Repeat knows for a key (right-hand modifiers become the generic ones); nil when
    /// Repeat has none (Fn, keys only known by their mac code).
    static func repeatCode(_ code: Int) -> Int? {
        let generic = [privateBase + 60: 16, privateBase + 62: 17, privateBase + 61: 18, privateBase + 54: 157,
                       privateBase + 76: 10, privateBase + 81: 61]
        if let base = generic[code] { return base }
        return privateMac(code) == nil ? code : nil
    }

    /// Modifier keys (mac code) → their flag and device-dependent bit (NX_DEVICE*KEYMASK).
    /// The device bit tells left from right; `other` is the opposite side's bit.
    static let modifiers: [CGKeyCode: (flag: CGEventFlags, device: UInt64, other: UInt64)] = [
        59: (.maskControl, 0x1, 0x2000), 62: (.maskControl, 0x2000, 0x1),
        56: (.maskShift, 0x2, 0x4), 60: (.maskShift, 0x4, 0x2),
        55: (.maskCommand, 0x8, 0x10), 54: (.maskCommand, 0x10, 0x8),
        58: (.maskAlternate, 0x20, 0x40), 61: (.maskAlternate, 0x40, 0x20),
        63: (.maskSecondaryFn, 0, 0),
    ]
    static let capsLockMac: CGKeyCode = 57
    static let capsLock = 20
}

struct FormatError: Error {
    let line: Int
    let text: String
    var message: String { "第 \(line) 行无法识别：\(text)" }
}

/// Two encodings of a step list:
/// - native: Repeat's manual-build source (`version=1.0` + one JSON step per line), fed to its compiler;
/// - chinese: the `.repeat` file format, one readable, editable Chinese sentence per line.
enum RecordingFormat {
    static let mouseButtons: [Int: String] = [1024: "左键", 2048: "中键", 4096: "右键"]
    private static let buttonMasks = Dictionary(uniqueKeysWithValues: mouseButtons.map { ($0.value, $0.key) })

    // Native

    static func parseNative(_ text: String) -> [Step] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("version=") }
            .map { parseNativeLine($0) ?? .other(json: $0) }
    }

    /// nil when the line is not valid JSON.
    static func parseNativeLine(_ line: String) -> Step? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let fields = object["data"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { (fields[key] as? NSNumber)?.intValue }
        switch object["signature"] as? String {
        case "controller_delay": if let v = int("delay") { return .delay(ms: v) }
        case "mouse_move": if let x = int("x"), let y = int("y") { return .move(x: x, y: y) }
        case "mouse_press_current_position": if let m = int("mask") { return .mousePress(mask: m) }
        case "mouse_release_current_position": if let m = int("mask") { return .mouseRelease(mask: m) }
        case "keyboard_press_key": if let k = int("key") { return .keyPress(key: k) }
        case "keyboard_release_key": if let k = int("key") { return .keyRelease(key: k) }
        default: break
        }
        return .other(json: line)
    }

    static func native(_ steps: [Step]) -> String {
        "version=1.0\n" + steps.map(nativeLine).joined(separator: "\n") + "\n"
    }

    private static func nativeLine(_ step: Step) -> String {
        func line(_ signature: String, _ fields: String) -> String {
            #"{"signature":"\#(signature)","data":{\#(fields)}}"#
        }
        switch step {
        case .delay(let ms): return line("controller_delay", #""delay":\#(ms)"#)
        case .move(let x, let y): return line("mouse_move", #""x":\#(x),"y":\#(y)"#)
        case .mousePress(let m): return line("mouse_press_current_position", #""mask":\#(m)"#)
        case .mouseRelease(let m): return line("mouse_release_current_position", #""mask":\#(m)"#)
        case .keyPress(let k): return line("keyboard_press_key", #""key":\#(k)"#)
        case .keyRelease(let k): return line("keyboard_release_key", #""key":\#(k)"#)
        case .other(let json): return json
        }
    }

    // Chinese

    static func chinese(_ steps: [Step]) -> String {
        let header = [
            "# Repeat 录制文件：每行一个操作，可直接修改后保存；以 # 开头的行是注释。",
            "# 共 \(steps.count) 步，时长约 \(seconds(duration(steps))) 秒。",
        ]
        return (header + steps.map(chineseLine)).joined(separator: "\n") + "\n"
    }

    static func chineseLine(_ step: Step) -> String {
        switch step {
        case .delay(let ms): return "等待 \(ms) 毫秒"
        case .move(let x, let y): return "鼠标移动到 (\(x), \(y))"
        case .mousePress(let m): return "按下 鼠标\(buttonName(m))"
        case .mouseRelease(let m): return "松开 鼠标\(buttonName(m))"
        case .keyPress(let k): return "按下 \(keyName(k)) 键"
        case .keyRelease(let k): return "松开 \(keyName(k)) 键"
        case .other(let json): return json  // No Chinese form; Repeat's own JSON line is kept as-is.
        }
    }

    static func buttonName(_ mask: Int) -> String { mouseButtons[mask] ?? "按键\(mask)" }
    static func keyName(_ key: Int) -> String { Keys.name(key) }

    /// Reads a `.repeat` file: the Chinese format, or Repeat's native format (older files).
    static func parse(_ text: String) throws -> [Step] {
        if text.hasPrefix("version=") { return parseNative(text) }
        var steps: [Step] = []
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let step = parseChineseLine(line) else { throw FormatError(line: index + 1, text: line) }
            steps.append(step)
        }
        return steps
    }

    private static func parseChineseLine(_ line: String) -> Step? {
        if line.hasPrefix("{") { return parseNativeLine(line) }
        if let m = match(#"^等待\s*(\d+)\s*毫秒$"#, line), let ms = Int(m[0]) { return .delay(ms: ms) }
        if let m = match(#"^鼠标移动到\s*[(（]\s*(-?\d+)\s*[,，]\s*(-?\d+)\s*[)）]$"#, line),
           let x = Int(m[0]), let y = Int(m[1]) { return .move(x: x, y: y) }
        // Mouse before keys: "按下 鼠标左键" would otherwise read as key "鼠标左".
        if let m = match(#"^(按下|松开)\s*鼠标\s*(\S+)$"#, line) {
            guard let mask = buttonMasks[m[1]] ?? match(#"^按键(\d+)$"#, m[1]).flatMap({ Int($0[0]) }) else { return nil }
            return m[0] == "按下" ? .mousePress(mask: mask) : .mouseRelease(mask: mask)
        }
        if let m = match(#"^(按下|松开)\s*(.+?)\s*键$"#, line) {
            guard let key = Keys.code(named: m[1]) else { return nil }
            return m[0] == "按下" ? .keyPress(key: key) : .keyRelease(key: key)
        }
        return nil
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern)
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }

    // Display

    static func duration(_ steps: [Step]) -> Int {
        steps.reduce(0) { if case .delay(let ms) = $1 { return $0 + ms }; return $0 }
    }

    static func seconds(_ ms: Int) -> String { String(format: "%.1f", Double(ms) / 1000) }

    /// Steps for display: delays become timestamps; runs of mouse moves collapse into one line.
    static func timeline(_ steps: [Step]) -> [(time: Int, text: String)] {
        var items: [(time: Int, text: String)] = []
        var time = 0
        var moveRun: (index: Int, count: Int)?
        for step in steps {
            switch step {
            case .delay(let ms):
                time += ms
            case .move(let x, let y):
                if let run = moveRun {
                    moveRun = (run.index, run.count + 1)
                    items[run.index].text = "鼠标移动到 (\(x), \(y))（经过 \(run.count + 1) 个点）"
                } else {
                    items.append((time, chineseLine(step)))
                    moveRun = (items.count - 1, 1)
                }
            default:
                items.append((time, chineseLine(step)))
                moveRun = nil
            }
        }
        return items
    }
}

/// Fixes what Repeat's recorder captures beyond the user's intent.
enum RecordingCleaner {
    /// F9 / F10 as Java key codes: pressing them controls recording and playback, never content.
    static let hotkeyCodes: Set<Int> = [120, 121]

    /// - cutoffMs: drop everything from this offset on (the click/menu that stopped the recording).
    /// - trimTrailingMoves: drop moves at the end (the pointer travelling to the stop button).
    ///   Only when something else (a click or key) precedes them; a moves-only recording keeps them.
    static func clean(_ input: [Step], cutoffMs: Int?, trimTrailingMoves: Bool) -> [Step] {
        var kept: [Step] = []
        var time = 0
        for step in input {
            if let cutoff = cutoffMs, time >= cutoff { break }
            switch step {
            case .delay(let ms): time += ms
            case .keyPress(let k) where hotkeyCodes.contains(k), .keyRelease(let k) where hotkeyCodes.contains(k): continue
            default: break
            }
            kept.append(step)
        }

        // Pair releases with presses. Repeat records a left-button release with the right-button
        // mask, so a release takes the mask of the latest held button; unmatched releases (from
        // the input that started the recording) are dropped.
        var result: [Step] = []
        var heldButtons: [Int] = []
        var heldKeys: [Int] = []
        for step in kept {
            switch step {
            case .mousePress(let mask):
                heldButtons.append(mask)
                result.append(step)
            case .mouseRelease:
                guard let mask = heldButtons.popLast() else { continue }
                result.append(.mouseRelease(mask: mask))
            case .keyPress(let key):
                if !heldKeys.contains(key) { heldKeys.append(key) }
                result.append(step)
            case .keyRelease(let key):
                guard let index = heldKeys.firstIndex(of: key) else {
                    // Repeat's hook sees a CapsLock toggle only as a release: keep it as a tap.
                    if key == Keys.capsLock { result += [.keyPress(key: key), step] }
                    continue
                }
                heldKeys.remove(at: index)
                result.append(step)
            default:
                result.append(step)
            }
        }
        if trimTrailingMoves, result.contains(where: { !$0.isMove && !$0.isDelay }) {
            while let last = result.last, last.isMove || last.isDelay { result.removeLast() }
        }
        while result.last?.isDelay == true { result.removeLast() }
        // Never leave a button or key held down after playback.
        result += heldButtons.reversed().map { .mouseRelease(mask: $0) }
        result += heldKeys.reversed().map { .keyRelease(key: $0) }
        return mergeDelays(result)
    }

    /// Replaces the key steps of Repeat's recording with the ones this app recorded itself
    /// (`keys`: ms since the recording started by this app's clock). Repeat's hook misses right
    /// Control, Fn and CapsLock presses. The two clocks are aligned by the median offset between
    /// key events both saw.
    static func replacingKeys(in steps: [Step], with keys: [(ms: Int, step: Step)]) -> [Step] {
        var timed: [(ms: Int, step: Step)] = []
        var repeatKeys: [(ms: Int, step: Step)] = []
        var time = 0
        for step in steps {
            switch step {
            case .delay(let ms): time += ms
            case .keyPress, .keyRelease: repeatKeys.append((time, step))
            default: timed.append((time, step))
            }
        }

        func repeatView(_ step: Step) -> Step? {
            switch step {
            case .keyPress(let k): return Keys.repeatCode(k).map { .keyPress(key: $0) }
            case .keyRelease(let k): return Keys.repeatCode(k).map { .keyRelease(key: $0) }
            default: return nil
            }
        }
        var offsets: [Int] = []
        var next = 0
        for event in repeatKeys {
            guard let found = keys[next...].prefix(20).firstIndex(where: {
                repeatView($0.step) == event.step && abs($0.ms - event.ms) < 2000
            }) else { continue }
            offsets.append(keys[found].ms - event.ms)
            next = found + 1
        }
        let offset = offsets.isEmpty ? 0 : offsets.sorted()[offsets.count / 2]

        // Stable sort: on equal times Repeat's steps (e.g. a click) stay before the keys.
        let merged = (timed + keys.map { (max(0, $0.ms - offset), $0.step) })
            .enumerated().sorted { ($0.element.ms, $0.offset) < ($1.element.ms, $1.offset) }.map(\.element)
        var result: [Step] = []
        time = 0
        for item in merged {
            if item.ms > time { result.append(.delay(ms: item.ms - time)); time = item.ms }
            result.append(item.step)
        }
        return result
    }

    /// Steps as Repeat can compile them (right-hand modifiers become the generic keys), and
    /// the steps it has no key code for.
    static func forRepeat(_ steps: [Step]) -> (steps: [Step], unsupported: [Step]) {
        var unsupported: [Step] = []
        let converted: [Step] = steps.compactMap { step in
            switch step {
            case .keyPress(let k), .keyRelease(let k):
                guard let code = Keys.repeatCode(k) else { unsupported.append(step); return nil }
                if case .keyPress = step { return .keyPress(key: code) }
                return .keyRelease(key: code)
            default:
                return step
            }
        }
        return (mergeDelays(converted), unsupported)
    }

    /// Drops presses of bound hotkeys (they trigger playback, not content) and the modifiers
    /// held only for them. A modifier also used for another key or a click is kept.
    static func removingHotkeys(_ steps: [Step], _ hotkeys: [Hotkey]) -> [Step] {
        guard !hotkeys.isEmpty else { return steps }
        var drop = Set<Int>()
        var droppedKeys = Set<Int>()
        var held: [Int: (index: Int, flag: UInt, forHotkey: Bool, forOther: Bool)] = [:]
        func markHeld(hotkey: Bool) {
            for key in held.keys { if hotkey { held[key]!.forHotkey = true } else { held[key]!.forOther = true } }
        }
        for (index, step) in steps.enumerated() {
            switch step {
            case .keyPress(let key):
                guard let mac = Keys.macCode(key) else { markHeld(hotkey: false); continue }
                if let modifier = Keys.modifiers[mac] {
                    if held[key] == nil { held[key] = (index, UInt(modifier.flag.rawValue), false, false) }
                    continue
                }
                let flags = held.values.reduce(UInt(0)) { $0 | $1.flag } & Hotkey.modifierMask
                if hotkeys.contains(Hotkey(key: mac, modifiers: flags)) {
                    drop.insert(index)
                    droppedKeys.insert(key)
                    markHeld(hotkey: true)
                } else {
                    markHeld(hotkey: false)
                }
            case .keyRelease(let key):
                if droppedKeys.remove(key) != nil {
                    drop.insert(index)
                } else if let entry = held.removeValue(forKey: key), entry.forHotkey, !entry.forOther {
                    drop.formUnion([entry.index, index])
                }
            case .mousePress:
                markHeld(hotkey: false)
            default:
                break
            }
        }
        for entry in held.values where entry.forHotkey && !entry.forOther { drop.insert(entry.index) }
        return steps.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
    }

    private static func mergeDelays(_ steps: [Step]) -> [Step] {
        var merged: [Step] = []
        for step in steps {
            if case .delay(let ms) = step, case .delay(let previous)? = merged.last {
                merged[merged.count - 1] = .delay(ms: previous + ms)
            } else {
                merged.append(step)
            }
        }
        return merged
    }
}

/// Plays steps by posting CGEvents directly. Repeat's own player (java.awt.Robot) types keys
/// twice or more on this macOS ("hi" → "h h ii"), so playback does not go through it.
final class Player {
    private let queue = DispatchQueue(label: "repeat.player")
    private let lock = NSLock()
    private var cancelled = false
    private var location = CGPoint.zero
    private var heldButtons: [CGMouseButton] = []
    private var heldKeys: [CGKeyCode] = []

    /// Flags of the modifiers currently held down, with the left/right device bits real keyboards set.
    private var flags: CGEventFlags {
        heldKeys.reduce(into: CGEventFlags()) { flags, code in
            guard let modifier = Keys.modifiers[code] else { return }
            flags.formUnion(modifier.flag)
            flags.formUnion(CGEventFlags(rawValue: modifier.device))
        }
    }

    /// Steps the player cannot perform (anything Repeat's recorder doesn't produce).
    static func unsupported(_ steps: [Step]) -> [Step] {
        steps.filter {
            switch $0 {
            case .other: return true
            case .keyPress(let k), .keyRelease(let k): return Keys.macCode(k) == nil
            case .mousePress(let m), .mouseRelease(let m): return button(m) == nil
            default: return false
            }
        }
    }

    private static func button(_ mask: Int) -> CGMouseButton? {
        [1024: .left, 2048: .center, 4096: .right][mask]
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Plays `steps` `count` times (delays scaled by 1/speed); `progress` gets the 1-based
    /// iteration, `done` whether it ran to completion. Callbacks arrive on the main queue.
    /// Starts once the user has let go of the modifiers and of `trigger` (the hotkey's key).
    func play(_ steps: [Step], count: Int, speed: Double, gap: TimeInterval, trigger: CGKeyCode? = nil,
              progress: @escaping (Int) -> Void, done: @escaping (Bool) -> Void) {
        queue.async { [self] in
            waitForKeysUp(trigger)
            location = CGEvent(source: nil)?.location ?? .zero
            outer: for iteration in 1...count {
                DispatchQueue.main.async { progress(iteration) }
                for step in steps {
                    if isCancelled { break outer }
                    perform(step, speed: speed)
                }
                if iteration < count && !wait(ms: Int(gap * 1000)) { break }
            }
            releaseAll()
            let completed = !isCancelled
            DispatchQueue.main.async { done(completed) }
        }
    }

    /// Physically held modifiers would mix into the replayed input (⌃⌥ + "h" instead of "h").
    /// Waits at most 3 s, then plays anyway.
    private func waitForKeysUp(_ trigger: CGKeyCode?) {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        let end = Date().addingTimeInterval(3)
        while Date() < end && !isCancelled {
            let flags = CGEventSource.flagsState(.hidSystemState).intersection(modifiers)
            let keyDown = trigger.map { CGEventSource.keyState(.hidSystemState, key: $0) } ?? false
            if flags.isEmpty && !keyDown { return }
            usleep(20_000)
        }
    }

    /// Sleeps in small slices so cancellation is prompt; false when cancelled.
    private func wait(ms: Int) -> Bool {
        let end = Date().addingTimeInterval(Double(ms) / 1000)
        while Date() < end {
            if isCancelled { return false }
            usleep(useconds_t(min(20_000, max(0, end.timeIntervalSinceNow * 1_000_000))))
        }
        return !isCancelled
    }

    private func perform(_ step: Step, speed: Double) {
        switch step {
        case .delay(let ms):
            _ = wait(ms: Int((Double(ms) / speed).rounded()))
        case .move(let x, let y):
            location = CGPoint(x: x, y: y)
            let type: CGEventType = heldButtons.contains(.left) ? .leftMouseDragged
                : heldButtons.contains(.right) ? .rightMouseDragged
                : heldButtons.isEmpty ? .mouseMoved : .otherMouseDragged
            postMouse(type, button: heldButtons.last ?? .left)
        case .mousePress(let mask):
            guard let button = Self.button(mask) else { return }
            heldButtons.append(button)
            postMouse(button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown, button: button)
        case .mouseRelease(let mask):
            guard let button = Self.button(mask) else { return }
            heldButtons.removeAll { $0 == button }
            postMouse(button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp, button: button)
        case .keyPress(let key):
            guard let code = Keys.macCode(key) else { return }
            if !heldKeys.contains(code) { heldKeys.append(code) }
            postKey(code, down: true)
        case .keyRelease(let key):
            guard let code = Keys.macCode(key) else { return }
            heldKeys.removeAll { $0 == code }
            postKey(code, down: false)
        case .other:
            break
        }
    }

    private func postMouse(_ type: CGEventType, button: CGMouseButton) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Call after updating `heldKeys`. Modifiers are sent as flagsChanged like a real keyboard
    /// (some apps ignore a modifier's keyDown); CapsLock toggles the system's lock state.
    private func postKey(_ code: CGKeyCode, down: Bool) {
        if code == Keys.capsLockMac {
            if down { Self.toggleCapsLock() }
            return
        }
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        if Keys.modifiers[code] != nil { event?.type = .flagsChanged }
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private static func toggleCapsLock() {
        var connection: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connection) }
        var on = false
        IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &on)
        IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), !on)
    }

    /// Never leave a button or key held down, also after cancellation midway.
    private func releaseAll() {
        for button in heldButtons.reversed() {
            postMouse(button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp, button: button)
        }
        heldButtons = []
        while let code = heldKeys.popLast() { postKey(code, down: false) }
    }
}

/// Records the keyboard with a listen-only event tap, enabled only while recording. Repeat's
/// own hook misses right Control, Fn and CapsLock presses.
final class KeyRecorder {
    private var tap: CFMachPort?
    private let lock = NSLock()
    private var events: [(time: Date, step: Step)] = []
    private var capsOn = false
    /// When capturing started; nil when not capturing.
    private(set) var capturingSince: Date?

    var isAvailable: Bool { tap != nil }

    /// Creates the tap on its own thread; false when the system refuses it (no permission).
    @discardableResult
    func install() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
            callback: { _, type, event, info in
                Unmanaged<KeyRecorder>.fromOpaque(info!).takeUnretainedValue().handle(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        CGEvent.tapEnable(tap: tap, enable: false)
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "repeat.keys"
        thread.start()
        return true
    }

    func start() {
        guard let tap else { return }
        lock.lock()
        events = []
        capsOn = CGEventSource.flagsState(.combinedSessionState).contains(.maskAlphaShift)
        capturingSince = Date()
        lock.unlock()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Stops capturing; returns the key steps with their times.
    @discardableResult
    func stop() -> [(time: Date, step: Step)] {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        lock.lock(); defer { lock.unlock() }
        capturingSince = nil
        let captured = events
        events = []
        return captured
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        let now = Date()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, capturingSince != nil { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let mac = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let code = Keys.code(mac: mac)
        lock.lock(); defer { lock.unlock() }
        guard capturingSince != nil else { return }
        switch type {
        case .keyDown: events.append((now, .keyPress(key: code)))
        case .keyUp: events.append((now, .keyRelease(key: code)))
        case .flagsChanged:
            if mac == Keys.capsLockMac {
                // One toggle = one tap; flagsChanged may also come on release without a change.
                let on = event.flags.contains(.maskAlphaShift)
                guard on != capsOn else { return }
                capsOn = on
                events += [(now, .keyPress(key: code)), (now, .keyRelease(key: code))]
            } else if let down = Self.isDown(mac, flags: event.flags) {
                events.append((now, down ? .keyPress(key: code) : .keyRelease(key: code)))
            }
        default: break
        }
    }

    /// Whether a flagsChanged event of modifier `mac` is its press. The device bit tells left
    /// from right; events without device bits (synthesized ones) fall back to the generic flag.
    static func isDown(_ mac: CGKeyCode, flags: CGEventFlags) -> Bool? {
        guard let modifier = Keys.modifiers[mac] else { return nil }
        let raw = flags.rawValue
        if raw & modifier.device != 0 { return true }
        guard flags.contains(modifier.flag) else { return false }
        // Flag still set: either the other side is still held (this is the release) or no device bits.
        return raw & modifier.other == 0
    }
}

struct Recording {
    var steps: [Step]
    var name: String?
    var url: URL?
    var saved: Bool
}

struct MessageError: Error {
    let message: String
}

// MARK: - Hotkeys

/// A global shortcut: macOS virtual key code plus modifier flags (the ⌃⌥⇧⌘ bits, which are the
/// same in CGEventFlags and NSEvent.ModifierFlags).
struct Hotkey: Codable, Hashable {
    var key: CGKeyCode
    var modifiers: UInt

    static let modifierMask = UInt(CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand]).rawValue)

    init(key: CGKeyCode, modifiers: UInt) {
        self.key = key
        self.modifiers = modifiers & Self.modifierMask
    }

    private func has(_ flag: CGEventFlags) -> Bool { modifiers & UInt(flag.rawValue) != 0 }

    /// "⌃⌥1", in the order macOS menus use.
    var display: String { Self.symbols(modifiers) + Self.keyName(key) }

    static func symbols(_ modifiers: UInt) -> String {
        let symbols: [(CGEventFlags, String)] = [(.maskControl, "⌃"), (.maskAlternate, "⌥"), (.maskShift, "⇧"), (.maskCommand, "⌘")]
        return symbols.filter { modifiers & UInt($0.0.rawValue) != 0 }.map(\.1).joined()
    }

    static func keyName(_ key: CGKeyCode) -> String {
        let symbols: [CGKeyCode: String] = [123: "←", 124: "→", 125: "↓", 126: "↑", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦"]
        return symbols[key] ?? Keys.name(Keys.code(mac: key))
    }

    var isFunctionKey: Bool {
        let name = Keys.name(Keys.code(mac: key))
        return name.hasPrefix("F") && Int(name.dropFirst()) != nil
    }

    /// Why this can't be a hotkey; nil when it can.
    var problem: String? {
        if [HotKey.record, HotKey.play, HotKey.escape].contains(key) { return "F9、F10、Esc 已用于录制和播放，不能绑定。" }
        if Keys.modifiers[key] != nil || key == Keys.capsLockMac { return "请按下修饰键加一个普通键，例如 ⌃⌥1。" }
        // ⌥ / ⇧ alone still type characters (⌥A = å) or edit text (⌥← = previous word).
        let needed = UInt(CGEventFlags([.maskControl, .maskCommand]).rawValue)
        if modifiers & needed == 0 && !isFunctionKey {
            return "请至少配合 ⌃ 或 ⌘（F 键除外），否则会影响正常打字。"
        }
        return nil
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if has(.maskControl) { result |= controlKey }
        if has(.maskAlternate) { result |= optionKey }
        if has(.maskShift) { result |= shiftKey }
        if has(.maskCommand) { result |= cmdKey }
        return UInt32(result)
    }
}

/// A recording file bound to a hotkey. Only the path is stored: the file is read on every
/// trigger, so edits to it take effect immediately.
struct HotkeyBinding: Codable, Equatable {
    var hotkey: Hotkey
    var path: String
    var count: Int
    var speed: Double

    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var fileExists: Bool { FileManager.default.fileExists(atPath: path) }

    func loadSteps() throws -> [Step] {
        guard fileExists else { throw MessageError(message: "找不到录制文件「\(name)」") }
        do {
            let steps = try RecordingFormat.parse(try String(contentsOf: url, encoding: .utf8))
            guard steps.contains(where: { !$0.isDelay }) else { throw MessageError(message: "「\(name)」里没有任何操作") }
            return steps
        } catch let error as FormatError {
            throw MessageError(message: "「\(name)」\(error.message)")
        } catch let error as MessageError {
            throw error
        } catch {
            throw MessageError(message: "无法读取「\(name)」：\(error.localizedDescription)")
        }
    }

    static func load() -> [HotkeyBinding] {
        guard let data = try? Data(contentsOf: hotkeysURL) else { return [] }
        return (try? JSONDecoder().decode([HotkeyBinding].self, from: data)) ?? []
    }

    static func save(_ bindings: [HotkeyBinding]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(bindings).write(to: hotkeysURL, options: .atomic)
    }
}

/// System-wide hotkeys via Carbon's RegisterEventHotKey: needs no privacy permission, and the
/// press is consumed (the front app never sees it). Presses arrive on the main thread.
final class GlobalHotkeys {
    private static let signature: OSType = 0x5250_544B  // "RPTK"
    private var refs: [EventHotKeyRef] = []
    private var hotkeys: [Hotkey] = []
    private var handler: EventHandlerRef?
    var onPress: ((Hotkey) -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, info in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let info else { return status }
            let me = Unmanaged<GlobalHotkeys>.fromOpaque(info).takeUnretainedValue()
            if id.signature == GlobalHotkeys.signature, me.hotkeys.indices.contains(Int(id.id)) {
                me.onPress?(me.hotkeys[Int(id.id)])
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// Replaces all registrations; returns the hotkeys the system refused (taken by another app).
    @discardableResult
    func register(_ list: [Hotkey]) -> [Hotkey] {
        unregisterAll()
        var refused: [Hotkey] = []
        for (index, hotkey) in list.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index))
            if RegisterEventHotKey(UInt32(hotkey.key), hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
            } else {
                refused.append(hotkey)
            }
        }
        hotkeys = list
        return refused
    }

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        hotkeys = []
    }

    /// Whether another app already holds `hotkey` (system shortcuts like ⌘Space are not detected).
    func isTaken(_ hotkey: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: UInt32.max)
        guard RegisterEventHotKey(UInt32(hotkey.key), hotkey.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
              let ref else { return true }
        UnregisterEventHotKey(ref)
        return false
    }
}

// MARK: - Backend operations on recordings

/// Repeat has no API for exporting or loading one recording, so this drives its manual-build
/// compiler: compiling writes the step file into `manualSourceDir`.
enum Recordings {
    static let fileExtension = "repeat"
    /// Declared in Info.plist (UTExportedTypeDeclarations); resolves once the app is registered.
    static let contentType = UTType("local.repeat.recording") ?? UTType(filenameExtension: fileExtension)!

    private static func manualFiles() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: manualSourceDir.path)) ?? [])
    }

    /// Runs `compile`, then returns the step file it produced. Needed because the compile
    /// endpoints answer 200 even when compilation fails; a new file is the only success signal.
    private static func compileProducingFile(_ compile: (@escaping (String?) -> Void) -> Void,
                                             _ done: @escaping (Result<String, RecordingError>) -> Void) {
        let before = manualFiles()
        compile { response in
            guard response != nil else { return done(.failure(.backend)) }
            guard let name = manualFiles().subtracting(before).sorted().last,
                  let text = try? String(contentsOf: manualSourceDir.appendingPathComponent(name), encoding: .utf8)
            else { return done(.failure(.compileFailed)) }
            done(.success(text))
        }
    }

    /// The steps of Repeat's last recording, as recorded.
    static func exportLast(_ done: @escaping (Result<[Step], RecordingError>) -> Void) {
        selectManualLanguage { ok in
            guard ok else { return done(.failure(.backend)) }
            Backend.post("internals/menu/tools/generate-source") { body in
                guard let body, let data = body.data(using: .utf8),
                      let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let page = response["page"] as? String,
                      let id = allMatches(#"manually-build-task-id"[^>]*>([0-9a-f-]{36})<"#, in: page).first
                else { return done(.failure(.backend)) }
                compileProducingFile({ finish in
                    Backend.post("internals/action/manually-build/constructor/build", body: Backend.json(["id": id]), finish)
                }) { done($0.map(RecordingFormat.parseNative)) }
            }
        }
    }

    /// Compiles steps into Repeat's current task, ready for `run-compiled-task`.
    static func load(_ steps: [Step], _ done: @escaping (Result<Void, RecordingError>) -> Void) {
        selectManualLanguage { ok in
            guard ok else { return done(.failure(.backend)) }
            compileProducingFile({ finish in
                Backend.post("internals/action/compile-task", body: RecordingFormat.native(steps), finish)
            }) { done($0.map { _ in () }) }
        }
    }

    /// Adds the current compiled task to the task list; returns the name it got.
    static func addCurrentAsTask(named name: String, _ done: @escaping (String?) -> Void) {
        Backend.post("internals/action/add-task") { table in
            // The response re-renders the task table; the new task is the last row.
            guard let table, let id = allMatches(#"div-task-id-([0-9a-f-]{36})"#, in: table).last
            else { return done(nil) }
            let taskName = asciiTaskName(name)
            Backend.post("internals/modify/task-name", body: Backend.json(["task": id, "name": taskName])) {
                done($0 == nil ? nil : taskName)
            }
        }
    }

    /// Repeat stores task names as UTF-8 but serves its HTML as ISO-8859-1, so non-Latin names
    /// render as "??" in its UI. Transliterate (e.g. 录制 → lu zhi) to keep names readable.
    static func asciiTaskName(_ name: String) -> String {
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let ascii = String(latin.unicodeScalars.filter(\.isASCII).map(Character.init))
        return ascii.trimmingCharacters(in: .whitespaces).isEmpty ? "Recording" : ascii
    }

    private static func selectManualLanguage(_ done: @escaping (Bool) -> Void) {
        Backend.get("internals/menu/tools/get-compiling-languages-options") { html in
            guard let html else { return done(false) }
            let labels = allMatches(#"<label[^>]*>\s*([^<]*?)\s*</label>"#, in: html)
            guard let index = labels.firstIndex(of: "manual") else { return done(false) }
            Backend.post("internals/menu/tools/set-compiling-language", body: Backend.json(["index": index])) { done($0 != nil) }
        }
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}

enum RecordingError: Error {
    case backend, compileFailed

    var message: String {
        switch self {
        case .backend: return "与 Repeat 后台通信失败，请查看日志。"
        case .compileFailed: return "Repeat 无法处理这段录制，详情见日志。"
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKUIDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var advancedWindow: NSWindow?
    private var advancedWebView: WKWebView?
    private var statusItem: NSStatusItem!

    private let statusLabel = NSTextField(labelWithString: "")
    private var recordButton: NSButton!
    private var playButton: NSButton!
    private var saveButton: NSButton!
    private var bindButton: NSButton!
    private let countField = NSTextField()
    private let countStepper = NSStepper()
    private let speedPopup = NSPopUpButton()
    private let recordingTitle = NSTextField(labelWithString: "")
    private let recordingSummary = NSTextField(labelWithString: "")
    private var stepsView: NSTextView!
    private var recordItem: NSMenuItem!
    private var playItem: NSMenuItem!

    private var process: Process?
    private var quitting = false
    private var restarting = false
    private var permissionTimer: Timer?
    private var pollTimer: Timer?
    private var backendReady = false

    private var isRecording = false
    private var isRunningTask = false
    private var isReplaying = false
    private var current: Recording?
    private var playback: (iteration: Int, total: Int, name: String?)?
    private var player: Player?
    private let keyRecorder = KeyRecorder()
    private var hidForPlayback = false
    /// When the recording started / when the in-app click or menu that stopped it began.
    private var recordStartedAt: Date?
    private var uiStopAt: Date?
    /// Recent input events received by this app (clicks, keys, menu opens).
    private var localInputTimes: [Date] = []
    private var monitors: [Any] = []

    private var bindings = HotkeyBinding.load()
    private let globalHotkeys = GlobalHotkeys()
    private var hotkeysWindow: HotkeysWindowController?
    /// While the binding editor is open, hotkeys are unregistered so they can be typed into it.
    private var editingHotkey = false
    /// A transient status-line message (ignored hotkey, missing file, …).
    private var notice: (text: String, color: NSColor, until: Date)?
    /// Opts out of App Nap: while hidden, the app must still poll and drive playback.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Controls Repeat record/replay")

    // Built before didFinishLaunching: a document opened from Finder at launch is delivered in between.
    func applicationWillFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
        buildStatusItem()
        installMonitors()
        globalHotkeys.onPress = { [weak self] in self?.hotkeyPressed($0) }
        registerHotkeys()
        showCurrent()
        refreshUI()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Backend.get("internals/get/is-recording") { [weak self] body in
            guard let self else { return }
            if body == nil {
                // The Java child inherits this app's privacy permissions, so request them here.
                self.ensurePermissions()
                self.startBackend()
            }
            self.installKeyRecorder()
            self.waitForBackend(attempt: 0)
        }
    }

    // MARK: Permissions

    // Repeat's event tap needs Accessibility only (verified: hook runs without Input Monitoring).
    private var hasPermissions: Bool { AXIsProcessTrusted() }

    private func ensurePermissions() {
        guard !hasPermissions else { return }
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        // Native hook only attaches at backend start, so restart it once access is granted.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self, self.hasPermissions else { return }
            timer.invalidate()
            self.permissionTimer = nil
            self.installKeyRecorder()
            self.restartBackend()
        }
    }

    /// The key tap works with Accessibility alone on some systems; otherwise it needs Input
    /// Monitoring, which is requested once (recordings then fall back to Repeat's key steps).
    private func installKeyRecorder() {
        guard hasPermissions, !keyRecorder.install() else { return refreshUI() }
        NSLog("Repeat: keyboard event tap refused; requesting Input Monitoring")
        if !UserDefaults.standard.bool(forKey: "requestedListenAccess") {
            UserDefaults.standard.set(true, forKey: "requestedListenAccess")
            CGRequestListenEventAccess()
        }
        refreshUI()
    }

    @objc private func restartBackend() {
        guard let p = process, p.isRunning else {
            info("当前后台不是由本 App 启动的，请先退出它再打开本 App。")
            return
        }
        restarting = true
        backendReady = false
        refreshUI()
        stopBackend(p) { [weak self] in
            guard let self else { return }
            self.restarting = false
            self.startBackend()
            self.waitForBackend(attempt: 0)
        }
    }

    /// Graceful exit lets the backend save config and stop its native hook process.
    private func stopBackend(_ p: Process, then done: @escaping () -> Void) {
        // Drop the step files every compile leaves behind (those not used by a task).
        Backend.post("internals/menu/file/clean-unused-sources") { _ in
            Backend.post("internals/menu/file/exit")
        }
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(15)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate(); p.waitUntilExit() }
            Backend.disableReplayHotkeys()  // A first run writes config.json with them on exit.
            DispatchQueue.main.async(execute: done)
        }
    }

    // MARK: Backend lifecycle

    private func startBackend() {
        guard FileManager.default.fileExists(atPath: jarURL.path) else {
            fail("找不到 \(jarURL.path)")
            return
        }
        Backend.disableReplayHotkeys()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/java")
        // UIElement: no separate Java Dock icon; this app owns the Dock presence.
        p.arguments = ["-Dapple.awt.UIElement=true", "-jar", jarURL.lastPathComponent]
        p.currentDirectoryURL = dataDir
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.quitting, !self.restarting else { return }
                self.process = nil
                self.fail("Repeat 后台已退出（代码 \(proc.terminationStatus)）。日志：\(logURL.path)")
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            fail("无法启动 Java：\(error.localizedDescription)")
        }
    }

    /// The UI server answers before the backend finishes initializing, and initialization resets
    /// the current compiled task, so a backend we launched is ready only once it logs completion.
    private var backendInitialized: Bool {
        guard process != nil else { return true }
        return (try? String(contentsOf: logURL, encoding: .utf8))?.contains("Initialization finished") ?? false
    }

    private func waitForBackend(attempt: Int) {
        Backend.get("internals/get/is-recording") { [weak self] body in
            guard let self else { return }
            if body != nil && self.backendInitialized {
                self.backendReady = true
                if self.pollTimer == nil { self.startPolling() }
                self.advancedWebView?.load(URLRequest(url: baseURL))
                self.refreshUI()
            } else if attempt < 120 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.waitForBackend(attempt: attempt + 1) }
            } else {
                self.fail("后台 60 秒内未就绪。日志：\(logURL.path)")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let p = process, p.isRunning else { return .terminateNow }
        quitting = true
        pollTimer?.invalidate()
        permissionTimer?.invalidate()
        stopBackend(p) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func fail(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Repeat"
        alert.informativeText = message
        alert.addButton(withTitle: "打开日志")
        alert.addButton(withTitle: "退出")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(logURL) }
        NSApp.terminate(nil)
    }

    /// Sheet on the main window (no nested modal loop inside network/timer callbacks).
    private func info(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Repeat"
        alert.informativeText = message
        showWindow()
        if window.attachedSheet == nil { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Status polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    private func poll() {
        Backend.get("internals/get/is-recording", timeout: 1) { [weak self] body in
            guard let self, let body else { return }
            let recording = body == "true"
            // F9 released but Repeat did not start recording.
            if !recording, !self.isRecording, let since = self.keyRecorder.capturingSince,
               since < Date(timeIntervalSinceNow: -3) { self.keyRecorder.stop() }
            guard recording != self.isRecording else { return }
            self.isRecording = recording
            recording ? self.recordingDidStart() : self.recordingDidStop()
            self.refreshUI()
        }
        Backend.get("internals/get/is-running-compiled-task", timeout: 1) { [weak self] body in
            guard let self, let body, (body == "true") != self.isRunningTask else { return }
            self.isRunningTask = body == "true"
            self.refreshUI()
        }
        Backend.get("internals/get/is-replaying", timeout: 1) { [weak self] body in
            guard let self, let body, (body == "true") != self.isReplaying else { return }
            self.isReplaying = body == "true"
            self.refreshUI()
        }
    }

    // MARK: Hotkeys and input tracking

    private func installMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { [weak self] event in
            _ = self?.handleHotkey(event)
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type != .keyUp { self.noteLocalInput(Self.date(of: event)) }
            return self.handleHotkey(event) ? nil : event
        }) { monitors.append(m) }
    }

    /// Returns true when the event was consumed.
    private func handleHotkey(_ event: NSEvent) -> Bool {
        // keyCode is only valid on key events (reading it on a mouse event throws).
        guard event.type == .keyDown || event.type == .keyUp, !editingHotkey else { return false }
        switch (event.type, event.keyCode) {
        case (.keyUp, HotKey.record) where !isRecording:
            // Repeat starts recording when F9 is released.
            recordStartedAt = Self.date(of: event)
            startKeyCapture()
            return false
        case (.keyDown, HotKey.play):
            if !event.isARepeat { togglePlay() }
            return true
        case (.keyDown, HotKey.escape) where playback != nil:
            stopPlayback()
            return false
        default:
            return false
        }
    }

    private static func date(of event: NSEvent) -> Date {
        Date(timeIntervalSinceNow: event.timestamp - ProcessInfo.processInfo.systemUptime)
    }

    private func noteLocalInput(_ date: Date) {
        localInputTimes.append(date)
        localInputTimes.removeAll { $0 < Date(timeIntervalSinceNow: -10) }
    }

    private func earliestLocalInput(within seconds: TimeInterval) -> Date? {
        localInputTimes.filter { $0 > Date(timeIntervalSinceNow: -seconds) }.min()
    }

    func menuWillOpen(_ menu: NSMenu) {
        noteLocalInput(Date(timeIntervalSinceNow: -0.05))
        refreshUI()
    }

    // MARK: Recording

    @objc private func toggleRecord() {
        guard backendReady, playback == nil else { return }
        if isRecording {
            // The click / shortcut / menu used to stop is part of the recording; cut from its start.
            uiStopAt = earliestLocalInput(within: 3) ?? Date()
            Backend.post("internals/action/stop-record") { [weak self] _ in self?.poll() }
        } else {
            recordStartedAt = Date()
            startKeyCapture()
            Backend.post("internals/action/start-record") { [weak self] _ in self?.poll() }
        }
    }

    private func recordingDidStart() {
        if recordStartedAt.map({ $0 < Date(timeIntervalSinceNow: -3) }) ?? true {
            // Started elsewhere (e.g. the advanced window): best estimate.
            recordStartedAt = earliestLocalInput(within: 2) ?? Date(timeIntervalSinceNow: -0.25)
        }
        if keyRecorder.capturingSince == nil { startKeyCapture() }
    }

    private func startKeyCapture() {
        if !keyRecorder.isAvailable { installKeyRecorder() }
        keyRecorder.start()
    }

    private func recordingDidStop() {
        let stopAt = uiStopAt
        var cutoff: Int?
        if let stopAt, let startAt = recordStartedAt {
            cutoff = max(0, Int(stopAt.timeIntervalSince(startAt) * 1000) - 30)
        }
        // The app's own key events, as ms since the start (nil: no tap, keep Repeat's).
        var keys: [(ms: Int, step: Step)]?
        if keyRecorder.capturingSince != nil {
            let captured = keyRecorder.stop()
            if let startAt = recordStartedAt {
                keys = captured.map { (Int($0.time.timeIntervalSince(startAt) * 1000), $0.step) }
            }
        }
        uiStopAt = nil
        recordStartedAt = nil
        Recordings.exportLast { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.info(error.message)
            case .success(var raw):
                if let keys { raw = RecordingCleaner.replacingKeys(in: raw, with: keys) }
                raw = RecordingCleaner.removingHotkeys(raw, self.bindings.map(\.hotkey))
                let steps = RecordingCleaner.clean(raw, cutoffMs: cutoff, trimTrailingMoves: stopAt != nil)
                guard steps.contains(where: { !$0.isDelay }) else {
                    return self.info("这次录制没有捕获到任何操作。")
                }
                self.current = Recording(steps: steps, name: nil, url: nil, saved: false)
                self.showCurrent()
                self.refreshUI()
            }
        }
    }

    // MARK: Playback

    @objc private func togglePlay() {
        playback != nil ? stopPlayback() : startPlayback()
    }

    private func startPlayback() {
        guard let recording = current else { return }
        let total = max(1, min(999, countField.integerValue))
        let speed = speedPopup.selectedItem?.representedObject as? Double ?? 1
        UserDefaults.standard.set(total, forKey: "playCount")
        UserDefaults.standard.set(speed, forKey: "playSpeed")
        play(recording.steps, name: nil, count: total, speed: speed)
    }

    /// `trigger`: the hotkey's key, so playback waits until it is released.
    private func play(_ steps: [Step], name: String?, count total: Int, speed: Double, trigger: CGKeyCode? = nil) {
        guard hasPermissions, !isRecording, playback == nil else { return }
        let unsupported = Player.unsupported(steps)
        guard unsupported.isEmpty else {
            let lines = unsupported.prefix(3).map(RecordingFormat.chineseLine).joined(separator: "\n")
            return info("录制\(name.map { "「\($0)」" } ?? "")里有无法播放的操作：\n\(lines)")
        }
        playback = (1, total, name)
        // Keep this window from catching replayed input; give focus back to the previous app.
        hidForPlayback = NSApp.isActive
        if hidForPlayback { NSApp.hide(nil) }
        refreshUI()
        let player = Player()
        self.player = player
        DispatchQueue.main.asyncAfter(deadline: .now() + (hidForPlayback ? 0.5 : 0)) { [weak self] in
            guard let self, self.player === player else { return }
            player.play(steps, count: total, speed: speed, gap: 0.5, trigger: trigger, progress: { iteration in
                guard self.player === player else { return }
                self.playback = (iteration, total, name)
                self.refreshUI()
            }, done: { _ in
                guard self.player === player else { return }
                self.finishPlayback()
            })
        }
    }

    private func stopPlayback() {
        guard playback != nil else { return }
        player?.cancel()
        finishPlayback()
    }

    private func finishPlayback() {
        player = nil
        playback = nil
        if hidForPlayback {
            hidForPlayback = false
            NSApp.unhide(nil)
        }
        refreshUI()
    }

    // MARK: Hotkey bindings

    /// Hotkeys stay registered while recording: pressing one then is consumed and ignored, and
    /// `RecordingCleaner.removingHotkeys` drops whatever the recorders still saw of it.
    private func registerHotkeys() {
        guard !editingHotkey else { return globalHotkeys.unregisterAll() }
        let refused = globalHotkeys.register(bindings.map(\.hotkey))
        if !refused.isEmpty {
            notify("快捷键 \(refused.map(\.display).joined(separator: "、")) 已被其他应用占用，无法使用", beep: false)
        }
    }

    private func setBindings(_ list: [HotkeyBinding]) {
        bindings = list
        HotkeyBinding.save(list)
        registerHotkeys()
        hotkeysWindow?.reload()
        refreshUI()
    }

    private func hotkeyPressed(_ hotkey: Hotkey) {
        guard let binding = bindings.first(where: { $0.hotkey == hotkey }) else { return }
        let key = hotkey.display
        // Also covers presses replayed by this app's own player (no recursion).
        if playback != nil { return notify("正在播放，已忽略快捷键 \(key)。按 Esc 中止") }
        if isRecording || keyRecorder.capturingSince != nil { return notify("正在录制，已忽略快捷键 \(key)") }
        if isRunningTask || isReplaying { return notify("Repeat 正在运行任务，已忽略快捷键 \(key)") }
        guard hasPermissions else { return notify("需要辅助功能权限才能播放") }
        do {
            let steps = try binding.loadSteps()
            play(steps, name: binding.name, count: binding.count, speed: binding.speed, trigger: hotkey.key)
        } catch {
            notify("快捷键 \(key)：\((error as? MessageError)?.message ?? "\(error)")")
            hotkeysWindow?.reload()
        }
    }

    private func notify(_ text: String, color: NSColor = .systemOrange, beep: Bool = true) {
        if beep { NSSound.beep() }
        let until = Date().addingTimeInterval(4)
        notice = (text, color, until)
        refreshUI()
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.05) { [weak self] in
            guard let self, self.notice?.until == until else { return }
            self.notice = nil
            self.refreshUI()
        }
    }

    /// Binds the current recording; it must be saved first, since bindings refer to the file.
    @objc private func bindCurrent() {
        guard let recording = current, !isRecording, !editingHotkey else { return }
        guard let url = recording.url, recording.saved else {
            let alert = NSAlert()
            alert.messageText = "请先保存录制"
            alert.informativeText = "快捷键播放的是录制文件；以后修改了文件，按快捷键播放的内容也会随之更新。"
            alert.addButton(withTitle: "保存…")
            alert.addButton(withTitle: "取消")
            showWindow()
            alert.beginSheetModal(for: window) { [weak self] in
                if $0 == .alertFirstButtonReturn { self?.saveRecording(then: { self?.bindCurrent() }) }
            }
            return
        }
        showWindow()
        editBinding(at: bindings.firstIndex { $0.path == url.path }, path: url.path, on: window)
    }

    /// Opens the binding editor for `bindings[index]`, or for a new binding of `path`.
    private func editBinding(at index: Int?, path: String, on parent: NSWindow) {
        guard !editingHotkey, parent.attachedSheet == nil else { return }
        let existing = index.map { bindings[$0] }
        let editor = BindingEditor(
            name: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            hotkey: existing?.hotkey,
            count: existing?.count ?? max(1, min(999, countField.integerValue)),
            speed: existing?.speed ?? (speedPopup.selectedItem?.representedObject as? Double ?? 1))
        editor.validate = { [weak self] hotkey in
            if let problem = hotkey.problem { return problem }
            guard let self else { return nil }
            if let other = self.bindings.indices.first(where: { $0 != index && self.bindings[$0].hotkey == hotkey }) {
                return "\(hotkey.display) 已绑定到「\(self.bindings[other].name)」。"
            }
            if self.globalHotkeys.isTaken(hotkey) { return "\(hotkey.display) 已被其他应用占用。" }
            return nil
        }
        editingHotkey = true
        registerHotkeys()
        editor.begin(on: parent) { [weak self] result in
            guard let self else { return }
            self.editingHotkey = false
            guard let result else { return self.registerHotkeys() }
            let binding = HotkeyBinding(hotkey: result.hotkey, path: path, count: result.count, speed: result.speed)
            var list = self.bindings
            if let index, list.indices.contains(index) { list[index] = binding } else { list.append(binding) }
            self.setBindings(list)
            self.notify("已绑定 \(result.hotkey.display) → 「\(binding.name)」", color: .systemGreen, beep: false)
        }
    }

    @objc private func showHotkeys() {
        if hotkeysWindow == nil {
            let controller = HotkeysWindowController(bindings: { [weak self] in self?.bindings ?? [] })
            controller.onAdd = { [weak self] in self?.addBindingFromFile() }
            controller.onEdit = { [weak self] index in
                guard let self, let parent = self.hotkeysWindow?.window else { return }
                self.editBinding(at: index, path: self.bindings[index].path, on: parent)
            }
            controller.onDelete = { [weak self] index in
                guard let self else { return }
                var list = self.bindings
                list.remove(at: index)
                self.setBindings(list)
            }
            controller.onOpen = { [weak self] index in
                guard let self else { return }
                self.openRecording(self.bindings[index].url)
            }
            hotkeysWindow = controller
        }
        hotkeysWindow?.reload()
        hotkeysWindow?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func addBindingFromFile() {
        guard let parent = hotkeysWindow?.window, parent.attachedSheet == nil else { return }
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.title = "选择要绑定快捷键的录制"
        panel.directoryURL = recordingsDir
        panel.allowedContentTypes = [Recordings.contentType]
        panel.beginSheetModal(for: parent) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let binding = HotkeyBinding(hotkey: Hotkey(key: 0, modifiers: 0), path: url.path, count: 1, speed: 1)
            do {
                _ = try binding.loadSteps()
            } catch {
                let alert = NSAlert()
                alert.messageText = (error as? MessageError)?.message ?? "\(error)"
                return alert.beginSheetModal(for: parent)
            }
            // The open panel's sheet is still closing; start the editor sheet after it.
            DispatchQueue.main.async {
                self.editBinding(at: self.bindings.firstIndex { $0.path == url.path }, path: url.path, on: parent)
            }
        }
    }

    private var missingBindings: Int { bindings.filter { !$0.fileExists }.count }

    // MARK: Files

    @objc private func saveRecording() { saveRecording(then: nil) }

    private func saveRecording(then done: (() -> Void)?) {
        guard var recording = current, !isRecording else { return }
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.title = "保存录制"
        panel.directoryURL = recording.url?.deletingLastPathComponent() ?? recordingsDir
        panel.nameFieldStringValue = "\(recording.name ?? "录制 \(Self.timestamp())").\(Recordings.fileExtension)"
        panel.allowedContentTypes = [Recordings.contentType]
        showWindow()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try RecordingFormat.chinese(recording.steps).write(to: url, atomically: true, encoding: .utf8)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                recording.name = url.deletingPathExtension().lastPathComponent
                recording.url = url
                recording.saved = true
                self.current = recording
                self.showCurrent()
                self.refreshUI()
                self.hotkeysWindow?.reload()
                // The save panel's sheet is still closing; let it finish before another sheet.
                if let done { DispatchQueue.main.async(execute: done) }
            } catch {
                self.info("保存失败：\(error.localizedDescription)")
            }
        }
    }

    @objc private func chooseRecording() {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.title = "打开录制"
        panel.directoryURL = recordingsDir
        panel.allowedContentTypes = [Recordings.contentType]
        showWindow()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openRecording(url)
        }
    }

    /// Finder double-click / drag onto the Dock icon / 打开最近使用.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach(openRecording)
    }

    private func openRecording(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        guard !isRecording, playback == nil else { return info("请先停止录制或播放，再打开「\(name)」。") }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let steps = try RecordingFormat.parse(text)
            guard steps.contains(where: { !$0.isDelay }) else { return info("「\(name)」里没有任何操作。") }
            current = Recording(steps: steps, name: name, url: url, saved: true)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            showCurrent()
            refreshUI()
            showWindow()
        } catch let error as FormatError {
            info("「\(name)」\(error.message)")
        } catch {
            info("无法读取「\(name)」：\(error.localizedDescription)")
        }
    }

    @objc private func openRecordingsDir() {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(recordingsDir)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }

    // MARK: Tasks and advanced window

    /// Kept for Repeat's gesture triggers, but discouraged: Repeat's own player types keys twice.
    @objc private func addAsTask() {
        guard backendReady, !isRecording, playback == nil, current != nil else { return }
        let alert = NSAlert()
        alert.messageText = "推荐改用「绑定快捷键」"
        alert.informativeText = """
            Repeat 的任务由它自己播放，在本机上按键可能会重复输入（"hi" 变成 "h h ii"）。
            「绑定快捷键」由本 App 播放，没有这个问题。仍要添加为 Repeat 任务吗？
            """
        alert.addButton(withTitle: "绑定快捷键…")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "仍然添加为任务")
        showWindow()
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                DispatchQueue.main.async { self.bindCurrent() }
            } else if response == .alertThirdButtonReturn {
                DispatchQueue.main.async { self.addCurrentAsTask() }
            }
        }
    }

    private func addCurrentAsTask() {
        guard backendReady, !isRecording, playback == nil, let recording = current else { return }
        let name = recording.name ?? "录制 \(Self.timestamp())"
        let (steps, unsupported) = RecordingCleaner.forRepeat(recording.steps)
        guard unsupported.isEmpty else {
            let keys = Set(unsupported.map { step -> String in
                if case .keyPress(let k) = step { return RecordingFormat.keyName(k) }
                if case .keyRelease(let k) = step { return RecordingFormat.keyName(k) }
                return RecordingFormat.chineseLine(step)
            }).sorted().joined(separator: "、")
            let alert = NSAlert()
            alert.messageText = "Repeat 的任务不支持这些键"
            alert.informativeText = "\(keys)\n添加为任务时会忽略它们。"
            alert.addButton(withTitle: "忽略并添加")
            alert.addButton(withTitle: "取消")
            showWindow()
            alert.beginSheetModal(for: window) { [weak self] in
                if $0 == .alertFirstButtonReturn { self?.addTask(steps, named: name) }
            }
            return
        }
        addTask(steps, named: name)
    }

    private func addTask(_ steps: [Step], named name: String) {
        Recordings.load(steps) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result { return self.info(error.message) }
            Recordings.addCurrentAsTask(named: name) { taskName in
                guard let taskName else { return self.info("添加任务失败，请查看日志。") }
                self.advancedWebView?.reload()
                let alert = NSAlert()
                alert.messageText = "已添加到任务列表"
                alert.informativeText = """
                    任务名称：\(taskName)
                    可在「高级界面」的任务列表里运行它，或为它设置手势。
                    注意：任务由 Repeat 自己播放，在本机上按键可能会重复输入；含键盘操作的录制请用「绑定快捷键」。
                    """
                alert.addButton(withTitle: "打开高级界面")
                alert.addButton(withTitle: "好")
                alert.beginSheetModal(for: self.window) { if $0 == .alertFirstButtonReturn { self.showAdvanced() } }
            }
        }
    }

    @objc private func showAdvanced() {
        guard backendReady else { return info("后台尚未就绪，请稍候。") }
        if advancedWindow == nil {
            let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
            webView.uiDelegate = self
            webView.navigationDelegate = self
            let advanced = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
            advanced.title = "Repeat 高级界面"
            advanced.contentView = webView
            advanced.isReleasedWhenClosed = false
            advanced.setFrameAutosaveName("RepeatAdvancedWindow")
            if !advanced.setFrameUsingName("RepeatAdvancedWindow") { advanced.center() }
            advancedWindow = advanced
            advancedWebView = webView
        }
        advancedWebView?.load(URLRequest(url: baseURL))
        advancedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Window state

    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLog() { NSWorkspace.shared.open(logURL) }

    @objc private func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openInputMonitoringSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    @objc private func countStepped() { countField.integerValue = countStepper.integerValue }

    @objc private func countEdited() {
        countField.integerValue = max(1, min(999, countField.integerValue))
        countStepper.integerValue = countField.integerValue
    }

    /// Re-renders the current recording (title, summary, steps).
    private func showCurrent() {
        guard let recording = current else {
            recordingTitle.stringValue = "还没有录制"
            recordingSummary.stringValue = ""
            stepsView.string = """
                按 F9（或点击「录制」）开始录制，做完要重复的操作后再按一次 F9 停止。
                也可以点击「打开…」载入以前保存的录制。
                """
            stepsView.textColor = .secondaryLabelColor
            window.title = "Repeat"
            return
        }
        let items = RecordingFormat.timeline(recording.steps)
        let title = recording.name ?? "新录制"
        recordingTitle.stringValue = recording.saved ? title : "\(title)（未保存）"
        recordingSummary.stringValue = "\(items.count) 个操作 · 时长 \(RecordingFormat.seconds(RecordingFormat.duration(recording.steps))) 秒"
        stepsView.string = items.map { item in
            String(format: "%02d:%04.1f    ", item.time / 60000, Double(item.time % 60000) / 1000) + item.text
        }.joined(separator: "\n")
        stepsView.textColor = .labelColor
        window.title = "Repeat — \(title)"
    }

    private func refreshUI() {
        let status: String
        var color = NSColor.labelColor
        if !hasPermissions {
            status = "需要辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能"
            color = .systemOrange
        } else if let notice, notice.until > Date() {
            status = notice.text
            color = notice.color
        } else if !backendReady {
            status = "正在启动…"
            color = .secondaryLabelColor
        } else if isRecording {
            status = "● 正在录制…  按 F9 停止"
            color = .systemRed
        } else if let run = playback {
            let name = run.name.map { "「\($0)」" } ?? ""
            status = run.total > 1 ? "▶ 正在播放\(name)（第 \(run.iteration)/\(run.total) 次）…  按 Esc 中止" : "▶ 正在播放\(name)…  按 Esc 中止"
            color = .controlAccentColor
        } else if isRunningTask || isReplaying {
            status = "▶ 正在运行任务…  按 Esc 中止"
            color = .controlAccentColor
        } else if missingBindings > 0 {
            status = "就绪 · \(missingBindings) 个快捷键的录制文件不存在，见「快捷键」窗口"
            color = .systemOrange
        } else if hasPermissions && !keyRecorder.isAvailable {
            status = "就绪 · 右 Control、Fn、CapsLock 需要「输入监控」权限才能录到"
            color = .systemOrange
        } else {
            status = "就绪"
        }
        statusLabel.stringValue = status
        statusLabel.textColor = color

        recordButton.title = isRecording ? "停止录制" : "录制"
        recordButton.image = NSImage(systemSymbolName: isRecording ? "stop.fill" : "record.circle", accessibilityDescription: nil)
        recordButton.isEnabled = backendReady && playback == nil
        playButton.title = playback != nil ? "停止播放" : "播放"
        playButton.image = NSImage(systemSymbolName: playback != nil ? "stop.fill" : "play.fill", accessibilityDescription: nil)
        playButton.isEnabled = playback != nil || (hasPermissions && !isRecording && current != nil)
        saveButton.isEnabled = current != nil && !isRecording
        bindButton.isEnabled = current != nil && !isRecording && !editingHotkey

        recordItem.title = recordButton.title
        recordItem.isEnabled = recordButton.isEnabled
        playItem.title = playButton.title
        playItem.isEnabled = playButton.isEnabled

        let symbol = isRecording ? "record.circle.fill" : (playback != nil || isRunningTask || isReplaying) ? "play.circle.fill" : "record.circle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Repeat")
        image?.isTemplate = !isRecording
        statusItem.button?.image = isRecording ? image?.withSymbolConfiguration(.init(paletteColors: [.systemRed])) : image
    }

    // MARK: UI construction

    private func makeButton(_ title: String, symbol: String? = nil, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        return button
    }

    private func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size)
        if secondary { field.textColor = .secondaryLabelColor }
        return field
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func buildWindow() {
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.lineBreakMode = .byTruncatingTail

        recordButton = makeButton("录制", symbol: "record.circle", action: #selector(toggleRecord))
        playButton = makeButton("播放", symbol: "play.fill", action: #selector(togglePlay))
        for button in [recordButton!, playButton!] {
            button.controlSize = .large
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 116).isActive = true
        }

        let defaults = UserDefaults.standard
        let count = max(1, min(999, defaults.integer(forKey: "playCount")))
        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 999
        formatter.allowsFloats = false
        countField.formatter = formatter
        countField.integerValue = count
        countField.alignment = .right
        countField.target = self
        countField.action = #selector(countEdited)
        countField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        countStepper.minValue = 1
        countStepper.maxValue = 999
        countStepper.integerValue = count
        countStepper.target = self
        countStepper.action = #selector(countStepped)

        let savedSpeed = defaults.double(forKey: "playSpeed")
        for (title, speed) in playbackSpeeds {
            speedPopup.addItem(withTitle: title)
            speedPopup.lastItem?.representedObject = speed
            if speed == (savedSpeed == 0 ? 1 : savedSpeed) { speedPopup.select(speedPopup.lastItem) }
        }

        let controls = NSStackView(views: [recordButton, playButton, spacer(),
                                           label("次数"), countField, countStepper, label("速度"), speedPopup])
        controls.spacing = 8

        recordingTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        recordingTitle.lineBreakMode = .byTruncatingMiddle
        recordingSummary.font = .systemFont(ofSize: 12)
        recordingSummary.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [recordingTitle, recordingSummary])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        saveButton = makeButton("保存…", action: #selector(saveRecording as () -> Void))
        bindButton = makeButton("绑定快捷键…", symbol: "command", action: #selector(bindCurrent))
        let header = NSStackView(views: [titles, spacer(), makeButton("打开…", action: #selector(chooseRecording)), saveButton, bindButton])

        let scroll = NSTextView.scrollableTextView()
        stepsView = (scroll.documentView as! NSTextView)
        stepsView.isEditable = false
        stepsView.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        stepsView.textContainerInset = NSSize(width: 8, height: 8)
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        let footer = NSStackView(views: [label("F9 录制 / 停止 · F10 播放 / 停止 · Esc 中止", size: 12, secondary: true),
                                         spacer(), makeButton("快捷键…", action: #selector(showHotkeys)),
                                         makeButton("高级界面…", action: #selector(showAdvanced))])

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [statusLabel, controls, separator, header, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [controls, header, footer, statusLabel] as [NSView] {
            row.setContentHuggingPriority(.defaultHigh, for: .vertical)
        }
        for row in [statusLabel, controls, separator, header, scroll, footer] as [NSView] {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Repeat"
        window.contentView = content
        window.contentMinSize = NSSize(width: 580, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("RepeatSimpleWindow")
        if !window.setFrameUsingName("RepeatSimpleWindow") { window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        recordItem = menu.addItem(withTitle: "录制", action: #selector(toggleRecord), keyEquivalent: "")
        playItem = menu.addItem(withTitle: "播放", action: #selector(togglePlay), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "打开录制…", action: #selector(chooseRecording), keyEquivalent: "")
        menu.addItem(withTitle: "保存录制…", action: #selector(saveRecording as () -> Void), keyEquivalent: "")
        menu.addItem(withTitle: "快捷键…", action: #selector(showHotkeys), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "显示主窗口", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(withTitle: "高级界面…", action: #selector(showAdvanced), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐私与安全性设置…", action: #selector(openPrivacySettings), keyEquivalent: "")
        menu.addItem(withTitle: "输入监控设置…", action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        menu.addItem(withTitle: "重启后台", action: #selector(restartBackend), keyEquivalent: "")
        menu.addItem(withTitle: "查看日志", action: #selector(openLog), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 Repeat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        statusItem.menu = menu
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 Repeat", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Repeat", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Repeat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "", action: nil, keyEquivalent: "").submenu = appMenu

        let file = NSMenu(title: "文件")
        file.addItem(withTitle: "打开录制…", action: #selector(chooseRecording), keyEquivalent: "o").target = self
        // Title must match AppKit's Recent menu convention for NSDocumentController to populate it.
        let recent = NSMenu(title: "Open Recent")
        recent.perform(NSSelectorFromString("_setMenuName:"), with: "NSRecentDocumentsMenu")
        recent.addItem(withTitle: "清除菜单", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        file.addItem(withTitle: "打开最近使用", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(withTitle: "保存录制…", action: #selector(saveRecording as () -> Void), keyEquivalent: "s").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "为当前录制绑定快捷键…", action: #selector(bindCurrent), keyEquivalent: "b").target = self
        file.addItem(withTitle: "快捷键…", action: #selector(showHotkeys), keyEquivalent: "k").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "在 Finder 中显示录制文件夹", action: #selector(openRecordingsDir), keyEquivalent: "").target = self
        file.addItem(.separator())
        file.addItem(withTitle: "添加为 Repeat 任务（不推荐）…", action: #selector(addAsTask), keyEquivalent: "").target = self
        main.addItem(withTitle: "文件", action: nil, keyEquivalent: "").submenu = file

        // Standard edit actions for text fields and the advanced window's code editor.
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = edit

        let control = NSMenu(title: "控制")
        control.addItem(withTitle: "录制 / 停止录制", action: #selector(toggleRecord), keyEquivalent: "r").target = self
        control.addItem(withTitle: "播放 / 停止播放", action: #selector(togglePlay), keyEquivalent: "p").target = self
        main.addItem(withTitle: "控制", action: nil, keyEquivalent: "").submenu = control

        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(.separator())
        win.addItem(withTitle: "主窗口", action: #selector(showWindow), keyEquivalent: "0").target = self
        win.addItem(withTitle: "快捷键", action: #selector(showHotkeys), keyEquivalent: "").target = self
        win.addItem(withTitle: "高级界面", action: #selector(showAdvanced), keyEquivalent: "").target = self
        main.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    // MARK: WKUIDelegate — the advanced web UI relies on alert()/confirm()/prompt().

    private func sheetWindow(for webView: WKWebView) -> NSWindow { webView.window ?? window }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: sheetWindow(for: webView)) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: sheetWindow(for: webView)) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: sheetWindow(for: webView)) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // Links that open new windows (e.g. GitHub/wiki) go to the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, let host = url.host else { return decisionHandler(.allow) }
        if host == "127.0.0.1" || host == "localhost" { return decisionHandler(.allow) }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }
}

// MARK: - Hotkey UI

/// Records a shortcut: click (or focus) it, then press the keys. Shows held modifiers live.
final class HotkeyField: NSView {
    var hotkey: Hotkey? { didSet { refresh() } }
    var onChange: ((Hotkey) -> Void)?
    private let label = NSTextField(labelWithString: "")
    private var listening = false
    private var liveModifiers: UInt = 0

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        focusRingType = .exterior
        label.alignment = .center
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            widthAnchor.constraint(equalToConstant: 200),
            heightAnchor.constraint(equalToConstant: 32),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        listening = true
        refresh()
        return true
    }

    override func resignFirstResponder() -> Bool {
        listening = false
        liveModifiers = 0
        refresh()
        return true
    }

    /// Key events routed here by HotkeyPanel while this field has focus. Esc alone stops listening.
    func capture(_ event: NSEvent) {
        let modifiers = UInt(event.modifierFlags.rawValue) & Hotkey.modifierMask
        if event.type == .flagsChanged {
            liveModifiers = modifiers
            return refresh()
        }
        guard event.type == .keyDown, !event.isARepeat else { return }
        if event.keyCode == HotKey.escape && modifiers == 0 {
            window?.makeFirstResponder(nil)
            return
        }
        let hotkey = Hotkey(key: event.keyCode, modifiers: modifiers)
        self.hotkey = hotkey
        if hotkey.problem == nil { window?.makeFirstResponder(nil) }
        onChange?(hotkey)
    }

    private func refresh() {
        if listening && liveModifiers != 0 {
            label.stringValue = Hotkey.symbols(liveModifiers) + "…"
        } else if let hotkey, !(listening && hotkey.problem != nil) {
            label.stringValue = hotkey.display
        } else {
            label.stringValue = listening ? "请按下快捷键…" : "点击后按下快捷键"
        }
        label.textColor = hotkey == nil || listening ? .secondaryLabelColor : .labelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = (listening ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

/// Sends every key press to a focused HotkeyField, before menus and buttons see it (⌘S, Esc, ↩).
final class HotkeyPanel: NSPanel {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let field = firstResponder as? HotkeyField {
            field.capture(event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown || event.type == .flagsChanged, let field = firstResponder as? HotkeyField {
            return field.capture(event)
        }
        super.sendEvent(event)
    }
}

/// Sheet for choosing a binding's hotkey, play count and speed.
final class BindingEditor: NSObject {
    struct Result {
        var hotkey: Hotkey
        var count: Int
        var speed: Double
    }

    /// Returns why a hotkey can't be used, or nil.
    var validate: ((Hotkey) -> String?)?
    private let panel = HotkeyPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    private let field = HotkeyField()
    private let countField = NSTextField()
    private let speedPopup = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var parent: NSWindow?
    private var completion: ((Result?) -> Void)?

    init(name: String, hotkey: Hotkey?, count: Int, speed: Double) {
        super.init()
        field.hotkey = hotkey
        field.onChange = { [weak self] in self?.showProblem(self?.validate?($0)) }

        let formatter = NumberFormatter()
        formatter.minimum = 1
        formatter.maximum = 999
        formatter.allowsFloats = false
        countField.formatter = formatter
        countField.integerValue = count
        countField.alignment = .right
        countField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        for (title, value) in playbackSpeeds {
            speedPopup.addItem(withTitle: title)
            speedPopup.lastItem?.representedObject = value
            if value == speed { speedPopup.select(speedPopup.lastItem) }
        }

        let title = NSTextField(labelWithString: "为「\(name)」绑定快捷键")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        let hint = NSTextField(wrappingLabelWithString: "在任何应用里按下快捷键，就会播放这个录制文件（每次都读取文件的最新内容）。播放中按 Esc 中止。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "快捷键"), field],
            [NSTextField(labelWithString: "次数"), countField],
            [NSTextField(labelWithString: "速度"), speedPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.row(at: 0).yPlacement = .center
        grid.row(at: 0).rowAlignment = .none

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "绑定", target: self, action: #selector(confirm))
        ok.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [title, hint, grid, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        for view in [title, hint, errorLabel, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 400).isActive = true
        panel.contentView = stack
    }

    func begin(on parent: NSWindow, completion: @escaping (Result?) -> Void) {
        self.parent = parent
        self.completion = completion
        // The sheet's handler keeps this editor alive until it closes.
        parent.beginSheet(panel) { _ in _ = self }
        panel.makeFirstResponder(field)
    }

    private func showProblem(_ problem: String?) {
        errorLabel.stringValue = problem ?? ""
        errorLabel.isHidden = problem == nil
    }

    @objc private func confirm() {
        guard let hotkey = field.hotkey else { return showProblem("请先点击「快捷键」框，按下要绑定的快捷键。") }
        if let problem = validate?(hotkey) { return showProblem(problem) }
        let count = max(1, min(999, countField.integerValue))
        finish(Result(hotkey: hotkey, count: count, speed: speedPopup.selectedItem?.representedObject as? Double ?? 1))
    }

    @objc private func cancel() { finish(nil) }

    private func finish(_ result: Result?) {
        parent?.endSheet(panel)
        completion?(result)
        completion = nil
    }
}

/// Lists all bindings: hotkey, recording, count, speed. Missing files are shown in red.
final class HotkeysWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let window: NSWindow
    var onAdd: (() -> Void)?
    var onEdit: ((Int) -> Void)?
    var onDelete: ((Int) -> Void)?
    var onOpen: ((Int) -> Void)?
    private let bindings: () -> [HotkeyBinding]
    private let table = NSTableView()
    private var rowButtons: [NSButton] = []

    init(bindings: @escaping () -> [HotkeyBinding]) {
        self.bindings = bindings
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "快捷键"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 480, height: 260)

        for (id, title, width) in [("hotkey", "快捷键", 100.0), ("name", "录制", 250.0), ("count", "次数", 50.0), ("speed", "速度", 50.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            if id == "name" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(edit)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "添加…", target: self, action: #selector(add))
        let edit = NSButton(title: "修改…", target: self, action: #selector(edit))
        let delete = NSButton(title: "删除", target: self, action: #selector(delete))
        let open = NSButton(title: "在主窗口打开", target: self, action: #selector(open))
        rowButtons = [edit, delete, open]
        let hint = NSTextField(wrappingLabelWithString: "在任何应用里按下快捷键即可播放对应的录制文件，播放中按 Esc 中止。录制时按下的快捷键不会被录进去。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor
        let buttons = NSStackView(views: [add, edit, delete, NSView(), open])

        let stack = NSStackView(views: [scroll, buttons, hint])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [scroll, buttons, hint] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        window.setFrameAutosaveName("RepeatHotkeysWindow")
        if !window.setFrameUsingName("RepeatHotkeysWindow") { window.center() }
        updateButtons()
    }

    func reload() {
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        let valid = bindings().indices.contains(table.selectedRow)
        rowButtons.forEach { $0.isEnabled = valid }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { bindings().count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let list = bindings()
        guard let column = tableColumn, list.indices.contains(row) else { return nil }
        let binding = list[row]
        let text: String
        switch column.identifier.rawValue {
        case "hotkey": text = binding.hotkey.display
        case "name": text = binding.fileExists ? binding.name : "\(binding.name)（文件不存在）"
        case "count": text = "\(binding.count)"
        default: text = playbackSpeeds.first { $0.speed == binding.speed }?.title ?? "\(binding.speed)×"
        }
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingMiddle
        field.toolTip = column.identifier.rawValue == "name" ? binding.path : nil
        if column.identifier.rawValue == "name" && !binding.fileExists { field.textColor = .systemRed }
        if column.identifier.rawValue == "hotkey" { field.font = .systemFont(ofSize: 13, weight: .medium) }
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    private var selected: Int? { bindings().indices.contains(table.selectedRow) ? table.selectedRow : nil }

    @objc private func add() { onAdd?() }
    @objc private func edit() { if let row = selected { onEdit?(row) } }
    @objc private func delete() { if let row = selected { onDelete?(row) } }
    @objc private func open() { if let row = selected { onOpen?(row) } }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
