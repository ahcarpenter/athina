import CoreGraphics
import Foundation
import ScreenCaptureKit

/// A downscaled capture of one display.
public struct CapturedFrame: @unchecked Sendable {
  public let image: CGImage
  public let displayID: CGDirectDisplayID
  /// The display's bounds in global display coordinates.
  public let screenRect: CGRect
}

public enum ScreenCaptureError: Error, CustomStringConvertible {
  case noDisplays
  case captureFailed(String)

  public var description: String {
    switch self {
    case .noDisplays: "no displays available to capture"
    case .captureFailed(let message): message
    }
  }
}

/// Captures the display containing the focused window with ScreenCaptureKit,
/// excluding Athina's own windows so the debug panel never captures itself.
public actor ScreenCapturer {
  private var content: SCShareableContent?
  /// The window server's list changes in real time, so it is cached for
  /// real seconds whatever clock the rest of the app runs on (`AthinaClock`).
  private var contentFetchedAt: Date = .distantPast
  private let contentMaxAge: TimeInterval = 30

  public init() {}

  public func capture(windowFrame: CGRect?, maxDimension: Int) async throws -> CapturedFrame {
    let content = try await shareableContent()
    guard let display = ScreenCapturer.display(for: windowFrame, in: content.displays) else {
      throw ScreenCaptureError.noDisplays
    }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let ownApps = content.applications.filter { $0.processID == ownPID }
    let filter = SCContentFilter(
      display: display,
      excludingApplications: ownApps,
      exceptingWindows: []
    )

    let configuration = SCStreamConfiguration()
    let target = FrameImaging.boundedSize(for: display.frame.size, maxDimension: maxDimension)
    configuration.width = Int(target.width)
    configuration.height = Int(target.height)
    configuration.showsCursor = false
    configuration.captureResolution = .automatic
    configuration.pixelFormat = kCVPixelFormatType_32BGRA

    do {
      let image = try await SCScreenshotManager.captureImage(
        contentFilter: filter,
        configuration: configuration
      )
      return CapturedFrame(image: image, displayID: display.displayID, screenRect: display.frame)
    } catch {
      // Stale display lists throw; refetch once and let the next capture retry.
      self.content = nil
      throw ScreenCaptureError.captureFailed(error.localizedDescription)
    }
  }

  private func shareableContent() async throws -> SCShareableContent {
    if let content, Date().timeIntervalSince(contentFetchedAt) < contentMaxAge {
      return content
    }
    let fresh = try await SCShareableContent.excludingDesktopWindows(
      true,
      onScreenWindowsOnly: true
    )
    content = fresh
    contentFetchedAt = Date()
    return fresh
  }

  /// Picks the display overlapping the window most, falling back to the main display.
  static func display(for windowFrame: CGRect?, in displays: [SCDisplay]) -> SCDisplay? {
    guard !displays.isEmpty else { return nil }
    if let windowFrame {
      let best = displays.max { a, b in
        a.frame.intersection(windowFrame).area < b.frame.intersection(windowFrame).area
      }
      if let best, best.frame.intersection(windowFrame).area > 0 {
        return best
      }
    }
    let mainID = CGMainDisplayID()
    return displays.first { $0.displayID == mainID } ?? displays.first
  }
}

extension CGRect {
  var area: CGFloat {
    isNull || isEmpty ? 0 : width * height
  }
}
