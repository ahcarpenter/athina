import Foundation

/// The Setup window's pages, in the order a first launch walks through them.
///
/// The window is titled by its page, as Settings is titled by its pane, so the
/// title says where the person is and VoiceOver reads it.
public enum SetupPage: String, CaseIterable, Sendable {
  /// What Athina reads and sends, and the person's answer (`Consent`).
  case consent
  /// Screen Recording and Accessibility, and the optional pair for talking back.
  case permissions
  /// The provider, its API key and the hourly spend cap.
  case model
  /// What to expect once Athina watches.
  case ready

  /// The window's title while it shows the page.
  public var title: String {
    switch self {
    case .consent: "Athina and Your Privacy"
    case .permissions: "Permissions"
    case .model: "Models"
    case .ready: "All Set"
    }
  }
}

/// Where the Setup window is: the page it shows, and whether it walks through
/// the pages after it.
///
/// A first launch walks through them. Everything else opens one page on its
/// own, as the menu's Permissions… and Allow Watching… do, and closes the
/// window once that page is done with.
public struct SetupState: Equatable, Sendable {
  /// The page the window shows.
  public var page: SetupPage
  /// Whether Back, Continue and the page dots walk on through the pages after
  /// it, as a first launch does.
  public var walksThrough: Bool

  /// A page, walked through or on its own.
  public init(page: SetupPage, walksThrough: Bool) {
    self.page = page
    self.walksThrough = walksThrough
  }
}

/// The buttons at the end of the Setup window's footer.
public enum SetupFooter: Equatable, Sendable {
  /// Not Now and Allow, for a consent page still unanswered.
  case answer
  /// Continue, on to the next page of a walk through.
  case `continue`
  /// Done, which closes the window.
  case done
  /// Not Now, which closes a permissions or model page opened on its own while
  /// a required permission is still off.
  case notNow
}

/// Which page comes next in the Setup window, as pure functions.
public enum SetupFlow {
  /// Where Allow leads: the next thing still to set up, or nil when there is
  /// nothing left and the window closes.
  ///
  /// A missing permission always comes next, walking through or not, as the
  /// Permissions window always opened after Allow. Only a walk through goes on
  /// to the model when a key is still needed.
  public static func afterAllow(
    walksThrough: Bool,
    permissionsGranted: Bool,
    needsKey: Bool
  ) -> SetupPage? {
    if !permissionsGranted { return .permissions }
    if walksThrough && needsKey { return .model }
    return nil
  }

  /// The pages a walk through steps through: the model page only while a
  /// key is still needed, as after Allow.
  public static func pages(needsKey: Bool) -> [SetupPage] {
    SetupPage.allCases.filter { $0 != .model || needsKey }
  }

  /// The page Continue shows in a walk through, or nil at the last page.
  public static func page(after page: SetupPage, needsKey: Bool) -> SetupPage? {
    pages(needsKey: needsKey).first { order(of: $0) > order(of: page) }
  }

  /// The page Back shows in a walk through, or nil at the first page.
  public static func page(before page: SetupPage, needsKey: Bool) -> SetupPage? {
    pages(needsKey: needsKey).last { order(of: $0) < order(of: page) }
  }

  /// Which step of the walk through `page` is, counting from one, and how
  /// many there are, as the page dots show; the model page counts while it
  /// is shown, even once its key is saved.
  public static func step(of page: SetupPage, needsKey: Bool) -> (number: Int, count: Int) {
    let steps = pages(needsKey: needsKey || page == .model)
    return ((steps.firstIndex(of: page) ?? 0) + 1, steps.count)
  }

  private static func order(of page: SetupPage) -> Int {
    SetupPage.allCases.firstIndex(of: page) ?? 0
  }

  /// The footer's buttons: a consent page is answered only while there is no
  /// consent, and otherwise shows Continue in a walk through or Done, as the
  /// last page always does.
  public static func footer(
    on state: SetupState,
    hasConsent: Bool,
    permissionsGranted: Bool
  ) -> SetupFooter {
    if state.page == .consent && !hasConsent { return .answer }
    if state.page == .ready { return .done }
    if state.walksThrough { return .continue }
    return state.page == .consent || permissionsGranted ? .done : .notNow
  }

  /// Where the window is at launch: a launch with no consent walks through
  /// from the consent page whatever `--open` names, since no permission is
  /// asked about before consent; otherwise a named page opens on its own, and
  /// the permissions page when none is named.
  public static func atLaunch(requested: SetupPage?, hasConsent: Bool) -> SetupState {
    guard hasConsent else { return SetupState(page: .consent, walksThrough: true) }
    return SetupState(page: requested ?? .permissions, walksThrough: false)
  }

  /// Where the window is once a page is opened into it: while it shows an
  /// unanswered consent page it stays there, and otherwise it shows the page,
  /// walking through only if an open walk through already was.
  public static func opening(
    _ page: SetupPage,
    from current: SetupState,
    isOpen: Bool,
    hasConsent: Bool
  ) -> SetupState {
    if isOpen && current.page == .consent && !hasConsent { return current }
    return SetupState(page: page, walksThrough: isOpen && current.walksThrough)
  }
}

/// What a walk through's last page says is still to do, so it says Athina is
/// set up only when nothing required is missing.
public struct SetupReadiness: Equatable, Sendable {
  /// The required permissions still off, in `Permission.required` order.
  public let missingPermissions: [Permission]
  /// Whether an API key is still needed: a live run with no key saved.
  public let needsKey: Bool

  /// What is still missing from `permissions`, and whether a key is needed.
  public init(permissions: PermissionStatus, needsKey: Bool) {
    missingPermissions = Permission.required.filter { !permissions.isGranted($0) }
    self.needsKey = needsKey
  }

  /// Whether nothing required is missing.
  public var isSetUp: Bool { missingPermissions.isEmpty && !needsKey }

  /// The page's heading.
  public var heading: String { isSetUp ? "Athina is set up" : "Athina is almost set up" }

  /// A sentence for each thing still to do, empty when nothing is.
  public var stillToDo: [String] {
    var lines: [String] = []
    let titles = missingPermissions.map(\.title)
    if titles.count == 1 {
      lines.append("\(titles[0]) is still off. Allow it from Permissions in the Athina menu.")
    } else if !titles.isEmpty {
      lines.append(
        "\(titles.joined(separator: " and ")) are still off. Allow them from Permissions in the Athina menu."
      )
    }
    if needsKey {
      lines.append("An API key is still needed. Add it in Settings > Models.")
    }
    return lines
  }
}
