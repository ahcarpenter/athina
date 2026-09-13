import Foundation

/// Pure retention arithmetic, kept apart from the database so it can be tested directly.
public struct RetentionPolicy: Equatable, Sendable {
    public var thumbnailMaxAge: TimeInterval
    public var textMaxAge: TimeInterval
    public var sizeCapBytes: Int64

    /// After a size-cap sweep the journal is trimmed to this fraction of the
    /// cap so the sweep does not run again on the very next write.
    public static let sizeCapTargetFraction = 0.8

    public init(thumbnailMaxAge: TimeInterval, textMaxAge: TimeInterval, sizeCapBytes: Int64) {
        self.thumbnailMaxAge = thumbnailMaxAge
        self.textMaxAge = textMaxAge
        self.sizeCapBytes = sizeCapBytes
    }

    public init(settings: SensingSettings) {
        self.init(
            thumbnailMaxAge: settings.thumbnailRetention,
            textMaxAge: settings.textRetention,
            sizeCapBytes: settings.journalSizeCapBytes
        )
    }

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

public struct RetentionResult: Equatable, Sendable {
    public var thumbnailsDeleted: Int
    public var observationsDeleted: Int
    public var eventsDeleted: Int
    public var bytesBefore: Int64
    public var bytesAfter: Int64

    public init(thumbnailsDeleted: Int = 0, observationsDeleted: Int = 0, eventsDeleted: Int = 0, bytesBefore: Int64 = 0, bytesAfter: Int64 = 0) {
        self.thumbnailsDeleted = thumbnailsDeleted
        self.observationsDeleted = observationsDeleted
        self.eventsDeleted = eventsDeleted
        self.bytesBefore = bytesBefore
        self.bytesAfter = bytesAfter
    }

    public var deletedAnything: Bool {
        thumbnailsDeleted + observationsDeleted + eventsDeleted > 0
    }
}
