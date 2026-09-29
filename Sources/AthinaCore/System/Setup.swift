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

  /// The page Continue shows in a walk through, or nil at the last page.
  public static func page(after page: SetupPage) -> SetupPage? {
    let pages = SetupPage.allCases
    guard let index = pages.firstIndex(of: page), index + 1 < pages.count else { return nil }
    return pages[index + 1]
  }

  /// The page Back shows in a walk through, or nil at the first page.
  public static func page(before page: SetupPage) -> SetupPage? {
    let pages = SetupPage.allCases
    guard let index = pages.firstIndex(of: page), index > 0 else { return nil }
    return pages[index - 1]
  }
}
