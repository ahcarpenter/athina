import AppKit
import ApplicationServices
import Foundation

/// Reading and pressing through accessibility: the route that needs no
/// pointer, so it works while someone else is using the Mac, and the only
/// route to a menu item a mouse cannot reach.
enum Accessibility {
  /// Does one action to a pid's elements.
  ///
  /// Only those under `scope` when it is given; `terms` are the role, match
  /// and value `action` takes.
  static func run(pid: pid_t, action: AX.Action, terms: [String], scope: String?) {
    let app = AXUIElementCreateApplication(pid)

    func windows() -> [AXUIElement] { (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }

    /// Where to look: a window whose title contains `scope`, the status
    /// menu (`extras`), or everything the app shows.
    func roots() -> [AXUIElement] {
      guard let scope, !scope.isEmpty else {
        var roots = windows()
        if let extras = attr(app, "AXExtrasMenuBar") { roots.append(extras as! AXUIElement) }
        return roots
      }
      if scope == "extras" {
        return attr(app, "AXExtrasMenuBar").map { [$0 as! AXUIElement] } ?? []
      }
      return windows().filter { title($0).localizedCaseInsensitiveContains(scope) }
    }

    func matches(_ element: AXUIElement, role wanted: String, name: String, exact: Bool) -> Bool {
      if !wanted.isEmpty, role(element) != wanted { return false }
      if name.isEmpty { return true }
      return exact
        ? names(element).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        : names(element).contains { $0.localizedCaseInsensitiveContains(name) }
    }

    func find(role wanted: String, name: String, exact: Bool) -> AXUIElement? {
      for root in roots() {
        if let found = first(root, { matches($0, role: wanted, name: name, exact: exact) }) {
          return found
        }
      }
      return nil
    }

    switch action {
    case .dump:
      for root in roots() {
        say("ROOT \(line(root))")
        walk(root, depth: 1)
      }

    case .texts:
      // AXUnknown is in the list because that is the role SwiftUI gives a
      // row whose parts are combined into one element, which is how
      // VoiceOver reads most of Athina's rows.
      let interesting = [
        "AXStaticText",
        "AXButton",
        "AXCheckBox",
        "AXTextField",
        "AXTextArea",
        "AXMenuItem",
        "AXMenuBarItem",
        "AXUnknown",
      ]
      for root in roots() {
        var found: [AXUIElement] = []
        findAll(root, { interesting.contains(role($0)) }, into: &found)
        for element in found { say(line(element)) }
      }

    case .menuitems:
      guard let extras = attr(app, "AXExtrasMenuBar") else {
        fail("ax menuitems: pid \(pid) has no menu bar extra", code: 2)
      }
      var found: [AXUIElement] = []
      findAll(extras as! AXUIElement, { role($0) == "AXMenuItem" }, into: &found)
      for element in found {
        say("AXMenuItem title=\"\(title(element))\" en=\(text(attr(element, kAXEnabledAttribute)))")
      }

    case .menu:
      // The open status menu's own rows as macOS shows them, top level
      // only, in order: the title and whether it is enabled, or "-" for
      // a separator, which accessibility shows as a row with no title.
      // The same shape as the control API's `menu`, so the two compare.
      guard let extras = attr(app, "AXExtrasMenuBar"),
        let menu = first(extras as! AXUIElement, { role($0) == "AXMenu" })
      else {
        fail("ax menu: pid \(pid) has no open menu", code: 2)
      }
      for item in children(menu) where role(item) == "AXMenuItem" {
        let name = title(item)
        let enabled = text(attr(item, kAXEnabledAttribute)) == "1"
        say(name.isEmpty ? "-" : "\(name)\t\(enabled ? "enabled" : "dimmed")")
      }

    case .pressextra:
      guard let item = statusItem(of: pid) else {
        fail("ax pressextra: pid \(pid) has no menu bar extra", code: 2)
      }
      let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
      say("pressextra \"\(title(item))\" desc=\"\(describe(item))\" -> \(status.rawValue)")

    case .cancelmenu:
      guard let extras = attr(app, "AXExtrasMenuBar") else {
        fail("ax cancelmenu: pid \(pid) has no menu bar extra", code: 2)
      }
      guard let menu = first(extras as! AXUIElement, { role($0) == "AXMenu" }) else {
        fail("ax cancelmenu: no open menu", code: 2)
      }
      say("cancelmenu -> \(AXUIElementPerformAction(menu, kAXCancelAction as CFString).rawValue)")

    case .get, .press, .pressx, .focus, .set:
      let wanted = terms[0]
      let name = terms.count > 1 ? terms[1] : ""
      guard let element = find(role: wanted, name: name, exact: action == .pressx) else {
        fail(
          "ax \(action.rawValue): no \(wanted.isEmpty ? "element" : wanted) matching \"\(name)\"",
          code: 2
        )
      }
      switch action {
      case .get:
        say(line(element))
      case .press, .pressx:
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        say(
          """
          press \(role(element)) \"\(title(element))\" desc=\"\(describe(element))\" -> \
          \(status.rawValue)
          """
        )
        if status != .success { exit(2) }
      case .focus:
        let status = AXUIElementSetAttributeValue(
          element,
          kAXFocusedAttribute as CFString,
          kCFBooleanTrue
        )
        say("focus \(role(element)) -> \(status.rawValue)")
      default:
        let newValue = terms[2]
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // A number goes in as a number only where the element's value
        // already is one, as a scroll bar's is: a text field, which is
        // most of what a scenario sets, refuses anything but a string.
        var payload = newValue as CFTypeRef
        if let current = attr(element, kAXValueAttribute),
          CFGetTypeID(current) == CFNumberGetTypeID(),
          let number = Double(newValue)
        {
          payload = NSNumber(value: number) as CFTypeRef
        }
        let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, payload)
        if status != .success {
          fail(
            """
            ax set: \(role(element)) refused \"\(newValue)\" -> \(status.rawValue), value \
            still \"\(value(element).prefix(200))\"
            """,
            code: 2
          )
        }
        say(
          "set \(role(element)) -> \(status.rawValue) now value=\"\(value(element).prefix(200))\""
        )
      }

    }
  }

  private static func walk(_ element: AXUIElement, depth: Int) {
    let wrapper = [
      "AXGroup", "AXUnknown", "AXSplitGroup", "AXLayoutArea", "AXLayoutItem", "AXScrollArea",
    ]
    let boring =
      wrapper.contains(role(element)) && title(element).isEmpty && describe(element).isEmpty
    if !boring { say(String(repeating: " ", count: depth) + line(element)) }
    for child in children(element) { walk(child, depth: depth + 1) }
  }
}
