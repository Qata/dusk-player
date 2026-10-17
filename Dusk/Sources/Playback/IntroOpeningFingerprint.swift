import CoreGraphics
import CoreVideo
import Foundation
import UIKit

struct IntroFrameSample: Equatable, Sendable {
    let mediaTime: TimeInterval
    let hash: UInt64
}

struct IntroFingerprintPoint: Codable, Equatable, Sendable {
    let slot: Int
    let hash: UInt64
}

struct IntroOpeningFingerprint: Codable, Equatable, Sendable {
    static let currentAlgorithmVersion = 1

    let algorithmVersion: Int
    let points: [IntroFingerprintPoint]

    init(
        algorithmVersion: Int = currentAlgorithmVersion,
        points: [IntroFingerprintPoint]
    ) {
        self.algorithmVersion = algorithmVersion
        self.points = points.sorted { $0.slot < $1.slot }
    }
}

struct IntroFingerprintSeasonKey: Codable, Hashable, Sendable {
    let serverID: String
    let seasonRatingKey: String

    init(serverID: String, seasonRatingKey: String) {
        self.serverID = serverID
        self.seasonRatingKey = seasonRatingKey
    }

    init?(mediaDetails: PlexMediaDetails) {
        guard mediaDetails.type == .episode,
              let serverID = mediaDetails.serverID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !serverID.isEmpty else {
            return nil
        }

        guard let seasonRatingKey = mediaDetails.parentRatingKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !seasonRatingKey.isEmpty else {
            return nil
        }

        self.serverID = serverID
        self.seasonRatingKey = seasonRatingKey
    }
}

enum IntroFingerprintRecognition: Equatable {
    case incomplete
    case ambiguous
    case firstOccurrence(IntroOpeningFingerprint)
    case repeatOccurrence
}

enum IntroOpeningFingerprintMatcher {
    static let sampleWindow: TimeInterval = 5
    static let minimumSamples = 4
    private static let maximumFrameDistance = 12
    private static let minimumMatchingFrames = 4
    private static let minimumMatchingRatio = 0.75
    private static let ambiguousFrameDistance = 20
    private static let minimumAmbiguousFrames = 3

    static func fingerprint(
        from samples: [IntroFrameSample],
        windowStartTime: TimeInterval
    ) -> IntroOpeningFingerprint? {
        var hashesBySlot: [Int: UInt64] = [:]

        for sample in samples {
            let offset = sample.mediaTime - windowStartTime
            guard offset >= 0, offset < sampleWindow else { continue }
            let slot = Int(offset)
            if hashesBySlot[slot] == nil {
                hashesBySlot[slot] = sample.hash
            }
        }

        let points = hashesBySlot
            .map { IntroFingerprintPoint(slot: $0.key, hash: $0.value) }
            .sorted { $0.slot < $1.slot }
        guard points.count >= minimumSamples else { return nil }
        return IntroOpeningFingerprint(points: points)
    }

    static func recognize(
        _ candidate: IntroOpeningFingerprint?,
        among known: [IntroOpeningFingerprint]
    ) -> IntroFingerprintRecognition {
        guard let candidate,
              candidate.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              candidate.points.count >= minimumSamples else {
            return .incomplete
        }

        var hasAmbiguousComparison = false
        for knownFingerprint in known {
            switch compare(candidate, knownFingerprint) {
            case .match:
                return .repeatOccurrence
            case .ambiguous:
                hasAmbiguousComparison = true
            case .different:
                break
            }
        }
        if hasAmbiguousComparison { return .ambiguous }
        return .firstOccurrence(candidate)
    }

    static func matches(
        _ lhs: IntroOpeningFingerprint,
        _ rhs: IntroOpeningFingerprint
    ) -> Bool {
        compare(lhs, rhs) == .match
    }

    private enum Comparison {
        case different
        case ambiguous
        case match
    }

    private static func compare(
        _ lhs: IntroOpeningFingerprint,
        _ rhs: IntroOpeningFingerprint
    ) -> Comparison {
        guard lhs.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              rhs.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              lhs.points.count >= minimumSamples,
              rhs.points.count >= minimumSamples else {
            return .different
        }

        let rhsBySlot = Dictionary(
            rhs.points.map { ($0.slot, $0.hash) },
            uniquingKeysWith: { first, _ in first }
        )
        var hasAmbiguousAlignment = false
        for slotOffset in -1...1 {
            let distances = lhs.points.compactMap { point -> Int? in
                guard let other = rhsBySlot[point.slot + slotOffset] else { return nil }
                return (point.hash ^ other).nonzeroBitCount
            }
            guard distances.count >= minimumAmbiguousFrames else { continue }
            let closeCount = distances.filter { $0 <= maximumFrameDistance }.count
            let closeRatio = Double(closeCount) / Double(distances.count)
            let averageDistance = Double(distances.reduce(0, +)) / Double(distances.count)
            if closeCount >= minimumMatchingFrames,
               closeRatio >= minimumMatchingRatio,
               averageDistance <= Double(maximumFrameDistance) {
                return .match
            }

            let nearCount = distances.filter { $0 <= ambiguousFrameDistance }.count
            let nearRatio = Double(nearCount) / Double(distances.count)
            let nearAverage = averageDistance <= Double(ambiguousFrameDistance)
            if nearCount >= minimumAmbiguousFrames,
               nearRatio >= minimumMatchingRatio,
               nearAverage {
                hasAmbiguousAlignment = true
            }
        }
        return hasAmbiguousAlignment ? .ambiguous : .different
    }
}

enum IntroFrameHasher {
    private static let width = 9
    private static let height = 8

    static func hash(pixelBuffer: CVPixelBuffer) -> UInt64? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scale = min(
            Double(width) / Double(sourceWidth),
            Double(height) / Double(sourceHeight)
        )
        let drawWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let drawHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))
        let originX = (width - drawWidth) / 2
        let originY = (height - drawHeight) / 2
        let sourcePixels = baseAddress.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)

        for y in 0..<drawHeight {
            let sourceY = min(sourceHeight - 1, Int((Double(y) + 0.5) / scale))
            for x in 0..<drawWidth {
                let sourceX = min(sourceWidth - 1, Int((Double(x) + 0.5) / scale))
                let sourceIndex = sourceY * bytesPerRow + sourceX * 4
                let blue = Double(sourcePixels[sourceIndex])
                let green = Double(sourcePixels[sourceIndex + 1])
                let red = Double(sourcePixels[sourceIndex + 2])
                let gray = UInt8((0.299 * red + 0.587 * green + 0.114 * blue).rounded())
                pixels[(originY + y) * width + originX + x] = gray
            }
        }
        return differenceHash(from: pixels)
    }

    static func hash(image: UIImage) -> UInt64? {
        guard let cgImage = image.cgImage else { return nil }
        return hash(cgImage: cgImage)
    }

    static func hash(cgImage: CGImage) -> UInt64? {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else {
                return false
            }

            context.interpolationQuality = .high
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let scale = min(
                CGFloat(width) / CGFloat(cgImage.width),
                CGFloat(height) / CGFloat(cgImage.height)
            )
            let drawWidth = CGFloat(cgImage.width) * scale
            let drawHeight = CGFloat(cgImage.height) * scale
            context.draw(
                cgImage,
                in: CGRect(
                    x: (CGFloat(width) - drawWidth) / 2,
                    y: (CGFloat(height) - drawHeight) / 2,
                    width: drawWidth,
                    height: drawHeight
                )
            )
            return true
        }
        guard rendered else { return nil }

        return differenceHash(from: pixels)
    }

    private static func differenceHash(from pixels: [UInt8]) -> UInt64? {
        guard pixels.count == width * height,
              let minimum = pixels.min(),
              let maximum = pixels.max(),
              maximum - minimum >= 8 else {
            // Uniform fades and blank frames carry too little information to
            // distinguish openings safely.
            return nil
        }

        var result: UInt64 = 0
        for row in 0..<height {
            for column in 0..<(width - 1) {
                let index = row * width + column
                if pixels[index] > pixels[index + 1] {
                    result |= UInt64(1) << UInt64(row * (width - 1) + column)
                }
            }
        }
        return result
    }
}

@MainActor
final class IntroFingerprintStore {
    static let shared = IntroFingerprintStore(defaults: .standard)

    private static let defaultsKey = "Dusk.IntroOpeningFingerprints"
    private static let schemaVersion = 1

    private struct Record: Codable {
        let key: IntroFingerprintSeasonKey
        let fingerprint: IntroOpeningFingerprint
    }

    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [Record]
    }

    private let defaults: UserDefaults
    private var records: [Record]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let archive = try? JSONDecoder().decode(Archive.self, from: data),
           archive.schemaVersion == Self.schemaVersion {
            records = archive.records.filter {
                $0.fingerprint.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion
            }
        } else {
            records = []
        }
    }

    func fingerprints(for key: IntroFingerprintSeasonKey) -> [IntroOpeningFingerprint] {
        records
            .filter { $0.key == key }
            .map(\.fingerprint)
    }

    func insert(_ fingerprint: IntroOpeningFingerprint, for key: IntroFingerprintSeasonKey) {
        guard fingerprint.algorithmVersion == IntroOpeningFingerprint.currentAlgorithmVersion,
              !records.contains(where: { $0.key == key && $0.fingerprint == fingerprint }) else {
            return
        }
        records.append(Record(key: key, fingerprint: fingerprint))
        persist()
    }

    private func persist() {
        let archive = Archive(schemaVersion: Self.schemaVersion, records: records)
        guard let data = try? JSONEncoder().encode(archive) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
