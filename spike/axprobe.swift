// axprobe.swift
// Phase 0 spike for the Handy fork: what the macOS Accessibility API can do to
// the focused text field of a running app.
//
//   axprobe mktext <out-dir> [wordlist] [words]     write out-dir/test.txt and test.html
//   axprobe run <pid> <label> <out-dir> [--paste <file>] [--focus <description prefix>]
//              [--close <window title part>] [--sheet yes|no] [--enhance yes|no]
//   axprobe selftest
//
// Read-only unless the field starts with the AXPROBE header that mktext writes.
// Every keystroke is preceded by a check that the app is frontmost and its
// focused field still shows exactly the content this probe expects there.

import AppKit
import ApplicationServices
import Foundation

let HEADER_PREFIX = "AXPROBE "
let EMOJI = "\u{1F600}"
let TARGET = "jumps over the lazy dog"
let TOKEN = "axprobe-OK"
let QUESTION = "?"

// MARK: - Small helpers

func pause(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }

func die(_ message: String, _ code: Int32 = 2) -> Never {
    FileHandle.standardError.write(("axprobe: " + message + "\n").data(using: .utf8)!)
    exit(code)
}

func show(_ s: String, _ max: Int = 48) -> String {
    s.count > max ? String(s.prefix(max)) + "…" : s
}

func describeCount(_ n: Int?) -> String {
    n.map { String($0) } ?? "unsupported"
}

func describeRange(_ r: CFRange?) -> String {
    guard let r else { return "unsupported" }
    return "location=\(r.location) length=\(r.length)"
}

func describeText(_ s: String?) -> String {
    s.map { show($0, 64) } ?? "unsupported"
}

func axErrorName(_ e: AXError) -> String {
    switch e {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled (Accessibility not granted to this process)"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "axError(\(e.rawValue))"
    }
}

// MARK: - UTF-16 offsets (the unit the Accessibility API counts)

func u16Count(_ s: String) -> Int { s.utf16.count }

func u16Sub(_ s: String, _ from: Int, _ to: Int) -> String? {
    let units = s.utf16
    guard from >= 0, to >= from, to <= units.count else { return nil }
    guard let a = String.Index(units.index(units.startIndex, offsetBy: from), within: s),
          let b = String.Index(units.index(units.startIndex, offsetBy: to), within: s) else { return nil }
    return String(s[a..<b])
}

func u16Offset(of needle: String, in s: String) -> Int? {
    guard let r = s.range(of: needle) else { return nil }
    return s[..<r.lowerBound].utf16.count
}

func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

/// How the text read back from a field compares with the text put into it.
func fidelity(_ got: String, _ want: String) -> String {
    let g = normalize(got), w = normalize(want)
    if g == w { return "exact match, \(w.count) characters" }
    if g.hasPrefix(w) { return "field holds the test text plus \(g.count - w.count) characters" }
    let ga = Array(g.utf16), wa = Array(w.utf16)
    var n = 0
    while n < ga.count, n < wa.count, ga[n] == wa[n] { n += 1 }
    return "DIFFERS at UTF-16 offset \(n) (test text \(wa.count) units, field \(ga.count) units)"
}

// MARK: - Accessibility wrappers

extension AXError: Error {}

extension Result where Failure == AXError {
    /// The success value, or nil.
    var value: Success? { try? get() }
}

func copyAttr(_ el: AXUIElement, _ name: String) -> Result<AnyObject?, AXError> {
    var value: CFTypeRef?
    let e = AXUIElementCopyAttributeValue(el, name as CFString, &value)
    return e == .success ? .success(value) : .failure(e)
}

func stringAttr(_ el: AXUIElement, _ name: String) -> Result<String, AXError> {
    copyAttr(el, name).flatMap { (v: AnyObject?) -> Result<String, AXError> in
        if let s = v as? String { return .success(s) }
        if let a = v as? NSAttributedString { return .success(a.string) }
        return .failure(.attributeUnsupported)
    }
}

func intAttr(_ el: AXUIElement, _ name: String) -> Result<Int, AXError> {
    copyAttr(el, name).flatMap { (v: AnyObject?) -> Result<Int, AXError> in
        guard let n = v as? NSNumber else { return .failure(.attributeUnsupported) }
        return .success(n.intValue)
    }
}

func boolAttr(_ el: AXUIElement, _ name: String) -> Result<Bool, AXError> {
    copyAttr(el, name).flatMap { (v: AnyObject?) -> Result<Bool, AXError> in
        guard let n = v as? NSNumber else { return .failure(.attributeUnsupported) }
        return .success(n.boolValue)
    }
}

func rangeAttr(_ el: AXUIElement, _ name: String) -> Result<CFRange, AXError> {
    copyAttr(el, name).flatMap { (v: AnyObject?) -> Result<CFRange, AXError> in
        // A conditional downcast to a CF class type does not check anything; compare type IDs.
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return .failure(.attributeUnsupported) }
        let ax = unsafeDowncast(v, to: AXValue.self)
        let type = AXValueGetType(ax)
        // kAXValueTypeCFRange is 4 in the SDK; CGPoint is 1.
        guard type == .cfRange else { return .failure(.attributeUnsupported) }
        var words = [Int64](repeating: 0, count: 2)
        let ok = words.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return AXValueGetValue(ax, type, base)
        }
        guard ok else { return .failure(.failure) }
        return .success(CFRange(location: Int(words[0]), length: Int(words[1])))
    }
}

func rangeType(_ el: AXUIElement, _ name: String) -> String {
    guard case .success(let v?) = copyAttr(el, name), CFGetTypeID(v) == AXValueGetTypeID() else { return "n/a" }
    let type = AXValueGetType(unsafeDowncast(v, to: AXValue.self))
    return type == .cfRange ? "4 (CFRange)" : String(type.rawValue)
}

func textValue(_ el: AXUIElement) -> Result<String, AXError> { stringAttr(el, kAXValueAttribute) }

func settable(_ el: AXUIElement, _ name: String) -> String {
    var s = DarwinBoolean(false)
    let e = AXUIElementIsAttributeSettable(el, name as CFString, &s)
    return e == .success ? (s.boolValue ? "yes" : "no") : axErrorName(e)
}

func setSelection(_ el: AXUIElement, _ location: Int, _ length: Int) -> AXError {
    var r = CFRange(location: location, length: length)
    guard let v = AXValueCreate(.cfRange, &r) else { return .failure }
    return AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
}

func stringForRange(_ el: AXUIElement, _ location: Int, _ length: Int) -> Result<String, AXError> {
    var r = CFRange(location: location, length: length)
    guard let parameter = AXValueCreate(.cfRange, &r) else { return .failure(.failure) }
    var value: CFTypeRef?
    let e = AXUIElementCopyParameterizedAttributeValue(el, "AXStringForRange" as CFString, parameter, &value)
    guard e == .success else { return .failure(e) }
    guard let s = value as? String else { return .failure(.attributeUnsupported) }
    return .success(s)
}

func role(_ el: AXUIElement) -> String { stringAttr(el, kAXRoleAttribute).value ?? QUESTION }

/// The whole text through AXStringForRange, for fields whose AXValue is cut short.
func pagedText(_ el: AXUIElement, pageSize: Int) -> (text: String, calls: Int)? {
    var parts: [String] = []
    var offset = 0
    var calls = 0
    while calls < 5_000 {
        switch stringForRange(el, offset, pageSize) {
        case .success(let s):
            calls += 1
            let n = u16Count(s)
            guard n > 0 else { return (parts.joined(), calls) }
            parts.append(s)
            offset += n
        case .failure:
            return parts.isEmpty ? nil : (parts.joined(), calls)
        }
    }
    return (parts.joined(), calls)
}

/// Set a selection, read it back, and say whether the app applied it.
@discardableResult
func trySelection(_ el: AXUIElement, _ location: Int, _ length: Int, expected: String?, tag: String) -> Bool {
    let e = setSelection(el, location, length)
    pause(0.15)
    let back = rangeAttr(el, kAXSelectedTextRangeAttribute).value
    let picked = stringAttr(el, kAXSelectedTextAttribute).value
    let rangeOk = back?.location == location && back?.length == length
    let textOk = picked.map { $0 == expected } ?? true
    print("[\(tag)] set \(describeRange(CFRange(location: location, length: length))) -> \(axErrorName(e)); read back \(describeRange(back)); selected text \(describeText(picked))")
    return e == .success && rangeOk && textOk
}

/// The focused element once its value can be read. Electron builds its tree on first use
/// and hands out handles that die while it does, so this waits and re-resolves.
func liveFocusedElement(_ app: AXUIElement, seconds: Double) -> (AXUIElement?, String) {
    let start = Date()
    let deadline = start.addingTimeInterval(seconds)
    var why = "not tried"
    var manual = false
    while true {
        switch copyAttr(app, kAXFocusedUIElementAttribute) {
        case .success(let value):
            if let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let el = unsafeDowncast(value, to: AXUIElement.self)
                let r = role(el)
                switch textValue(el) {
                case .success: return (el, r)
                case .failure(let e): why = "role \(r), value read failed: \(axErrorName(e))"
                }
            } else {
                why = "no focused element"
            }
        case .failure(let e):
            why = axErrorName(e)
        }
        if !manual, Date().timeIntervalSince(start) > 3 {
            manual = true
            let e = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            print("[focus] unresolved after 3 s; set AXManualAccessibility=true: \(axErrorName(e))")
        }
        if Date() >= deadline { return (nil, why) }
        pause(0.3)
    }
}

func focusedTextArea(_ app: AXUIElement, seconds: Double) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(seconds)
    while true {
        let left = Date().timeIntervalSince(deadline)
        if let el = liveFocusedElement(app, seconds: max(0, left)).0, role(el) == "AXTextArea" { return el }
        if Date() >= deadline { return nil }
        pause(0.2)
    }
}

/// Breadth-first search through the element tree for the first match.
func findElement(_ root: AXUIElement, tag: String, deadline: Date, quiet: Bool = false,
                 matching: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue: [AXUIElement] = [root]
    var seen = 0
    while !queue.isEmpty, Date() < deadline {
        let el = queue.removeFirst()
        seen += 1
        if matching(el) {
            if !quiet { print("[\(tag)] matched after visiting \(seen) elements") }
            return el
        }
        if case .success(let children?) = copyAttr(el, kAXChildrenAttribute), let items = children as? [AnyObject] {
            for item in items where CFGetTypeID(item) == AXUIElementGetTypeID() {
                queue.append(unsafeDowncast(item, to: AXUIElement.self))
            }
        }
    }
    if !quiet { print("[\(tag)] no match among \(seen) elements") }
    return nil
}

/// A text area whose description starts with the prefix. An empty prefix takes any text area.
func findTextArea(_ root: AXUIElement, descriptionPrefix: String, deadline: Date) -> AXUIElement? {
    findElement(root, tag: "focus", deadline: deadline) { el in
        guard role(el) == "AXTextArea" else { return false }
        return descriptionPrefix.isEmpty
            || stringAttr(el, kAXDescriptionAttribute).value?.hasPrefix(descriptionPrefix) == true
    }
}

/// The text area in any of the app's windows that holds the test text, with that window
/// brought forward and the text area focused. For apps whose file the caller opened.
func findHeaderArea(_ app: AXUIElement) -> AXUIElement? {
    // WebKit builds its tree on the first AX query, so the page's text area can take seconds to appear.
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
        if case .success(let value?) = copyAttr(app, kAXWindowsAttribute), let windows = value as? [AnyObject] {
            for item in windows where CFGetTypeID(item) == AXUIElementGetTypeID() {
                let window = unsafeDowncast(item, to: AXUIElement.self)
                guard let area = findElement(window, tag: "focus", deadline: Date().addingTimeInterval(3), quiet: true, matching: { el in
                    role(el) == "AXTextArea" && (textValue(el).value ?? "").hasPrefix(HEADER_PREFIX)
                }) else { continue }
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                pause(0.4)
                if let now = focusedTextArea(app, seconds: 3), CFEqual(now, area) {
                    print("[focus] focus moved to the window holding the test text")
                    return now
                }
            }
        }
        pause(0.5)
    }
    print("[focus] no window holds the test text in a text area")
    return nil
}

/// Close the windows the caller opened. Each must be frontmost and titled as expected.
/// TextEdit asks whether to save; the button titled Delete answers that.
func closeFrontmostWindows(_ app: AXUIElement, pid: pid_t, titleContains: String, hasSaveSheet: Bool) {
    var closed = 0
    for _ in 0..<10 {
        guard frontmostPid() == pid else { break }
        guard case .success(let value?) = copyAttr(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { break }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        let title = stringAttr(window, kAXTitleAttribute).value ?? QUESTION
        guard title.contains(titleContains) else {
            print("[close] stopping at a window titled \(show(title))")
            break
        }
        postKey(13, .maskCommand)
        pause(0.6)
        if hasSaveSheet {
            // An unmodified document closes at once; a modified one stays open behind a save prompt.
            guard case .success(let again?) = copyAttr(app, kAXFocusedWindowAttribute),
                  CFGetTypeID(again) == AXUIElementGetTypeID() else { break }
            let still = unsafeDowncast(again, to: AXUIElement.self)
            guard CFEqual(still, window) else {
                closed += 1
                continue
            }
            let button = findElement(still, tag: "close", deadline: Date().addingTimeInterval(5)) { el in
                role(el) == "AXButton" && stringAttr(el, kAXTitleAttribute).value == "Delete"
            }
            guard let button else {
                print("[close] save prompt left on screen: choose Delete")
                break
            }
            print("[close] pressed Delete in the save prompt: \(axErrorName(AXUIElementPerformAction(button, kAXPressAction as CFString)))")
            pause(0.4)
        }
        closed += 1
    }
    print("[close] closed \(closed) window(s) titled \(titleContains)")
}

/// Poll until the field's length stops changing (paste in progress, page loading).
func waitForStableLength(_ el: AXUIElement, minimum: Int, seconds: Double) -> Int {
    var last = -1
    var stable = 0
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        let n = intAttr(el, kAXNumberOfCharactersAttribute).value ?? (textValue(el).value.map { u16Count($0) } ?? -1)
        if n >= minimum, n == last {
            stable += 1
            if stable >= 5 { break }
        } else {
            stable = 0
        }
        last = n
        pause(0.1)
    }
    return last
}

struct State {
    var value = ""
    var count: Int?
    var range: CFRange?
    var selectedText: String?
}

func snapshot(_ el: AXUIElement) -> State {
    var s = State()
    s.value = textValue(el).value ?? ""
    s.count = intAttr(el, kAXNumberOfCharactersAttribute).value
    s.range = rangeAttr(el, kAXSelectedTextRangeAttribute).value
    s.selectedText = stringAttr(el, kAXSelectedTextAttribute).value
    return s
}

func describe(_ el: AXUIElement) {
    let textAttributes = [("role", kAXRoleAttribute), ("subrole", kAXSubroleAttribute),
                          ("identifier", kAXIdentifierAttribute), ("title", kAXTitleAttribute),
                          ("description", kAXDescriptionAttribute), ("help", kAXHelpAttribute)]
    for (label, name) in textAttributes {
        switch stringAttr(el, name) {
        case .success(let s): print("  \(label): \(show(s))")
        case .failure(let e): print("  \(label): \(axErrorName(e))")
        }
    }
    let flagAttributes = [("editable", kAXIsEditableAttribute), ("enabled", kAXEnabledAttribute),
                          ("focused", kAXFocusedAttribute)]
    for (label, name) in flagAttributes {
        switch boolAttr(el, name) {
        case .success(let b): print("  \(label): \(b)")
        case .failure(let e): print("  \(label): \(axErrorName(e))")
        }
    }
    for name in [kAXValueAttribute, kAXSelectedTextRangeAttribute, kAXFocusedAttribute] {
        print("  settable: \(name) = \(settable(el, name))")
    }
    print("  AXValueType of AXSelectedTextRange: \(rangeType(el, kAXSelectedTextRangeAttribute))")
}

// MARK: - Keyboard

func postKey(_ keycode: CGKeyCode, _ flags: CGEventFlags = []) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: down) else {
            die("could not create a key event")
        }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}

/// The mechanism enigo uses on macOS: key events that carry a Unicode string.
func typeText(_ text: String) {
    let units = Array(text.utf16)
    var start = 0
    while start < units.count {
        var end = min(start + 20, units.count)
        // A chunk must not split a surrogate pair.
        if end < units.count, units[end - 1] >= 0xD800, units[end - 1] <= 0xDBFF { end -= 1 }
        let chunk = Array(units[start..<end])
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else {
                die("could not create a key event")
            }
            chunk.withUnsafeBufferPointer { buffer in
                e.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: buffer.baseAddress)
            }
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
        start = end
        pause(0.02)
    }
}

// MARK: - App activation

func frontmostPid() -> pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

@discardableResult
func activate(_ app: AXUIElement, _ pid: pid_t) -> Bool {
    if frontmostPid() != pid {
        AXUIElementSetAttributeValue(app, "AXFrontmost" as CFString, kCFBooleanTrue)
        pause(0.4)
        if frontmostPid() != pid, let running = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                running.activate()
            } else {
                running.activate(options: [.activateIgnoringOtherApps])
            }
            pause(0.4)
        }
    }
    return frontmostPid() == pid
}

// MARK: - Modes

func makeTestFiles(_ outDir: String, _ wordlist: String, _ wanted: Int) {
    let header = HEADER_PREFIX + "axiomatic " + EMOJI + " brown fox " + TARGET + "\n"
    var lines: [String] = []
    var line: [String] = []
    var n = 0
    if let words = try? String(contentsOfFile: wordlist, encoding: .utf8) {
        for word in words.split(separator: "\n") {
            if n >= wanted { break }
            line.append(String(word))
            n += 1
            if line.count == 12 {
                lines.append(line.joined(separator: " "))
                line = []
            }
        }
    }
    if !line.isEmpty { lines.append(line.joined(separator: " ")) }
    guard n == wanted else { die("could not read \(wanted) words from \(wordlist) (got \(n))") }
    let text = header + lines.joined(separator: "\n") + "\n"
    do {
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        try text.write(toFile: outDir + "/test.txt", atomically: true, encoding: .utf8)
        // In a <textarea>, the parser drops the first newline after the start tag.
        let escaped = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let html = "<!doctype html><html><head><meta charset=\"utf-8\"><title>axprobe</title></head>"
            + "<body style=\"margin:0\"><textarea id=\"t\" autofocus "
            + "style=\"width:98vw;height:92vh;font:13px monospace\">\n" + escaped + "</textarea></body></html>"
        try html.write(toFile: outDir + "/test.html", atomically: true, encoding: .utf8)
        print("[mktext] \(outDir)/test.txt: \(u16Count(text)) UTF-16 units, \(n) dictionary words after the header")
    } catch {
        die("could not write the test files: \(error)")
    }
}

func run(_ pid: pid_t, _ label: String, _ outDir: String, pasteFile: String?, focus: String?,
         closeTitle: String?, closeHasSheet: Bool, enhance: Bool, findHeader: Bool) {
    guard AXIsProcessTrusted() else {
        die("Accessibility is not granted to the process that runs this probe (AXIsProcessTrusted is false)")
    }
    print("[trust] AXIsProcessTrusted=true canPostEvents=\(CGPreflightPostEventAccess())")
    let app = AXUIElementCreateApplication(pid)
    let want = normalize((try? String(contentsOfFile: outDir + "/test.txt", encoding: .utf8)) ?? "")

    // Chrome only builds its tree for a screen reader; this is the signal VoiceOver sends.
    if enhance {
        let e = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        print("[focus] set AXEnhancedUserInterface=true: \(axErrorName(e))")
        pause(0.5)
    }

    // 0. What is focused while the app is in the background (for the record).
    let (before, why0) = liveFocusedElement(app, seconds: 4)
    let beforeRole = before.map { role($0) } ?? "none: \(why0)"
    print("[focus] before activation: role=\(beforeRole)")

    // 1. Chromium answers with defaults unless its window is key, so the app comes forward first.
    guard activate(app, pid) else { die("could not bring pid \(pid) to the front") }
    pause(0.3)

    // 2. The field: whatever is focused, else a text area the caller describes, else the
    // window that holds the test text.
    let (found, why) = liveFocusedElement(app, seconds: 12)
    guard let first = found else { die("no focused element with a readable value in pid \(pid): \(why)") }
    print("[focus] role=\(role(first))")
    describe(first)
    var target: AXUIElement? = role(first) == "AXTextArea" ? first : nil
    if target == nil, let prefix = focus {
        guard case .success(let value?) = copyAttr(app, kAXFocusedWindowAttribute),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            die("the focused role is \(role(first)) and the app has no focused window to search")
        }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        guard let area = findTextArea(window, descriptionPrefix: prefix, deadline: Date().addingTimeInterval(20)) else {
            die("the focused role is \(role(first)); no text area described \(prefix) in the focused window")
        }
        let e = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        pause(0.3)
        guard e == .success, let now = focusedTextArea(app, seconds: 3), CFEqual(now, area) else {
            die("could not move focus to the text area (AXFocused -> \(axErrorName(e)))")
        }
        target = now
        print("[focus] focus moved to the text area described \(prefix)")
    }
    if target == nil, findHeader {
        target = findHeaderArea(app)
    }
    guard let el = target else { die("the focused element is \(role(first)); nothing to test") }

    // 3. Fill the field. A field that already holds the test text (the caller opened a file
    // and the app loaded it) is left alone; otherwise paste, or wait for the file to load.
    var expected: String?
    if let file = pasteFile, !(textValue(el).value ?? "").hasPrefix(HEADER_PREFIX) {
        let empty = textValue(el).value == "" && (intAttr(el, kAXNumberOfCharactersAttribute).value ?? 0) == 0
        guard empty else { die("paste refused: the focused field is not empty") }
        guard CGPreflightPostEventAccess() else { die("cannot post events: CGPreflightPostEventAccess is false") }
        guard let area = focusedTextArea(app, seconds: 3), textValue(area).value == "" else {
            die("focus is not on an empty text area; stopping before any keystroke")
        }
        let fileText = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard frontmostPid() == pid else { die("the app is not frontmost; nothing was typed") }
        print("[paste] sending Cmd+V to pid \(pid)")
        postKey(9, .maskCommand)
        _ = waitForStableLength(area, minimum: 1000, seconds: 8)
        guard let pasted = textValue(area).value, pasted.hasPrefix(HEADER_PREFIX) else {
            let n = textValue(area).value.map { u16Count($0) }
            die("the paste did not produce the test text (field holds \(describeCount(n)) UTF-16 units)")
        }
        expected = pasted
        print("[paste] fidelity of the pasted text: \(fidelity(pasted, fileText))")
    } else {
        let n = waitForStableLength(el, minimum: 1000, seconds: 12)
        print("[load] number of characters in the focused field: \(describeCount(n))")
    }

    // 4. Read the text, timed.
    guard let area = focusedTextArea(app, seconds: 3) else { die("the focused element is no longer a text area") }
    var value = ""
    var reads: [Double] = []
    for _ in 0..<5 {
        let t = DispatchTime.now().uptimeNanoseconds
        switch textValue(area) {
        case .success(let s): value = s
        case .failure(let e): die("AXValue read failed: \(axErrorName(e))")
        }
        reads.append(Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6)
    }
    let n16 = u16Count(value)
    // Chromium shows only the start of a long field; `cap` is how much of it is visible.
    let truncated = n16 < u16Count(want)
    let cap = truncated ? n16 : nil
    let outPath = outDir + "/" + label + "-value.txt"
    do {
        try value.write(toFile: outPath, atomically: true, encoding: .utf8)
    } catch {
        print("[read] could not write \(outPath): \(error)")
    }
    let readMs = String(format: "%.1f ms (fastest of 5)", reads.min() ?? 0)
    let agrees = want.hasPrefix(normalize(value))
    let shown = agrees ? "matches the test text" : "DIFFERS from the test text"
    let readFidelity = truncated
        ? "truncated: first \(n16) of \(u16Count(want)) UTF-16 units, shown part \(shown)"
        : fidelity(value, want)
    print("[read] \(n16) UTF-16 units read in \(readMs); fidelity: \(readFidelity)")
    printState(snapshot(area))
    guard value.hasPrefix(HEADER_PREFIX) else {
        print("RESULT \(label) readFidelity=\"\(readFidelity)\" readMs=\"\(readMs)\" header=missing: the field does not hold the test text, typing tests skipped")
        return
    }
    // What the field is believed to hold in full. Dropped as soon as the field disagrees.
    var model: String? = agrees ? want : nil

    /// The part of a text this probe can see in the field.
    func visible(_ m: String) -> String { u16Sub(m, 0, cap ?? u16Count(m)) ?? m }

    /// The focused field, only while the app is frontmost and the field shows exactly what is expected.
    func field() -> AXUIElement? {
        fieldCheck().0
    }

    /// The same check, with the reason when it fails.
    func fieldCheck() -> (AXUIElement?, String) {
        guard let model else { return (nil, "the field no longer shows the expected text") }
        guard frontmostPid() == pid else {
            return (nil, "the app is not frontmost (pid \(frontmostPid() ?? -1), expected \(pid))")
        }
        guard CGPreflightPostEventAccess() else { return (nil, "event posting is unavailable") }
        guard let el = focusedTextArea(app, seconds: 3), let v = textValue(el).value else {
            return (nil, "the focused element is not a readable text area")
        }
        guard normalize(v) == visible(model) else { return (nil, "the field shows text other than expected") }
        return (el, "ok")
    }

    /// Read the field after a change; the model survives only if the field shows the planned text.
    @discardableResult
    func settle(_ planned: String, tag: String) -> Bool {
        guard let el = focusedTextArea(app, seconds: 3), let after = textValue(el).value else {
            print("[\(tag)] field not readable afterwards")
            model = nil
            return false
        }
        let ok = normalize(after) == visible(planned)
        model = ok ? planned : nil
        print("[\(tag)] field shows the planned text afterwards: \(ok)")
        return ok
    }

    // 5. Beyond the visible part: text reads and selections far into the field.
    var farOk = "not tested"
    var far2Ok = "not tested"
    if truncated {
        let t0 = DispatchTime.now().uptimeNanoseconds
        if let (text, calls) = pagedText(area, pageSize: 10_000) {
            let ms = String(format: "%.1f ms", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            let verdict = text == (u16Sub(want, 0, u16Count(text)) ?? "") ? "matches the test text" : "DIFFERS from the test text"
            print("[page] whole field through AXStringForRange: \(u16Count(text)) of \(u16Count(want)) units in \(calls) calls, \(ms), \(verdict)")
        } else {
            print("[page] AXStringForRange returned nothing")
        }
        if let w = u16Sub(want, 150_000, 150_023) {
            farOk = trySelection(area, 150_000, 23, expected: w, tag: "far") ? "yes" : "no"
        }
        if let w = u16Sub(want, 205_000, 205_023) {
            far2Ok = trySelection(area, 205_000, 23, expected: w, tag: "far-beyond-paging") ? "yes" : "no"
        }
    }

    // 6. Offset units: select the emoji by its UTF-16 offset.
    var offsets = "not tested"
    if let o16 = u16Offset(of: EMOJI, in: value), let range = value.range(of: EMOJI) {
        if trySelection(area, o16, 2, expected: EMOJI, tag: "units") {
            offsets = "UTF-16 code units"
        } else {
            let o8 = value[..<range.lowerBound].utf8.count
            let byBytes = trySelection(area, o8, 4, expected: EMOJI, tag: "units-utf8")
            offsets = byBytes ? "UTF-8 bytes" : "unknown: neither unit selected the emoji"
        }
    } else {
        print("[units] emoji not found in the value")
    }

    // 7. Set a selection on a phrase (what F2 needs).
    var setOk = "no"
    if let t = u16Offset(of: TARGET, in: value) {
        setOk = trySelection(area, t, u16Count(TARGET), expected: TARGET, tag: "set") ? "yes" : "no"
    }

    let frontmost = frontmostPid() == pid
    print("[activate] frontmost=\(frontmost)")
    let notTyped = "not typed: \(fieldCheck().1)"

    if let el = field(), let t = u16Offset(of: TARGET, in: value) {
        _ = setSelection(el, t, u16Count(TARGET))
        print("[show] \(TARGET) should be highlighted in \(label) for the next second")
        pause(1)
    }

    // 8. Typing over the selection replaces it (what D4 needs).
    var replaceOk = "skipped"
    var caretOk = "skipped"
    if let el = field(), let m = model, let t = u16Offset(of: TARGET, in: m) {
        let length = u16Count(TARGET)
        if trySelection(el, t, length, expected: TARGET, tag: "replace-select"), frontmostPid() == pid {
            typeText(TOKEN)
            pause(0.4)
            let planned = (u16Sub(m, 0, t) ?? "") + TOKEN + (u16Sub(m, t + length, u16Count(m)) ?? "")
            replaceOk = settle(planned, tag: "replace") ? "yes" : "no"
            let caret = rangeAttr(focusedTextArea(app, seconds: 3) ?? el, kAXSelectedTextRangeAttribute).value
            caretOk = caret?.location == t + u16Count(TOKEN) && caret?.length == 0 ? "yes" : "no"
        } else {
            print("[replace] \(notTyped)")
        }
    } else {
        print("[replace] \(notTyped)")
    }

    // 9. Typing at a collapsed caret inserts there (what F1 needs).
    var typeAtCaret = "skipped"
    if let el = field(), let m = model {
        let c = 5
        if trySelection(el, c, 0, expected: "", tag: "caret-select"), frontmostPid() == pid {
            typeText(TOKEN)
            pause(0.4)
            let planned = (u16Sub(m, 0, c) ?? "") + TOKEN + (u16Sub(m, c, u16Count(m)) ?? "")
            typeAtCaret = settle(planned, tag: "caret") ? "yes" : "no"
        } else {
            print("[caret] \(notTyped)")
        }
    } else {
        print("[caret] \(notTyped)")
    }

    // 10. Remove the test text: select through AX, verify, one Backspace. A field longer than
    // AX can page through takes more than one pass.
    var cleanup = model == nil ? "skipped: \(notTyped)" : "incomplete"
    var passes = 0
    while let el = field(), let m = model, !m.isEmpty, passes < 5 {
        passes += 1
        var length = u16Count(m)
        let shownCount = intAttr(el, kAXNumberOfCharactersAttribute).value ?? u16Count(visible(m))
        if cap != nil, let (text, _) = pagedText(el, pageSize: 10_000) {
            length = u16Count(text)
            if text != (u16Sub(m, 0, length) ?? "") {
                print("[cleanup] the text beyond the visible part differs from what was expected; stopping")
                model = nil
                break
            }
        }
        guard frontmostPid() == pid, setSelection(el, 0, length) == .success else { model = nil; break }
        pause(0.2)
        let back = rangeAttr(el, kAXSelectedTextRangeAttribute).value
        let pickedLength = stringAttr(el, kAXSelectedTextAttribute).value.map { u16Count($0) }
        let rangeOk = back?.location == 0 && back?.length == length
        let textOk = pickedLength.map { $0 == length || $0 == min(length, shownCount) } ?? true
        guard rangeOk, textOk, frontmostPid() == pid else {
            print("[cleanup] selection not verified (range \(describeRange(back)), selected text \(describeCount(pickedLength)) units); stopping")
            model = nil
            break
        }
        postKey(51)
        pause(0.5)
        let remaining = u16Sub(m, length, u16Count(m)) ?? ""
        print("[cleanup] pass \(passes): \(length) units selected and deleted")
        settle(remaining, tag: "cleanup")
        if model == nil { break }
        if remaining.isEmpty {
            cleanup = "clean after \(passes) pass(es)"
            break
        }
    }
    if model?.isEmpty == true, cleanup == "incomplete" { cleanup = "clean" }
    let clean = cleanup.hasPrefix("clean")
    if !clean { print("[cleanup] \(cleanup); delete the test text in \(label) by hand") }
    if clean, let closeTitle {
        closeFrontmostWindows(app, pid: pid, titleContains: closeTitle, hasSaveSheet: closeHasSheet)
    }

    print("RESULT \(label) readFidelity=\"\(readFidelity)\" readMs=\"\(readMs)\" farSelection=\(farOk) selectionBeyondPaging=\(far2Ok) offsets=\"\(offsets)\" setSelection=\(setOk) replaceSelection=\(replaceOk) caretAfterTyped=\(caretOk) typeAtCaret=\(typeAtCaret) cleanup=\"\(cleanup)\"")
}

func printState(_ s: State) {
    let firstLine = String(s.value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    let length = s.value.isEmpty ? "0 (empty)" : "\(u16Count(s.value)) UTF-16 units, \(s.value.count) characters"
    print("  value: \(length); first line: \(show(firstLine))")
    print("  number of characters: \(describeCount(s.count))")
    print("  selected range: \(describeRange(s.range))")
    print("  selected text: \(describeText(s.selectedText))")
}

/// Delete test text that an interrupted run left in the focused field. The whole field,
/// read back through a select-all, must equal the expected text exactly.
func purge(_ pid: pid_t, _ expectedFile: String) {
    guard AXIsProcessTrusted() else { die("Accessibility is not granted to this process") }
    let want = normalize((try? String(contentsOfFile: expectedFile, encoding: .utf8)) ?? "")
    guard !want.isEmpty else { die("missing or empty \(expectedFile)") }
    let n = u16Count(want)
    let app = AXUIElementCreateApplication(pid)
    guard activate(app, pid) else { die("could not bring pid \(pid) to the front") }
    pause(0.3)
    guard let el = focusedTextArea(app, seconds: 5) else { die("the focused element is not a text area") }
    guard let head = textValue(el).value, normalize(head) == (u16Sub(want, 0, u16Count(normalize(head))) ?? "") else {
        let got = textValue(el).value.map { show($0, 40) } ?? "unreadable"
        die("the focused field does not show the expected text (starts \(got))")
    }
    guard setSelection(el, 0, n) == .success else { die("the select-all was refused") }
    pause(0.3)
    let back = rangeAttr(el, kAXSelectedTextRangeAttribute).value
    let picked = stringAttr(el, kAXSelectedTextAttribute).value
    guard back?.location == 0, back?.length == n, let picked, normalize(picked) == want else {
        die("the selection does not match the expected text (range \(describeRange(back)), selected text \(describeCount(picked.map { u16Count($0) })) units)")
    }
    guard frontmostPid() == pid, CGPreflightPostEventAccess() else { die("the app is not frontmost; nothing was typed") }
    postKey(51)
    pause(0.6)
    let left = focusedTextArea(app, seconds: 3).flatMap { textValue($0).value } ?? "?"
    print(left.isEmpty
        ? "[purge] deleted \(n) UTF-16 units; the field is empty"
        : "[purge] the field still holds \(u16Count(left)) UTF-16 units; delete them by hand")
}

func selftest() -> Int {
    var failures = 0
    func check(_ name: String, _ ok: Bool) {
        print("selftest \(name): \(ok ? "ok" : "FAIL")")
        if !ok { failures += 1 }
    }
    let s = "AB" + EMOJI + "CD"
    check("utf16 length", u16Count(s) == 6)
    check("utf16 substring before the emoji", u16Sub(s, 0, 2) == "AB")
    check("utf16 substring over the emoji", u16Sub(s, 2, 4) == EMOJI)
    check("utf16 substring after the emoji", u16Sub(s, 4, 6) == "CD")
    check("utf16 range inside a surrogate pair is rejected", u16Sub(s, 3, 5) == nil)
    check("utf16 range past the end is rejected", u16Sub(s, 0, 7) == nil)
    check("utf16 offset of the emoji", u16Offset(of: EMOJI, in: s) == 2)
    let t = HEADER_PREFIX + "axiomatic " + EMOJI + " brown fox " + TARGET + "\nmore"
    check("target offset in the header", u16Offset(of: TARGET, in: t) == 31)
    check("caret at 5 splits the header", u16Sub(t, 0, 5) == "AXPRO" && u16Sub(t, 5, 8) == "BE ")
    check("replacement arithmetic", (u16Sub(t, 0, 31) ?? "") + "X" + (u16Sub(t, 31 + u16Count(TARGET), u16Count(t)) ?? "") == HEADER_PREFIX + "axiomatic " + EMOJI + " brown fox X\nmore")
    check("fidelity: identical", fidelity("a\r\nb" + EMOJI, "a\nb" + EMOJI).hasPrefix("exact"))
    check("fidelity: extra trailing text", fidelity("abc!", "abc").hasPrefix("field holds"))
    check("fidelity: first difference", fidelity("abXc", "abYc").contains("offset 2"))
    return failures
}

// MARK: - Entry point

func usage() -> Never {
    die("usage: axprobe mktext <out-dir> [wordlist] [words] | run <pid> <label> <out-dir> [--paste <file>] [--focus <prefix>] [--close <title>] [--sheet yes] [--enhance yes] [--header yes] | purge <pid> <label> <expected-text-file> | selftest")
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "selftest":
    exit(selftest() == 0 ? 0 : 1)
case "mktext":
    guard args.count >= 3 else { usage() }
    makeTestFiles(args[2], args.count > 3 ? args[3] : "/usr/share/dict/words", args.count > 4 ? Int(args[4]) ?? 20000 : 20000)
case "purge":
    guard args.count >= 5, let pid = Int32(args[2]) else { usage() }
    purge(pid, args[4])
case "run":
    guard args.count >= 5, let pid = Int32(args[2]) else { usage() }
    var paste: String?
    var focus: String?
    var closeTitle: String?
    var closeHasSheet = false
    var enhance = false
    var findHeader = false
    var i = 5
    while i < args.count {
        guard i + 1 < args.count else { usage() }
        if args[i] == "--paste" {
            paste = args[i + 1]
        } else if args[i] == "--focus" {
            focus = args[i + 1]
        } else if args[i] == "--close" {
            closeTitle = args[i + 1]
        } else if args[i] == "--sheet" {
            closeHasSheet = args[i + 1] == "yes"
        } else if args[i] == "--enhance" {
            enhance = args[i + 1] == "yes"
        } else if args[i] == "--header" {
            findHeader = args[i + 1] == "yes"
        } else {
            usage()
        }
        i += 2
    }
    run(pid, args[3], args[4], pasteFile: paste, focus: focus, closeTitle: closeTitle,
        closeHasSheet: closeHasSheet, enhance: enhance, findHeader: findHeader)
default:
    usage()
}
