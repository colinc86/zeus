import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import Vision

/// CGImage is immutable; ownership never crosses a mutable drawing context.
struct CapturedScreenFrame: @unchecked Sendable { let image: CGImage }
struct CoveredScreenFrame: Sendable {
    let frame: Redacted<FrameItem>
    let text: String
    let lineCount: Int
}
enum ScreenCaptureError: Error { case unavailable, sensitive, encoding, invalidImage }
protocol ScreenFrameRedacting: Sendable {
    func redact(_ frame: CapturedScreenFrame, context: ScreenContext) async throws -> CoveredScreenFrame
    func redact(_ frame: CapturedScreenFrame, context: ScreenContext, coverPictures: Bool) async throws -> CoveredScreenFrame
}
extension ScreenFrameRedacting {
    func redact(_ frame: CapturedScreenFrame, context: ScreenContext, coverPictures: Bool) async throws -> CoveredScreenFrame {
        try await redact(frame, context: context)
    }
}
/// Vision and image processing run off the main actor. Raw pixels/OCR exist only during this call.
actor FrameRedactor: ScreenFrameRedacting {
    private let redactor: any Redactor
    private var warmed = false
    init(redactor: any Redactor) { self.redactor = redactor }
    /// Hydrates Vision with generated pixels after consent, without reading a screen.
    func prewarm() {
        guard !warmed else { return }; warmed = true
        guard let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage() else { return }
        _ = try? Self.textLines(image)
    }
    static func textLines(_ image: CGImage) throws -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
    }
    func redact(_ captured: CapturedScreenFrame, context: ScreenContext) async throws -> CoveredScreenFrame {
        try await redact(captured, context: context, coverPictures: true)
    }
    func redact(_ captured: CapturedScreenFrame, context: ScreenContext, coverPictures: Bool) async throws -> CoveredScreenFrame {
        let image = captured.image
        guard image.width > 0, image.height > 0, image.width <= 1600, image.height <= 1600 else { throw ScreenCaptureError.invalidImage }
        let lines = try Self.textLines(image)
        let text = lines.map(\.0).joined(separator: "\n")
        if Self.isSensitiveDialog(title: context.windowTitle, text: text) { throw ScreenCaptureError.sensitive }
        // One batch redacts every OCR line and the metadata; both stages run before bytes are retained.
        var fields = Dictionary(uniqueKeysWithValues: lines.enumerated().map { ("line_\($0.offset)", $0.element.0) })
        fields["window"] = context.windowTitle; fields["app"] = context.appName
        let safe = await redactor.redact(JournalPayload(description: "", details: fields))
        try Task.checkCancellation()
        var boxes: [FrameBox] = [], coveredText: [String] = []
        var report = safe.report
        // Titles are stored beside the preview and may contain the same account hints as pixels.
        func coveredMetadata(_ value: String) -> String {
            guard Self.hasAccountHint(value) else { return value }
            report.counts[.finance, default: 0] += 1
            return "‹finance›"
        }
        let appName = safe.value.details["app"] ?? "App"
        let windowTitle = coveredMetadata(safe.value.details["window"] ?? "")
        let width = Double(image.width), height = Double(image.height)
        for (index, line) in lines.enumerated() {
            let result = safe.value.details["line_\(index)"] ?? "‹redacted›"
            // Account hints and money on screenshots need covering even when the prose model is unavailable.
            let sensitive = result != line.0 || Self.hasAccountHint(line.0)
            coveredText.append(sensitive ? "‹redacted›" : result)
            if (sensitive && coverPictures) || Self.mandatoryCover(original: line.0, redacted: result) {
                if result == line.0 { report.counts[.finance, default: 0] += 1 }
                boxes.append(Self.box(line.1, kind: .text, paddingX: 5 / width, paddingY: 5 / height))
            }
        }
        if coverPictures {
        let pictures = VNGenerateObjectnessBasedSaliencyImageRequest()
        try VNImageRequestHandler(cgImage: image).perform([pictures])
        for rect in pictures.results?.first?.salientObjects ?? [] {
            if rect.boundingBox.width * width > 48 && rect.boundingBox.height * height > 48 {
                boxes.append(Self.box(rect.boundingBox, kind: .picture))
            }
        }
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image).perform([faces])
        for face in faces.results ?? [] {
            boxes.append(Self.box(face.boundingBox, kind: .face,
                                  paddingX: face.boundingBox.width * 0.25, paddingY: face.boundingBox.height * 0.25))
        }
        }
        let covered = try Self.cover(image, boxes: boxes)
        let bytes = try Self.heic(covered)
        return CoveredScreenFrame(frame: .init(FrameItem(heic: bytes, width: image.width, height: image.height, boxes: boxes,
            appName: appName, windowTitle: windowTitle), report: report),
            text: coveredText.joined(separator: "\n"), lineCount: lines.count)
    }
    static func mandatoryCover(original: String, redacted: String) -> Bool {
        let mandatory: Set<RedactionKind> = [.secret, .card, .iban, .identity]
        return mandatory.contains { redacted.contains($0.placeholder) }
            || LocalRedactor.patternSpans(original).contains { mandatory.contains($0.kind) }
    }
    static func isSensitiveDialog(title: String, text: String) -> Bool {
        let source = (title + "\n" + text).lowercased()
        return ["enter your password", "enter password", "unlock keychain", "keychain access", "password required", "authentication required"].contains { source.contains($0) }
    }
    static func hasAccountHint(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(account|acct|iban|ending|routing|sort code|balance)\b.{0,40}\d|[$€£]\s*\d[\d,.]*"#, options: .regularExpression) != nil
    }
    private static func box(_ rect: CGRect, kind: FrameBox.Kind, paddingX: Double = 0, paddingY: Double = 0) -> FrameBox {
        let x = max(0, rect.minX - paddingX), y = max(0, 1 - rect.maxY - paddingY)
        return .init(x: x, y: y, width: min(1 - x, rect.width + paddingX * 2), height: min(1 - y, rect.height + paddingY * 2), kind: kind)
    }
    static func cover(_ image: CGImage, boxes: [FrameBox]) throws -> CGImage {
        let base = CIImage(cgImage: image), ci = CIContext(options: [.cacheIntermediates: false])
        var output = base
        // Pictures first, then solid text: a picture operation can never restore a covered text line.
        for box in boxes.sorted(by: { ($0.kind == .text ? 1 : 0) < ($1.kind == .text ? 1 : 0) }) {
            let rect = CGRect(x: box.x * Double(image.width), y: (1 - box.y - box.height) * Double(image.height),
                              width: box.width * Double(image.width), height: box.height * Double(image.height)).integral.intersection(base.extent)
            let patch: CIImage
            if box.kind == .text {
                patch = CIImage(color: CIColor(red: 0.42, green: 0.42, blue: 0.42)).cropped(to: rect)
            } else {
                let filter = CIFilter.pixellate(); filter.inputImage = output.clampedToExtent()
                filter.scale = Float(max(20, min(rect.width, rect.height) / 6)); filter.center = CGPoint(x: rect.midX, y: rect.midY)
                guard let pixels = filter.outputImage else { throw ScreenCaptureError.encoding }
                patch = pixels.cropped(to: rect)
            }
            output = patch.composited(over: output)
        }
        guard let result = ci.createCGImage(output, from: base.extent) else { throw ScreenCaptureError.encoding }
        return result
    }
    static func heic(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.heic.identifier as CFString, 1, nil) else { throw ScreenCaptureError.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenCaptureError.encoding }
        return data as Data
    }
}

struct ScreenFingerprint: Sendable {
    let hash: UInt64
    let pixels: [UInt8]
    init(image: CGImage) throws {
        func gray(_ width: Int, _ height: Int) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height)
            let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium; context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height)); return true
            }
            guard success else { throw ScreenCaptureError.invalidImage }; return bytes
        }
        pixels = try gray(64, 40)
        let small = try gray(9, 8)
        var value: UInt64 = 0
        for y in 0..<8 { for x in 0..<8 { value = (value << 1) | (small[y * 9 + x] < small[y * 9 + x + 1] ? 1 : 0) } }
        hash = value
    }
    func isUnchanged(from other: Self) -> Bool {
        (hash ^ other.hash).nonzeroBitCount <= 2 &&
        Double(zip(pixels, other.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / 2560 < 0.3
    }
}

protocol CoveredFrameReading: Sendable {
    func read(_ frame: Redacted<FrameItem>) async throws -> CoveredScreenFrame
}
/// Deferred descriptions decode only the covered encrypted-preview result, off the main actor.
actor CoveredFrameReader: CoveredFrameReading {
    func read(_ frame: Redacted<FrameItem>) async throws -> CoveredScreenFrame {
        guard let source = CGImageSourceCreateWithData(frame.value.heic as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScreenCaptureError.encoding }
        let lines = try FrameRedactor.textLines(image)
        return CoveredScreenFrame(frame: frame, text: lines.map(\.0).joined(separator: "\n"), lineCount: lines.count)
    }
}
