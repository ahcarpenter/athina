import AppKit
import ApplicationServices
import Foundation

/// Which part of the focus changed.
public enum FocusChangeKind: Sendable {
    case application
    case window
    case element
}

public struct FocusChange: Sendable {
    public var kind: FocusChangeKind
    public var context: FocusContext
}

/// Follows the frontmost app and its focused window and element through
/// NSWorkspace notifications and AX observers, and reads the context on demand.
@AXActor
public final class FocusTracker {
    private var onChange: (@Sendable (FocusChange) -> Void)?

    private var excludedBundleIDs: Set<String> = []
    private var current: RunningApp?
    private var observer: AXObserver?
    private var workspaceToken: (any NSObjectProtocol)?
    private var lastContext: FocusContext?
    private var isRunning = false

    private struct RunningApp: Sendable {
        var pid: pid_t
        var bundleID: String?
        var name: String
    }

    public nonisolated init() {}

    public func setOnChange(_ handler: (@Sendable (FocusChange) -> Void)?) {
        onChange = handler
    }

    public func updateExcluded(_ bundleIDs: Set<String>) {
        guard bundleIDs != excludedBundleIDs else { return }
        excludedBundleIDs = bundleIDs
        if let current, isRunning {
            // Exclusion state may have flipped for the current app: re-evaluate observers.
            attach(to: current, kind: .application)
        }
    }

    /// Installs or removes the current app's observer when the Accessibility
    /// grant no longer matches what was in place when the app was attached.
    public func refreshObserver() {
        guard let current, isRunning else { return }
        let excluded = ExcludedApps.matches(bundleID: current.bundleID, excluded: excludedBundleIDs)
        let wantsObserver = !excluded && AXIsProcessTrusted()
        guard wantsObserver != (observer != nil) else { return }
        attach(to: current, kind: .application)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let running = RunningApp(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            )
            Task { @AXActor [weak self] in
                self?.attach(to: running, kind: .application)
            }
        }
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: RunningApp(
                pid: app.processIdentifier,
                bundleID: app.bundleIdentifier,
                name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)"
            ), kind: .application)
        }
    }

    public func stop() {
        isRunning = false
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
        }
        workspaceToken = nil
        detachObserver()
    }

    /// Reads the current focus context fresh from the AX API.
    public func readCurrent() -> FocusContext? {
        guard let current else { return nil }
        let context = read(current)
        lastContext = context
        return context
    }

    // MARK: Observers

    private func attach(to app: RunningApp, kind: FocusChangeKind) {
        current = app
        detachObserver()
        let excluded = ExcludedApps.matches(bundleID: app.bundleID, excluded: excludedBundleIDs)
        if !excluded, AXIsProcessTrusted() {
            installObserver(pid: app.pid)
        }
        publish(kind: kind)
    }

    private func installObserver(pid: pid_t) {
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            Task { @AXActor in
                tracker.handleNotification(name)
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXFocusedWindowChangedNotification,
            kAXFocusedUIElementChangedNotification,
            kAXTitleChangedNotification,
            kAXMainWindowChangedNotification,
        ] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(AXActor.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
    }

    private func detachObserver() {
        if let observer {
            CFRunLoopRemoveSource(AXActor.runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
    }

    private func handleNotification(_ name: String) {
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            publish(kind: .window)
        case kAXTitleChangedNotification:
            // Title changes on the window we are already tracking (tab switches, document renames).
            let before = lastContext?.windowSignature
            let context = readCurrent()
            if context?.windowSignature != before {
                if let context { onChange?(FocusChange(kind: .window, context: context)) }
            }
        default:
            publish(kind: .element)
        }
    }

    private func publish(kind: FocusChangeKind) {
        guard let context = readCurrent() else { return }
        onChange?(FocusChange(kind: kind, context: context))
    }

    // MARK: Reading

    private func read(_ app: RunningApp) -> FocusContext {
        var context = FocusContext(pid: app.pid, bundleID: app.bundleID, appName: app.name)
        if ExcludedApps.matches(bundleID: app.bundleID, excluded: excludedBundleIDs) {
            context.isExcluded = true
            return context
        }
        guard AXIsProcessTrusted() else {
            context.accessibilityAvailable = false
            return context
        }
        let appElement = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)

        if let window = appElement.element(kAXFocusedWindowAttribute) ?? appElement.element(kAXMainWindowAttribute) {
            context.windowTitle = window.string(kAXTitleAttribute)
            if let origin = window.point(kAXPositionAttribute), let size = window.size(kAXSizeAttribute) {
                context.windowFrame = CGRect(origin: origin, size: size)
            }
        }
        if let focused = appElement.element(kAXFocusedUIElementAttribute) {
            context.focusedRole = focused.string(kAXRoleAttribute)
            context.focusedSubrole = focused.string(kAXSubroleAttribute)
            context.focusedTitle = focused.string(kAXTitleAttribute)
            context.focusedDescription = focused.string(kAXDescriptionAttribute)
            let isSecure = context.focusedSubrole == (kAXSecureTextFieldSubrole as String)
                || context.focusedRole == "AXSecureTextField"
            if !isSecure, let value = focused.textValue() {
                context.focusedValueLength = value.count
                context.focusedValue = String(value.prefix(FocusContext.maxValueLength))
            }
        }
        return context
    }
}

// MARK: - AXUIElement attribute helpers

extension AXUIElement {
    fileprivate func raw(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(self, attribute as CFString, &value)
        return result == .success ? value : nil
    }

    fileprivate func element(_ attribute: String) -> AXUIElement? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        return element
    }

    fileprivate func string(_ attribute: String) -> String? {
        guard let value = raw(attribute) else { return nil }
        return value as? String
    }

    fileprivate func point(_ attribute: String) -> CGPoint? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
    }

    fileprivate func size(_ attribute: String) -> CGSize? {
        guard let value = raw(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
    }

    /// The element's value as text when it has a textual value.
    fileprivate func textValue() -> String? {
        guard let value = raw(kAXValueAttribute) else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
