import AppKit
import ApplicationServices
import AthinaControlProtocol

/// Athina's own accessibility tree, as an assistive app sees it, read through
/// the AXUIElement API on the main actor.
///
/// It is the tree VoiceOver reads: SwiftUI's own buttons and links with their
/// labels, which the in-process NSAccessibility walk from a window never
/// reaches (it stops at the AppKit views, such as a Form's switch). A request
/// to this process's own tree is answered on the calling thread, so it has to
/// be made on the main actor: made from any other thread, it has SwiftUI
/// evaluate views off the main actor, which traps.
@MainActor
struct AppAccessibility {
    /// One control of the tree, and what `find` and `click` need about it.
    struct Node {
        let element: AXUIElement
        let window: NSWindow
        let windowTitle: String
        let role: String
        let subrole: String
        let label: String
        let title: String
        let identifier: String
        let value: String
        let enabled: Bool
        /// Top-left global coordinates, as accessibility reports them.
        let frame: CGRect
        /// Whether it sits in the window's toolbar or title bar.
        let inChrome: Bool
        /// The frames of the scroll areas it sits in, in the same coordinates.
        let clips: [CGRect]

        var summary: ControlValue {
            .object([
                "role": .string(role), "subrole": .string(subrole), "label": .string(label), "title": .string(title),
                "identifier": .string(identifier), "value": .string(value), "enabled": .bool(enabled),
                "frame": .array([frame.minX, frame.minY, frame.width, frame.height].map { .number(Double($0)) }),
                "window": .string(windowTitle), "chrome": .bool(inChrome),
            ])
        }
    }

    /// What a request asks for: the window whose title contains `window`
    /// (every window of the app when it is absent), and a control there by
    /// `identifier`, or by `role`, `subrole`, and `label` (its description or
    /// title, compared whole, ignoring case).
    struct Query {
        var window: String?
        var identifier: String?
        var role: String?
        var subrole: String?
        var label: String?

        init(_ request: ControlRequest) throws {
            window = try request.string("window")
            identifier = try request.string("identifier")
            role = try request.string("role")
            subrole = try request.string("subrole")
            label = try request.string("label")
        }

        var namesAControl: Bool { identifier != nil || role != nil || subrole != nil || label != nil }

        func matches(_ node: Node) -> Bool {
            if let identifier, node.identifier != identifier { return false }
            if let role, node.role != role { return false }
            if let subrole, node.subrole != subrole { return false }
            if let label {
                return [node.label, node.title].contains { $0.caseInsensitiveCompare(label) == .orderedSame }
            }
            return true
        }
    }

    static let windowButtons: Set<String> = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]

    /// The app's windows a request can reach, those on screen or ordered in.
    static func windows(titled title: String?) -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible && (title.map { window.title.localizedCaseInsensitiveContains($0) } ?? true)
        }
    }

    /// Every control matching the query, in tree order.
    static func nodes(_ query: Query) -> [Node] {
        let app = AXUIElementCreateApplication(getpid())
        let axWindows = (value(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var found: [Node] = []
        for window in windows(titled: query.window) {
            guard let root = axWindows.first(where: { matches($0, window) }) else { continue }
            walk(root, in: window, titled: window.title, chrome: false, clips: [], depth: 0) { node in
                if query.matches(node) { found.append(node) }
            }
        }
        return found
    }

    /// The accessibility window for an AppKit window: same title, same frame.
    private static func matches(_ element: AXUIElement, _ window: NSWindow) -> Bool {
        guard string(element, kAXTitleAttribute) == window.title else { return false }
        let frame = frame(of: element)
        let expected = globalFrame(of: window.frame)
        return abs(frame.minX - expected.minX) < 2 && abs(frame.minY - expected.minY) < 2
            && abs(frame.width - expected.width) < 2 && abs(frame.height - expected.height) < 2
    }

    /// Visits `element` and everything under it. A sheet shows in the tree
    /// of the window it is attached to, under the title a request names, but
    /// is a window of its own: what it holds is judged against the sheet, and
    /// a click on it posted there.
    private static func walk(
        _ element: AXUIElement, in window: NSWindow, titled title: String, chrome: Bool, clips: [CGRect], depth: Int,
        visit: (Node) -> Void
    ) {
        guard depth < 48 else { return }
        let role = string(element, kAXRoleAttribute)
        let window = role == "AXSheet" ? window.attachedSheet ?? window : window
        let subrole = string(element, kAXSubroleAttribute)
        let frame = frame(of: element)
        let inChrome = chrome || role == "AXToolbar" || windowButtons.contains(subrole)
        visit(Node(
            element: element, window: window, windowTitle: title, role: role, subrole: subrole,
            label: string(element, kAXDescriptionAttribute), title: string(element, kAXTitleAttribute),
            identifier: string(element, kAXIdentifierAttribute), value: string(element, kAXValueAttribute),
            enabled: (value(element, kAXEnabledAttribute) as? Bool) ?? true,
            frame: frame, inChrome: inChrome, clips: clips
        ))
        let childClips = role == "AXScrollArea" ? clips + [frame] : clips
        for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            walk(child, in: window, titled: title, chrome: inChrome, clips: childClips, depth: depth + 1, visit: visit)
        }
    }

    static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String {
        switch value(element, name) {
        case let text as String: text
        case let number as NSNumber: number.stringValue
        default: ""
        }
    }

    static func frame(of element: AXUIElement) -> CGRect {
        var point = CGPoint.zero
        var size = CGSize.zero
        if let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID() {
            AXValueGetValue(position as! AXValue, .cgPoint, &point)
        }
        if let extent = value(element, kAXSizeAttribute), CFGetTypeID(extent) == AXValueGetTypeID() {
            AXValueGetValue(extent as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: point, size: size)
    }

    /// The height of the screen whose top-left corner accessibility measures from.
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// A Cocoa screen rectangle (origin bottom left) in accessibility's
    /// top-left global coordinates, and back.
    static func globalFrame(of screenRect: CGRect) -> CGRect {
        CGRect(x: screenRect.minX, y: primaryHeight - screenRect.maxY, width: screenRect.width, height: screenRect.height)
    }

    static func screenRect(of globalFrame: CGRect) -> CGRect {
        CGRect(x: globalFrame.minX, y: primaryHeight - globalFrame.maxY, width: globalFrame.width, height: globalFrame.height)
    }

    /// A top-left global rectangle in a window's own coordinates.
    static func windowRect(of globalFrame: CGRect, in window: NSWindow) -> CGRect {
        window.convertFromScreen(screenRect(of: globalFrame))
    }
}
