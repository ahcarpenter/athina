import Synchronization

/// The newest suggestion id journaled before the one `MentorLoop` is
/// journaling or holding, or nil when none is: the same value as
/// `MentorStatus.holdsSuggestionsAfter`, set before the row is written, so
/// a list can read it the moment the row reaches it.
public final class SuggestionFloor: Sendable {
  private let after = Mutex<Int64?>(nil)

  /// Creates a floor that holds nothing back.
  public init() {}

  /// The floor now; a later suggestion with no feedback is not listed yet.
  public var value: Int64? { after.withLock { $0 } }

  func set(_ value: Int64?) { after.withLock { $0 = value } }
}
