import Testing

@testable import AthinaCore

@Suite struct SetupFlowTests {
  /// A missing permission comes next after Allow whether or not a first launch
  /// is walking through, as the Permissions window always opened after Allow.
  @Test func aMissingPermissionAlwaysComesNextAfterAllow() {
    for walksThrough in [true, false] {
      for needsKey in [true, false] {
        #expect(
          SetupFlow.afterAllow(
            walksThrough: walksThrough,
            permissionsGranted: false,
            needsKey: needsKey
          )
            == .permissions
        )
      }
    }
  }

  @Test func onlyAWalkThroughGoesOnToTheModelForAKey() {
    #expect(
      SetupFlow.afterAllow(walksThrough: true, permissionsGranted: true, needsKey: true) == .model
    )
    #expect(
      SetupFlow.afterAllow(walksThrough: false, permissionsGranted: true, needsKey: true) == nil
    )
  }

  /// With every permission granted and no key needed, as in a hermetic replay,
  /// Allow closes the window, as it always has.
  @Test func allowClosesTheWindowWhenNothingIsLeft() {
    for walksThrough in [true, false] {
      #expect(
        SetupFlow.afterAllow(walksThrough: walksThrough, permissionsGranted: true, needsKey: false)
          == nil
      )
    }
  }

  @Test func continueAndBackStepThroughThePagesInOrder() {
    #expect(SetupFlow.page(after: .consent, needsKey: true) == .permissions)
    #expect(SetupFlow.page(after: .permissions, needsKey: true) == .model)
    #expect(SetupFlow.page(after: .model, needsKey: true) == .ready)
    #expect(SetupFlow.page(after: .ready, needsKey: true) == nil)
    #expect(SetupFlow.page(before: .consent) == nil)
    #expect(SetupFlow.page(before: .ready) == .model)
  }

  /// Continue skips the model page exactly when Allow does: when no key is
  /// still needed.
  @Test func continueSkipsTheModelPageAsAllowDoes() {
    for needsKey in [true, false] {
      let afterContinue = SetupFlow.page(after: .permissions, needsKey: needsKey)
      let afterAllow = SetupFlow.afterAllow(
        walksThrough: true,
        permissionsGranted: true,
        needsKey: needsKey
      )
      #expect(afterContinue == (needsKey ? .model : .ready))
      #expect((afterContinue == .model) == (afterAllow == .model))
    }
    #expect(SetupFlow.page(after: .consent, needsKey: false) == .permissions)
  }

  /// A launch with no consent walks through from the consent page even when
  /// `--open` names another page, since no permission is asked about first.
  @Test func aLaunchWithNoConsentStartsOnTheConsentPage() {
    for requested in [nil] + SetupPage.allCases.map(Optional.some) {
      #expect(
        SetupFlow.atLaunch(requested: requested, hasConsent: false)
          == SetupState(page: .consent, walksThrough: true)
      )
    }
    #expect(
      SetupFlow.atLaunch(requested: .model, hasConsent: true)
        == SetupState(page: .model, walksThrough: false)
    )
    #expect(
      SetupFlow.atLaunch(requested: nil, hasConsent: true)
        == SetupState(page: .permissions, walksThrough: false)
    )
  }

  /// Opening any page into a window that shows an unanswered consent page
  /// keeps it there, walking through or not.
  @Test func anUnansweredConsentPageIsNeverReplaced() {
    for walksThrough in [true, false] {
      let consent = SetupState(page: .consent, walksThrough: walksThrough)
      for page in SetupPage.allCases {
        #expect(
          SetupFlow.opening(page, from: consent, isOpen: true, hasConsent: false) == consent
        )
      }
    }
  }

  @Test func openingAPageKeepsAnOpenWalkThroughGoing() {
    let walk = SetupState(page: .model, walksThrough: true)
    #expect(
      SetupFlow.opening(.consent, from: walk, isOpen: true, hasConsent: false)
        == SetupState(page: .consent, walksThrough: true)
    )
    #expect(
      SetupFlow.opening(.permissions, from: walk, isOpen: false, hasConsent: true)
        == SetupState(page: .permissions, walksThrough: false)
    )
    let answered = SetupState(page: .consent, walksThrough: true)
    #expect(
      SetupFlow.opening(.permissions, from: answered, isOpen: true, hasConsent: true)
        == SetupState(page: .permissions, walksThrough: true)
    )
  }

  /// A consent page for a provider that already has consent is never
  /// answered again: Continue in a walk through, Done on its own.
  @Test func anAnsweredConsentPageOnlyMovesOnOrCloses() {
    for granted in [true, false] {
      #expect(
        SetupFlow.footer(
          on: SetupState(page: .consent, walksThrough: true),
          hasConsent: true,
          permissionsGranted: granted
        ) == .continue
      )
      #expect(
        SetupFlow.footer(
          on: SetupState(page: .consent, walksThrough: false),
          hasConsent: true,
          permissionsGranted: granted
        ) == .done
      )
      for walksThrough in [true, false] {
        #expect(
          SetupFlow.footer(
            on: SetupState(page: .consent, walksThrough: walksThrough),
            hasConsent: false,
            permissionsGranted: granted
          ) == .answer
        )
      }
    }
    #expect(
      SetupFlow.footer(
        on: SetupState(page: .permissions, walksThrough: false),
        hasConsent: true,
        permissionsGranted: false
      ) == .notNow
    )
    #expect(
      SetupFlow.footer(
        on: SetupState(page: .ready, walksThrough: true),
        hasConsent: true,
        permissionsGranted: false
      ) == .done
    )
  }

  /// The last page says Athina is set up only when nothing required is
  /// missing, and otherwise names what is still to do and where.
  @Test func theReadyPageSaysWhatIsStillMissing() {
    let granted = PermissionStatus(screenRecording: true, accessibility: true)
    let ready = SetupReadiness(permissions: granted, needsKey: false)
    #expect(ready.isSetUp)
    #expect(ready.heading == "Athina is set up")
    #expect(ready.stillToDo.isEmpty)

    let noScreen = SetupReadiness(
      permissions: PermissionStatus(screenRecording: false, accessibility: true, microphone: true),
      needsKey: false
    )
    #expect(!noScreen.isSetUp)
    #expect(noScreen.heading != "Athina is set up")
    #expect(
      noScreen.stillToDo == [
        "Screen Recording is still off. Allow it from the menu's Permissions…."
      ]
    )

    let nothing = SetupReadiness(
      permissions: PermissionStatus(screenRecording: false, accessibility: false),
      needsKey: true
    )
    #expect(
      nothing.stillToDo == [
        "Screen Recording and Accessibility are still off. Allow them from the menu's Permissions….",
        "An API key is still needed. Add it in Settings > Models.",
      ]
    )

    let noKey = SetupReadiness(permissions: granted, needsKey: true)
    #expect(!noKey.isSetUp)
    #expect(noKey.stillToDo == ["An API key is still needed. Add it in Settings > Models."])
  }

  /// Only the required pair counts: the voice pair is optional.
  @Test func theVoicePermissionsAreNotMissing() {
    let readiness = SetupReadiness(
      permissions: PermissionStatus(screenRecording: true, accessibility: true),
      needsKey: false
    )
    #expect(readiness.isSetUp)
  }

  /// The consent page keeps the title the consent window had, and each page has
  /// its own, so the window's title always says where the person is.
  @Test func eachPageHasItsOwnTitle() {
    #expect(SetupPage.consent.title == "Athina and Your Privacy")
    #expect(Set(SetupPage.allCases.map(\.title)).count == SetupPage.allCases.count)
  }
}
