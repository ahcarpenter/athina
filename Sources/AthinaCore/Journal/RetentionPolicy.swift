import Foundation

/// Pure retention arithmetic, kept apart from the database so it can be tested directly.
public struct RetentionPolicy: Equatable, Sendable {
  /// How long a thumbnail is kept, in seconds.
  public var thumbnailMaxAge: TimeInterval
  /// How long observations, events, suggestions, follow-ups, model calls, and
  /// the understanding are kept, in seconds.
  public var textMaxAge: TimeInterval
  /// The journal size, in bytes, past which the oldest thumbnails and then
  /// the oldest observations and events are deleted.
  public var sizeCapBytes: Int64

  /// After a size-cap sweep the journal is trimmed to this fraction of the
  /// cap so the sweep does not run again on the very next write.
  public static let sizeCapTargetFraction = 0.8

  /// Creates a policy from its two ages and the size cap.
  public init(thumbnailMaxAge: TimeInterval, textMaxAge: TimeInterval, sizeCapBytes: Int64) {
    self.thumbnailMaxAge = thumbnailMaxAge
    self.textMaxAge = textMaxAge
    self.sizeCapBytes = sizeCapBytes
  }

  /// Creates the policy the owner's sensing settings ask for.
  public init(settings: SensingSettings) {
    self.init(
      thumbnailMaxAge: settings.thumbnailRetention,
      textMaxAge: settings.textRetention,
      sizeCapBytes: settings.journalSizeCapBytes
    )
  }

  /// Returns the time before which thumbnails are deleted.
  public func thumbnailCutoff(now: Date) -> Date {
    now.addingTimeInterval(-thumbnailMaxAge)
  }

  /// Text never outlives thumbnails' cutoff in the wrong direction: the text
  /// cutoff is at least as old as the thumbnail cutoff.
  public func textCutoff(now: Date) -> Date {
    now.addingTimeInterval(-max(textMaxAge, thumbnailMaxAge))
  }

  /// Size the journal should be trimmed to once it goes over the cap.
  public var sizeTargetBytes: Int64 {
    Int64(Double(sizeCapBytes) * RetentionPolicy.sizeCapTargetFraction)
  }
}

/// What one retention pass deleted, and the journal's size before and after.
public struct RetentionResult: Equatable, Sendable {
  /// The number of thumbnails deleted, by age or by the size cap.
  public var thumbnailsDeleted: Int
  /// The number of observations deleted, by age or by the size cap.
  public var observationsDeleted: Int
  /// The number of events deleted, by age or by the size cap.
  public var eventsDeleted: Int
  /// The number of suggestions deleted by age.
  public var suggestionsDeleted: Int
  /// The number of follow-ups deleted by age.
  public var followUpsDeleted: Int
  /// The number of model call records deleted by age.
  public var modelCallsDeleted: Int
  /// The number of understanding rows deleted, by age or by the size cap.
  public var understandingDeleted: Int
  /// Bytes in use by the journal's live pages before the pass.
  public var bytesBefore: Int64
  /// Bytes in use by the journal's live pages after the pass.
  public var bytesAfter: Int64

  /// Creates a result from its counts and sizes; each defaults to zero.
  public init(
    thumbnailsDeleted: Int = 0,
    observationsDeleted: Int = 0,
    eventsDeleted: Int = 0,
    suggestionsDeleted: Int = 0,
    followUpsDeleted: Int = 0,
    modelCallsDeleted: Int = 0,
    understandingDeleted: Int = 0,
    bytesBefore: Int64 = 0,
    bytesAfter: Int64 = 0
  ) {
    self.thumbnailsDeleted = thumbnailsDeleted
    self.observationsDeleted = observationsDeleted
    self.eventsDeleted = eventsDeleted
    self.suggestionsDeleted = suggestionsDeleted
    self.followUpsDeleted = followUpsDeleted
    self.modelCallsDeleted = modelCallsDeleted
    self.understandingDeleted = understandingDeleted
    self.bytesBefore = bytesBefore
    self.bytesAfter = bytesAfter
  }

  /// Whether the pass deleted any row of any kind.
  public var deletedAnything: Bool {
    thumbnailsDeleted + observationsDeleted + eventsDeleted + suggestionsDeleted + followUpsDeleted
      + modelCallsDeleted + understandingDeleted > 0
  }
}
