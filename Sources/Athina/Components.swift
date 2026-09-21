import SwiftUI

/// A one-line status message: a multicolor system symbol carries the kind,
/// and the words stay in a label color, so a message reads at full contrast
/// in both appearances and never depends on color alone.
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
        Label {
            Text(text)
                .foregroundStyle(kind == .success || kind == .info ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            switch kind {
            case .success:
                Image(systemName: kind.symbol).symbolRenderingMode(.palette).foregroundStyle(.white, .green)
            case .warning:
                Image(systemName: kind.symbol).symbolRenderingMode(.multicolor)
            case .error:
                Image(systemName: kind.symbol).symbolRenderingMode(.palette).foregroundStyle(.white, .red)
            case .info:
                Image(systemName: kind.symbol).foregroundStyle(.secondary)
            }
        }
    }
}

/// A short status word in a capsule, such as Granted or Replay. The tint
/// only colors the capsule; the word stays in the primary label color, and
/// Increase Contrast adds an outline so the capsule keeps its edge.
struct StatusBadge: View {
    @Environment(\.colorSchemeContrast) private var contrast

    let text: String
    let tint: Color
    var symbol: String?

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
