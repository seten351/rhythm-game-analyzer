import AppKit
import CoreImage
import CryptoKit
import ImageIO
import Vision
import ResultCore

struct ImageAnalysis {
    var result: ResultDraft?
    var settings: PlaySettings?
    var preview: CGImage
    var sha256: String
    var evidence: [OCRReadEvidence] = []
    var screenshotDateCandidates: [ScreenshotDateCandidate] = []
}

enum ImageAnalyzer {
    static func analyze(data: Data, preset: GamePreset, knownTitles: [String], filename: String? = nil) throws -> ImageAnalysis {
        try preset.validate()
        guard data.count <= 80 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any], let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0, width <= 20000, height <= 20000 else { throw CoreError.invalid("画像が破損しているか、大きすぎます（80MB・最大辺20000pxまで）。") }
        // Decode only a bounded thumbnail. This also applies EXIF orientation, without writing a file.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2800, kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw CoreError.invalid("画像を読み込めませんでした。") }
        let ratio = Double(image.width) / Double(image.height)
        guard abs(ratio / preset.aspectRatio - 1) <= preset.aspectTolerance else { throw CoreError.invalid("この画像の縦横比はプリセットに未対応です。提供画面と同じ配置のスクショを選んでください。") }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let screenshotDates = ScreenshotDateReader.read(properties: properties, metadata: CGImageSourceCopyMetadataAtIndex(source, 0, nil), filename: filename)
        var fields: [String: [OCRToken]] = [:]
        var evidence: [OCRReadEvidence] = []
        func read(_ key: String, numeric: Bool = false) throws -> [OCRToken] {
            let output = try recognizeWithEvidence(image, rect: preset.regions[key]!, customWords: knownTitles, numeric: numeric, sourceID: digest, fieldKey: key)
            evidence += output.evidence
            return output.tokens
        }
        for key in ["settingsMarker", "title", "timingHeader"] { fields[key] = try read(key) }
        let marker = (fields["settingsMarker"] ?? []).map(\.text).joined()
        if marker.contains("オプション") {
            for key in ["noteSpeed", "noteTiming", "chartPosition", "mirror"] { fields[key] = try recognize(image, rect: preset.regions[key]!, customWords: [], numeric: key != "mirror") }
            let settings = OurNotesParser.settings(fields: fields)
            guard settings.isComplete else { throw CoreError.invalid("設定値をすべて読み取れませんでした。設定画面から手入力できます。") }
            return ImageAnalysis(result: nil, settings: settings, preview: image, sha256: digest, screenshotDateCandidates: screenshotDates)
        }
        // Require actual result labels rather than interpreting arbitrary same-aspect images as results.
        let anchors = try recognize(image, rect: .init(x: 0.50, y: 0.30, width: 0.19, height: 0.08), customWords: []) + recognize(image, rect: .init(x: 0.51, y: 0.51, width: 0.095, height: 0.09), customWords: [])
        let anchorText = anchors.map(\.text).joined().uppercased()
        guard anchorText.contains("SCORE") && (anchorText.contains("PERFECT") || anchorText.contains("GREAT")) else { throw CoreError.invalid("対応するリザルト画面を確認できませんでした。") }
        let detailed = (fields["timingHeader"] ?? []).map(\.text).joined().uppercased().contains("FAST") && (fields["timingHeader"] ?? []).map(\.text).joined().uppercased().contains("SLOW")
        let contextualNumbers = try recognizeContextualNumbers(image, customWords: knownTitles)
        // Keep the judgment labels in the crop. Vision can rotate an isolated 6/9
        // mentally; neighboring text supplies its baseline without changing pixels.
        let panelNumbers = try recognizeContextualNumbers(image, customWords: [], rect: .init(x: 0.505, y: 0.48, width: 0.30, height: 0.255))
        let keys = ["difficulty", "score", "combo", "achievement"] + Judgment.allCases.flatMap { detailed ? [$0.rawValue + ".fast", $0.rawValue + ".slow"] : [$0.rawValue + ".total"] }
        for key in keys {
            let numeric = key == "score" || key == "combo" || key.contains(".")
            let region = preset.regions[key]!
            fields[key] = try read(key, numeric: numeric)
            if numeric {
                for (route, numbers) in [("context", contextualNumbers), ("judgment-panel", panelNumbers)] {
                    let contextual = numbers.filter { token in
                        let x = token.rect.x + token.rect.width / 2, y = token.rect.y + token.rect.height / 2
                        return x >= region.x && x <= region.x + region.width && y >= region.y && y <= region.y + region.height
                    }
                    if contextual.count == 1 {
                        if fields[key]?.isEmpty == true { fields[key] = contextual }
                        evidence.append(.init(sourceID: digest, fieldKey: key, route: route, observations: contextual.map { [$0] }))
                    }
                }
            }
        }
        let hash = perceptualHash(image, rect: .init(x: 0.51, y: 0.28, width: 0.46, height: 0.46))
        let fingerprint = SourceFingerprint(sha256: digest, perceptualHash: hash, layout: detailed ? "detail" : "normal")
        return ImageAnalysis(result: OurNotesParser.result(fields: fields, preset: preset, fingerprint: fingerprint, knownTitles: knownTitles, evidence: evidence), settings: nil, preview: image, sha256: digest, evidence: evidence, screenshotDateCandidates: screenshotDates)
    }

    static func recognizeContextualNumbers(_ image: CGImage, customWords: [String], rect: ResultCore.NormalizedRect = .init(x: 0, y: 0, width: 1, height: 1)) throws -> [OCRToken] {
        guard let cropped = image.cropping(to: CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height), width: rect.width * Double(image.width), height: rect.height * Double(image.height)).integral) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLanguages = ["ja-JP", "en-US"]; request.customWords = customWords
        try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
        let expression = try NSRegularExpression(pattern: "[0-9]+(?:,[0-9]+)*")
        let modeLabels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        guard !OurNotesParser.hasAssistModeLabel(modeLabels) else { throw CoreError.invalid("アシストモードは対応対象外です。") }
        return (request.results ?? []).flatMap { observation -> [OCRToken] in
            guard let candidate = observation.topCandidates(1).first else { return [] }
            let text = candidate.string
            return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let range = Range(match.range, in: text), let box = try? candidate.boundingBox(for: range) else { return nil }
                let b = box.boundingBox
                return OCRToken(text: String(text[range]), confidence: Double(candidate.confidence), rect: .init(x: rect.x + b.minX * rect.width, y: rect.y + (1 - b.maxY) * rect.height, width: b.width * rect.width, height: b.height * rect.height))
            }
        }
    }

    static func recognize(_ image: CGImage, rect: ResultCore.NormalizedRect, customWords: [String], numeric: Bool = false) throws -> [OCRToken] {
        try recognizeWithEvidence(image, rect: rect, customWords: customWords, numeric: numeric, sourceID: "", fieldKey: "").tokens
    }

    private struct FieldRead {
        var tokens: [OCRToken]
        var evidence: [OCRReadEvidence]
    }
    private static func recognizeWithEvidence(_ image: CGImage, rect: ResultCore.NormalizedRect, customWords: [String], numeric: Bool, sourceID: String, fieldKey: String) throws -> FieldRead {
        guard let cropped = image.cropping(to: CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height), width: rect.width * Double(image.width), height: rect.height * Double(image.height)).integral) else {
            return .init(tokens: [], evidence: [.init(sourceID: sourceID, fieldKey: fieldKey, route: "region", observations: [])])
        }
        // Give small single-digit regions enough resolution for Vision's detector.
        let scale = max(1, min(4, 110 / Double(cropped.height)))
        let ci = CIImage(cgImage: cropped).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        let enlarged = context.createCGImage(ci, from: ci.extent) ?? cropped
        func run(_ input: CGImage, route: String) throws -> FieldRead {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.revision = VNRecognizeTextRequestRevision3
            request.recognitionLanguages = numeric ? ["en-US"] : ["ja-JP", "en-US"]
            request.usesLanguageCorrection = !numeric
            request.customWords = numeric ? [] : Array(Set(customWords)).prefix(1000).map { $0 }
            request.minimumTextHeight = 0.03
            try VNImageRequestHandler(cgImage: input, options: [:]).perform([request])
            let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }.map { observation in
                observation.topCandidates(3).map { candidate in OCRToken(text: candidate.string, confidence: Double(candidate.confidence), rect: rect) }
            }
            let evidence = OCRReadEvidence(sourceID: sourceID, fieldKey: fieldKey, route: route, observations: observations)
            return .init(tokens: evidence.bestTokens, evidence: [evidence])
        }
        let original = try run(enlarged, route: "region")
        let field = fieldKey == "difficulty" ? OCRField.level : OCRField(rawValue: fieldKey)
        let retrySixNine = field.map { OCRCorrectionService.shouldRetrySixNine(for: $0, in: original.evidence) || !OCRCorrectionService.sixNineCandidates(for: $0, in: original.evidence).isEmpty } ?? false
        if (!numeric && !retrySixNine) || (!retrySixNine && !original.tokens.isEmpty && original.tokens.allSatisfy({ token in token.text.allSatisfy { $0.isNumber || $0 == "." || $0 == "-" || $0 == "," } })) { return original }
        // Some isolated zeros are rejected as noise. Retry the actual pixels in grayscale,
        // inverted and padded; a missing glyph is never replaced with an inferred zero.
        let inverted = CIImage(cgImage: enlarged).applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.5]).applyingFilter("CIColorInvert")
        guard let monochrome = context.createCGImage(inverted, from: inverted.extent) else { return original }
        let padding = 35, w = monochrome.width + padding * 2, h = monochrome.height + padding * 2
        guard let pad = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return original }
        pad.setFillColor(CGColor(gray: 1, alpha: 1)); pad.fill(CGRect(x: 0, y: 0, width: w, height: h)); pad.draw(monochrome, in: CGRect(x: padding, y: padding, width: monochrome.width, height: monochrome.height))
        guard let padded = pad.makeImage() else { return original }
        let retried = try run(padded, route: "inverted-padded")
        // A 6/9 retry adds evidence for review, never silently replaces the provisional value.
        return .init(tokens: retrySixNine || retried.tokens.isEmpty ? original.tokens : retried.tokens, evidence: original.evidence + retried.evidence)
    }

    static func perceptualHash(_ image: CGImage, rect: ResultCore.NormalizedRect) -> UInt64? {
        guard let cropped = image.cropping(to: CGRect(x: rect.x * Double(image.width), y: rect.y * Double(image.height), width: rect.width * Double(image.width), height: rect.height * Double(image.height)).integral) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 72)
        var hash: UInt64 = 0
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 9, height: 8, bitsPerComponent: 8, bytesPerRow: 9, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high; context.draw(cropped, in: CGRect(x: 0, y: 0, width: 9, height: 8)); return true
        }
        guard success else { return nil }
        for y in 0..<8 { for x in 0..<8 { if bytes[y * 9 + x] > bytes[y * 9 + x + 1] { hash |= UInt64(1) << (y * 8 + x) } } }
        return hash
    }
}
