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
    #expect(SetupFlow.page(after: .consent) == .permissions)
    #expect(SetupFlow.page(after: .permissions) == .model)
    #expect(SetupFlow.page(after: .model) == .ready)
    #expect(SetupFlow.page(after: .ready) == nil)
    #expect(SetupFlow.page(before: .consent) == nil)
    #expect(SetupFlow.page(before: .ready) == .model)
  }

  /// The consent page keeps the title the consent window had, and each page has
  /// its own, so the window's title always says where the person is.
  @Test func eachPageHasItsOwnTitle() {
    #expect(SetupPage.consent.title == "Athina and Your Privacy")
    #expect(Set(SetupPage.allCases.map(\.title)).count == SetupPage.allCases.count)
  }
}
