import AppKit
import Foundation
import SwiftUI

/// Tells VoiceOver about a change it would otherwise miss: a result that
/// arrives after the control that asked for it, a warning that appears beside
/// a field, a window Athina shows without taking focus.
///
/// Every announcement goes through here. `.medium` queues behind what
/// VoiceOver is saying, for news nobody was waiting for; `.high` interrupts,
/// only for the answer to something the person just asked.
@MainActor
enum Announce {
  /// Where a run serving the control API logs each announcement, so a
  /// scenario can wait on it (`ControlEventLog`); nil otherwise.
  static var recorder: ((String, NSAccessibilityPriorityLevel) -> Void)?

  static func post(_ text: String, priority: NSAccessibilityPriorityLevel = .medium) {
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [.announcement: text, .priority: priority.rawValue]
    )
    recorder?(text, priority)
  }
}

extension NSAccessibilityPriorityLevel {
  /// The level as the control API's `announcement` events name it.
  var name: String {
    switch self {
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    @unknown default: "unknown"
    }
  }
}

/// What a status color means, mapped once to a system color, so one hue never
/// stands for two unrelated things.
///
/// The words beside it always carry the meaning too (`StatusLabel`,
/// `StatusBadge`); the tint only reinforces it.
enum StatusTint {
  /// Working as it should: granted, allowed, watching, ready.
  case good
  /// Needs the person: a permission, a key, an answer, time until a limit
  /// lifts, or a look at something that stopped.
  case attention
  /// A state the person chose, or one that is simply quiet: an answer given,
  /// paused, idle, excluded, off.
  case neutral
  /// Live right now: the microphone listening, calls being recorded. Red, as
  /// a recording light is.
  case active

  var color: Color {
    switch self {
    case .good: .green
    case .attention: .orange
    case .neutral: .gray
    case .active: .red
    }
  }
}

/// A one-line status message: a multicolor system symbol carries the kind,
/// and the words stay in the primary label color, so a message reads at full
/// contrast in both appearances and never depends on color alone.
struct StatusLabel: View {
  enum Kind {
    case success
    case warning
    case error
    case info

    var symbol: String {
      switch self {
      case .success: "checkmark.circle.fill"
      case .warning: "exclamationmark.triangle.fill"
      case .error: "xmark.octagon.fill"
      case .info: "info.circle"
      }
    }
  }

  let text: String
  let kind: Kind

  init(_ text: String, kind: Kind) {
    self.text = text
    self.kind = kind
  }

  var body: some View {
    Label(
      title: {
        Text(text)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)
      },
      icon: {
        switch kind {
        case .success:
          Image(systemName: kind.symbol).symbolRenderingMode(.palette).foregroundStyle(
            .white,
            .green
          )
        case .warning:
          Image(systemName: kind.symbol).symbolRenderingMode(.multicolor)
        case .error:
          Image(systemName: kind.symbol).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
        case .info:
          Image(systemName: kind.symbol).foregroundStyle(.secondary)
        }
      }
    )
  }
}

/// A short status word in a capsule, such as Granted or Replay.
///
/// The tint colors the capsule and the symbol, if any; the word stays in the
/// primary label color, and Increase Contrast adds an outline so the capsule
/// keeps its edge.
struct StatusBadge: View {
  @Environment(\.colorSchemeContrast)
  private var contrast

  let text: String
  let tint: Color
  var symbol: String?

  init(text: String, tint: Color, symbol: String? = nil) {
    self.text = text
    self.tint = tint
    self.symbol = symbol
  }

  init(text: String, status: StatusTint, symbol: String? = nil) {
    self.init(text: text, tint: status.color, symbol: symbol)
  }

  var body: some View {
    HStack(spacing: 4) {
      if let symbol {
        Image(systemName: symbol)
          .imageScale(.small)
          .foregroundStyle(tint)
          .accessibilityHidden(true)
      }
      Text(text)
    }
    .font(.caption.weight(.medium))
    .foregroundStyle(.primary)
    .padding(.horizontal, 7)
    .padding(.vertical, 2)
    .background(tint.opacity(0.18), in: Capsule())
    .overlay {
      if contrast == .increased {
        Capsule().strokeBorder(tint)
      }
    }
    .fixedSize()
  }
}

extension EnvironmentValues {
  /// True in a snapshot render: a view that would keep moving on its own,
  /// such as a pulsing symbol or a readout that redraws every second, draws
  /// once and at rest, so every render of it is the same picture.
  @Entry var drawsStill = false
}

/// Content that redraws once a second, for ages and times read off the
/// app's clock; once only in a snapshot render, which must not redraw between
/// the captures it compares.
struct EverySecond<Content: View>: View {
  @ViewBuilder let content: () -> Content

  @Environment(\.drawsStill)
  private var drawsStill

  var body: some View {
    TimelineView(SecondTicks(once: drawsStill)) { _ in content() }
  }

  private struct SecondTicks: TimelineSchedule {
    let once: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
      var next: Date? = startDate
      return AnyIterator {
        defer { next = once ? nil : next?.addingTimeInterval(1) }
        return next
      }
    }
  }
}
