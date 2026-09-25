import Foundation
import Testing

@testable import AthinaCore

/// `MenuBarMark.resolve` over every sensing mode and every mentor
/// availability: the single decision for which variant of the mark the menu
/// bar shows.
@Suite struct MenuBarMarkTests {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private var availabilities: [MentorStatus.Availability] {
    [.ready, .disabled, .noAPIKey, .capReached(until: t0 + 3600)]
  }

  private func mark(
    _ mode: SensingMode,
    _ availability: MentorStatus.Availability = .ready,
    offline: Bool = false
  ) -> MenuBarMark {
    MenuBarMark.resolve(mode: mode, availability: availability, offline: offline)
  }

  /// A mode that is not sensing says so whatever the mentor tier could do,
  /// because nothing is being captured to advise about.
  @Test func aModeThatIsNotWatchingOutranksAvailability() {
    for availability in availabilities {
      #expect(mark(.paused, availability) == .paused)
      #expect(mark(.stopped, availability) == .paused)
      #expect(mark(.idle, availability) == .idle)
      #expect(mark(.excluded, availability) == .excluded)
      #expect(mark(.waitingForPermissions, availability) == .needsSomething)
    }
  }

  /// Every mode that senses reads the same way, so a missing permission
  /// degrades what Athina can see without changing what the menu bar says
  /// about whether it is working.
  @Test(arguments: [SensingMode.watching, .screenOnly, .accessibilityOnly])
  func theSensingModesAgreeWithEachOther(mode: SensingMode) {
    #expect(mark(mode, .ready) == .watching)
    #expect(mark(mode, .noAPIKey) == .needsSomething)
    #expect(mark(mode, .disabled) == .held)
    #expect(mark(mode, .capReached(until: t0 + 3600)) == .held)
  }

  /// The two states the user can fix read as one: a missing permission and a
  /// missing key both mean Athina needs something before it can work.
  @Test func whatTheUserMustFixReadsAsNeedsSomething() {
    #expect(mark(.waitingForPermissions) == .needsSomething)
    #expect(mark(.watching, .noAPIKey) == .needsSomething)
  }

  /// Off in Settings and a reached spend cap both leave sensing running
  /// while no advice comes, which is what held says.
  @Test func whatClearsWithoutTheUserReadsAsHeld() {
    #expect(mark(.watching, .disabled) == .held)
    #expect(mark(.watching, .capReached(until: t0 + 3600)) == .held)
  }

  /// A replay has no live availability to report, so the sensing modes read
  /// as plain watching and the word beside the icon does the rest. A
  /// recording is not offline, so it keeps the live reading.
  @Test func offlineCallsNeverReadAsNeedsSomethingOrHeld() {
    for availability in availabilities {
      for mode in [SensingMode.watching, .screenOnly, .accessibilityOnly] {
        #expect(mark(mode, availability, offline: true) == .watching)
      }
    }
    // A mode that is not sensing still says so in a replay.
    #expect(mark(.paused, .ready, offline: true) == .paused)
    #expect(mark(.excluded, .ready, offline: true) == .excluded)
  }

  /// Every sensing mode resolves, so a mode added later cannot fall through
  /// without a variant of the mark to show for it.
  @Test func everySensingModeResolves() {
    for mode in SensingMode.allCases {
      for availability in availabilities {
        for offline in [false, true] {
          _ = MenuBarMark.resolve(mode: mode, availability: availability, offline: offline)
        }
      }
    }
    // And every variant is reachable, so none is dead.
    var seen = Set<MenuBarMark>()
    for mode in SensingMode.allCases {
      for availability in availabilities {
        seen.insert(MenuBarMark.resolve(mode: mode, availability: availability, offline: false))
      }
    }
    #expect(seen == Set(MenuBarMark.allCases))
  }
}
