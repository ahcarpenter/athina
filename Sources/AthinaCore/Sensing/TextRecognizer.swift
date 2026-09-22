import CoreGraphics
import Foundation
import Vision

/// On-device OCR with the Vision framework.
public struct TextRecognizer: Sendable {
    public init() {}

    /// Recognizes text in the frame and maps each block to global display coordinates.
    public func recognize(_ frame: CapturedFrame, level: OCRLevel) async throws -> [TextBlock] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level == .fast ? .fast : .accurate
        request.usesLanguageCorrection = level == .accurate
        request.automaticallyDetectsLanguage = true

        let image = frame.image
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = frame.screenRect.width / imageSize.width
        let observations = try await request.perform(on: image)

        return observations.compactMap { observation -> TextBlock? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let imageRect = observation.boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)
            let screenRect = CGRect(
                x: frame.screenRect.origin.x + imageRect.origin.x * scale,
                y: frame.screenRect.origin.y + imageRect.origin.y * scale,
                width: imageRect.width * scale,
                height: imageRect.height * scale
            )
            return TextBlock(text: text, confidence: candidate.confidence, imageRect: imageRect, screenRect: screenRect)
        }
    }
}
