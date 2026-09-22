import Testing
@testable import AthinaCore

@Suite struct PluralTests {
    @Test func onlyExactlyOneTakesTheSingular() {
        #expect(Plural.count(0, "call", "calls") == "0 calls")
        #expect(Plural.count(1, "call", "calls") == "1 call")
        #expect(Plural.count(2, "call", "calls") == "2 calls")
        #expect(Plural.count(1234, "entry", "entries") == "1234 entries")
    }
}
