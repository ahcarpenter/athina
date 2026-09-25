import AppKit
import Testing
@testable import AthinaControl

/// `menu press=`: the item a path of titles names in the status item's menu,
/// through its submenus, and a refusal naming the step when one is not there
/// or is dimmed.
@MainActor
@Suite struct MenuTargetTests {
    func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        return menu
    }

    func item(_ title: String, enabled: Bool = true, submenu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.isEnabled = enabled
        return item
    }

    var status: NSMenu {
        menu("Athina", [
            item("Settings…"),
            item("Answer Suggestion", submenu: menu("Answer Suggestion", [item("Tell Me More"), item("Not Now", enabled: false)])),
            item("Pause", enabled: false, submenu: menu("Pause", [item("For an Hour")])),
            item("Quit Athina"),
        ])
    }

    /// The found item's menu and title, or nil for a refusal.
    func found(_ path: String) -> [String]? {
        guard case .item(let holder, let index) = ControlCommands.target(path, in: status) else { return nil }
        return [holder.title, holder.items[index].title]
    }

    @Test func anItemOfTheMenuIsFound() {
        #expect(found("Settings…") == ["Athina", "Settings…"])
        #expect(found("Quit Athina") == ["Athina", "Quit Athina"])
    }

    @Test func anItemInASubmenuIsFound() {
        #expect(found("Answer Suggestion > Tell Me More") == ["Answer Suggestion", "Tell Me More"])
    }

    @Test func aMissingStepIsRefusedByName() {
        #expect(ControlCommands.target("Debug Panel", in: status)
            == .refused(reason: "missing", message: #"the menu has no item "Debug Panel""#))
        #expect(ControlCommands.target("Answer Suggestion > Tell Me Less", in: status)
            == .refused(reason: "missing", message: #""Answer Suggestion" has no item "Tell Me Less""#))
        #expect(ControlCommands.target("Answer > Tell Me More", in: status)
            == .refused(reason: "missing", message: #"the menu has no item "Answer""#))
        #expect(ControlCommands.target("Settings… > General", in: status)
            == .refused(reason: "missing", message: #""Settings…" has no submenu"#))
    }

    @Test func aDimmedStepIsRefusedByName() {
        #expect(ControlCommands.target("Answer Suggestion > Not Now", in: status)
            == .refused(reason: "disabled", message: #""Not Now" is dimmed"#))
        // A dimmed submenu cannot be opened, so nothing in it can be chosen.
        #expect(ControlCommands.target("Pause > For an Hour", in: status)
            == .refused(reason: "disabled", message: #""Pause" is dimmed"#))
    }
}
