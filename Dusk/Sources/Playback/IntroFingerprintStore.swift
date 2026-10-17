import Foundation
import OSLog

private let introFingerprintStoreLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "AutoSkipIntro"
)

#if canImport(UIKit)
extension IntroFingerprintSeasonKey {
    init?(mediaDetails: PlexMediaDetails, viewerProfileID: String?) {
        guard mediaDetails.type == .episode,
              let viewer = viewerProfileID?.trimmingCharacters(in: .whitespacesAndNewlines), !viewer.isEmpty,
              let server = mediaDetails.serverID?.trimmingCharacters(in: .whitespacesAndNewlines), !server.isEmpty,
              let season = mediaDetails.parentRatingKey?.trimmingCharacters(in: .whitespacesAndNewlines), !season.isEmpty else { return nil }
        self.init(viewerProfileID: viewer, serverID: server, seasonRatingKey: season)
    }
}
#endif

@MainActor
final class IntroFingerprintStore {
    static let shared = IntroFingerprintStore(defaults: .standard)
    private static let defaultsKey = "Dusk.IntroOpeningFingerprints"
    private static let schemaVersion = 3
    private static let maximumReferencesPerSeason = 16
    private static let maximumArchiveBytes = 2 * 1_024 * 1_024

    private struct Record: Codable {
        let key: IntroFingerprintSeasonKey
        var fingerprint: IntroOpeningFingerprint
        var updatedAt: Date
    }
    private struct Archive: Codable {
        let schemaVersion: Int
        let records: [Record]
    }
    private let defaults: UserDefaults
    private var records: [Record] = []

    init(defaults: UserDefaults) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return }
        guard data.count <= Self.maximumArchiveBytes,
              let archive = try? JSONDecoder().decode(Archive.self, from: data),
              archive.schemaVersion == Self.schemaVersion else {
            introFingerprintStoreLogger.notice("Fingerprint archive ignored: obsolete, invalid, or oversized; openings will be relearned")
            return
        }
        // Validate persisted input as strictly as newly captured observations.
        records = archive.records.filter { $0.fingerprint.isEligibleReference && Self.isOrdered($0.fingerprint.points) }
            .sorted { $0.updatedAt < $1.updatedAt }
        enforceSeasonLimits()
        introFingerprintStoreLogger.notice("Fingerprint archive loaded records=\(self.records.count) bytes=\(data.count)")
    }

    func fingerprints(for key: IntroFingerprintSeasonKey, excluding playbackSessionID: UUID? = nil) -> [IntroOpeningFingerprint] {
        records.filter {
            $0.key == key && $0.fingerprint.playbackSessionID != playbackSessionID
        }.map(\.fingerprint)
    }

    /// Upserts one factual recording, never a blended or transitively merged
    /// prototype. An ambiguous but adequately watched opening remains learnable.
    @discardableResult
    func insert(_ fingerprint: IntroOpeningFingerprint, for key: IntroFingerprintSeasonKey) -> Bool {
        guard fingerprint.isEligibleReference, Self.isOrdered(fingerprint.points),
              !key.viewerProfileID.isEmpty, !key.serverID.isEmpty, !key.seasonRatingKey.isEmpty else { return false }
        if let index = records.firstIndex(where: {
            $0.key == key && $0.fingerprint.observationID == fingerprint.observationID
        }) {
            guard fingerprint.points.count > records[index].fingerprint.points.count else { return true }
            records[index].fingerprint = fingerprint
            records[index].updatedAt = Date()
        } else {
            records.append(Record(key: key, fingerprint: fingerprint, updatedAt: Date()))
        }
        enforceSeasonLimits()
        persist()
        introFingerprintStoreLogger.notice("Fingerprint recording saved episode=\(fingerprint.episodeRatingKey, privacy: .public) observation=\(fingerprint.observationID.uuidString, privacy: .public) points=\(fingerprint.points.count) references=\(self.records.count)")
        return true
    }

    private static func isOrdered(_ points: [IntroFingerprintPoint]) -> Bool {
        zip(points, points.dropFirst()).allSatisfy { $0.time < $1.time }
    }

    private func enforceSeasonLimits() {
        var counts: [IntroFingerprintSeasonKey: Int] = [:]
        records = records.reversed().filter { record in
            let count = counts[record.key, default: 0]
            counts[record.key] = count + 1
            return count < Self.maximumReferencesPerSeason
        }.reversed()
    }

    private func persist() {
        do {
            var data = try JSONEncoder().encode(Archive(schemaVersion: Self.schemaVersion, records: records))
            while data.count > Self.maximumArchiveBytes, !records.isEmpty {
                records.removeFirst()
                data = try JSONEncoder().encode(Archive(schemaVersion: Self.schemaVersion, records: records))
            }
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            introFingerprintStoreLogger.error("Fingerprint archive could not be encoded: \(String(describing: error), privacy: .public)")
        }
    }
}
