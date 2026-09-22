import AppKit
import ApplicationServices
import Foundation

// Shared plumbing for the drive commands: accessibility reads, window lists,
// and the timestamps every transcript is lined up on.

func stamp(_ date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: date)
}

func say(_ text: String) {
    print(text)
    fflush(stdout)
}

func fail(_ text: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(code)
}

// MARK: - Accessibility

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func text(_ value: Any?) -> String {
    guard let value else { return "" }
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    if CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() {
        var point = CGPoint.zero
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) { return "(\(Int(point.x)),\(Int(point.y)))" }
        if AXValueGetValue(value as! AXValue, .cgSize, &size) { return "\(Int(size.width))x\(Int(size.height))" }
    }
    return String(describing: value).prefix(60).description
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String { text(attr(element, kAXRoleAttribute)) }
func title(_ element: AXUIElement) -> String { text(attr(element, kAXTitleAttribute)) }
func describe(_ element: AXUIElement) -> String { text(attr(element, kAXDescriptionAttribute)) }
func value(_ element: AXUIElement) -> String { text(attr(element, kAXValueAttribute)) }

/// SwiftUI puts a control's name in AXDescription and leaves AXTitle empty, so
/// a match has to look at every name-bearing attribute.
func names(_ element: AXUIElement) -> [String] {
    [
        title(element), describe(element), value(element),
        text(attr(element, kAXHelpAttribute)), text(attr(element, kAXIdentifierAttribute)),
    ]
}

func line(_ element: AXUIElement) -> String {
    "\(role(element)) title=\"\(title(element))\" desc=\"\(describe(element))\" "
        + "value=\"\(value(element).prefix(160))\" en=\(text(attr(element, kAXEnabledAttribute))) "
        + "pos=\(text(attr(element, kAXPositionAttribute))) size=\(text(attr(element, kAXSizeAttribute)))"
}

func findAll(_ element: AXUIElement, _ matches: (AXUIElement) -> Bool, into found: inout [AXUIElement]) {
    if matches(element) { found.append(element) }
    for child in children(element) { findAll(child, matches, into: &found) }
}

func first(_ element: AXUIElement, _ matches: (AXUIElement) -> Bool) -> AXUIElement? {
    if matches(element) { return element }
    for child in children(element) {
        if let found = first(child, matches) { return found }
    }
    return nil
}

func frame(of element: AXUIElement) -> CGRect? {
    guard let positionValue = attr(element, kAXPositionAttribute),
          let sizeValue = attr(element, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

/// The app's single menu bar extra (Athina has one), from its AXExtrasMenuBar.
func statusItem(of pid: Int32) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    guard let extras = attr(app, "AXExtrasMenuBar") else { return nil }
    return children(extras as! AXUIElement).first
}

// MARK: - Windows

struct ScreenWindow {
    let id: Int
    let pid: Int32
    let owner: String
    let name: String
    let layer: Int
    let bounds: CGRect
    let alpha: Double

    var description: String {
        "id=\(id) pid=\(pid) owner=\"\(owner)\" name=\"\(name)\" layer=\(layer) "
            + "x=\(Int(bounds.minX)) y=\(Int(bounds.minY)) w=\(Int(bounds.width)) h=\(Int(bounds.height))"
    }
}

func onScreenWindows() -> [ScreenWindow] {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.map { window in
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        return ScreenWindow(
            id: window[kCGWindowNumber as String] as? Int ?? -1,
            pid: window[kCGWindowOwnerPID as String] as? Int32 ?? -1,
            owner: window[kCGWindowOwnerName as String] as? String ?? "?",
            name: window[kCGWindowName as String] as? String ?? "",
            layer: window[kCGWindowLayer as String] as? Int ?? 0,
            bounds: CGRect(
                x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
            ),
            alpha: window[kCGWindowAlpha as String] as? Double ?? 1
        )
    }
}

/// The window a click at `point` would land on: the frontmost normal window
/// containing it. Menus and the menu bar sit above every app window, so a
/// caller that cares about them checks accessibility as well.
func topmostWindow(at point: CGPoint) -> ScreenWindow? {
    onScreenWindows().first { $0.layer < 1000 && $0.alpha > 0 && $0.bounds.contains(point) }
}

/// Athina's suggestion toast, found by the fixed panel width
/// (`ToastController.panelWidth`, 380 plus a point of shadow inset each side).
/// The callout panel sits at the same window level but is sized to the region
/// it points at, so the width is what tells them apart.
let toastPanelWidth = 382.0

func toastWindow(of pid: Int32) -> ScreenWindow? {
    onScreenWindows().first { $0.pid == pid && abs($0.bounds.width - toastPanelWidth) < 1 }
}

func screencapture(_ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    process.arguments = arguments
    try? process.run()
    process.waitUntilExit()
}
