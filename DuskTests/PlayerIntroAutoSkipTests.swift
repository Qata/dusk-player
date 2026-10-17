import AVFoundation
import Foundation
import SwiftUI
import Testing
@testable import Dusk

@Suite("Intro auto-skip configuration", .serialized)
@MainActor
struct PlayerIntroAutoSkipTests {
    @Test func repeatOnlyModeFailsOpenWithoutAnOpeningFingerprint() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 73,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let details = try decoder.decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-2","key":"/library/metadata/episode-2","type":"episode","title":"Episode 2","index":2,"parentRatingKey":"season-1"}"#.utf8)
        )
        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details
        )

        // The five-second button countdown is also the fingerprint window.
        // Without enough matching frames, an unknown opening must play through.
        try await Task.sleep(for: .seconds(5.2))
        #expect(engine.seekTargets.isEmpty)
        #expect(engine.introSampleRequestCount > 0)
        #expect(viewModel.resolvedIntroFingerprintMarkerIDs == [marker.id])

        let rebuiltViewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { rebuiltViewModel.cleanup() }
        rebuiltViewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details,
            resolvedIntroFingerprintMarkerIDs: viewModel.resolvedIntroFingerprintMarkerIDs
        )
        #expect(rebuiltViewModel.autoSkipCountdownMarkerID == nil)
    }

    @Test func startupSyncDoesNotArmDefaultModeBeforeOffPreferenceIsApplied() {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .off
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 42,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        // The first timer sync can run before PlayerSessionView applies the
        // saved settings. It must not use PlayerViewModel's default mode.
        viewModel.sync()
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil
        )
        #expect(viewModel.autoSkipIntroMode == .off)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)

        preferences.autoSkipIntroMode = .always
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == marker.id)

        preferences.autoSkipIntroMode = .off
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        #expect(viewModel.autoSkipCountdownMarkerID == nil)
    }

    @Test func repeatOnlyModeDoesNotArmWithoutPlexServerIdentity() throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 76,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let details = try JSONDecoder().decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-4","key":"/library/metadata/episode-4","type":"episode","title":"Episode 4","index":4,"parentRatingKey":"season-1"}"#.utf8)
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details
        )

        #expect(viewModel.autoSkipCountdownMarkerID == nil)
        #expect(engine.introSampleRequestCount == 0)
    }

    @Test func alwaysModeStillSkipsWithoutFingerprintSamples() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .always
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 74,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        let viewModel = PlayerViewModel(engine: engine, markers: [marker])
        defer { viewModel.cleanup() }

        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(preferences: preferences, part: nil)
        try await Task.sleep(for: .seconds(5.2))

        #expect(engine.seekTargets == [20.5])
        #expect(engine.introSampleRequestCount == 0)
    }

    @Test func loadingDoesNotConsumeFirstOpeningBeforeRepeatedOpening() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let firstDetails = try decoder.decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-1","key":"/library/metadata/episode-1","type":"episode","title":"Episode 1","index":1,"parentRatingKey":"season-1"}"#.utf8)
        )
        let secondDetails = try decoder.decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-2","key":"/library/metadata/episode-2","type":"episode","title":"Episode 2","index":2,"parentRatingKey":"season-1"}"#.utf8)
        )
        let suiteName = "IntroFingerprintTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IntroFingerprintStore(defaults: defaults)
        let season = IntroFingerprintSeasonKey(serverID: "plex-a", seasonRatingKey: "season-1")

        let firstMarker = PlexMarker(
            id: 80,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let firstEngine = IntroAutoSkipPlaybackEngine(currentTime: 10, state: .loading)
        firstEngine.introSampleHashes = openingAHashes
        let firstViewModel = PlayerViewModel(
            engine: firstEngine,
            markers: [firstMarker],
            introFingerprintStore: store
        )
        defer { firstViewModel.cleanup() }

        firstViewModel.sync()
        firstViewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: firstDetails
        )
        try #require(firstViewModel.autoSkipCountdownMarkerID == nil)

        firstEngine.state = .playing
        firstViewModel.sync()
        try await Task.sleep(for: .seconds(1))
        let progressBeforeBuffering = firstViewModel.autoSkipCountdownProgress
        let sampleRequestsBeforeBuffering = firstEngine.introSampleRequestCount
        firstEngine.state = .loading
        firstViewModel.sync()
        try await Task.sleep(for: .milliseconds(250))
        #expect(firstViewModel.autoSkipCountdownProgress == progressBeforeBuffering)

        firstEngine.state = .playing
        firstEngine.isBuffering = true
        firstViewModel.sync()
        try await Task.sleep(for: .seconds(1.2))
        #expect(firstViewModel.autoSkipCountdownProgress == progressBeforeBuffering)
        #expect(firstEngine.introSampleRequestCount == sampleRequestsBeforeBuffering)

        firstEngine.isBuffering = false
        firstViewModel.sync()
        try await Task.sleep(for: .seconds(4.2))
        #expect(firstEngine.seekTargets.isEmpty)
        #expect(store.fingerprints(for: season).count == 1)

        let secondMarker = PlexMarker(
            id: 81,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let secondEngine = IntroAutoSkipPlaybackEngine(currentTime: 10, state: .loading)
        secondEngine.introSampleHashes = openingAHashes
        let secondViewModel = PlayerViewModel(
            engine: secondEngine,
            markers: [secondMarker],
            introFingerprintStore: store
        )
        defer { secondViewModel.cleanup() }

        secondViewModel.sync()
        secondViewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: secondDetails
        )
        try #require(secondViewModel.autoSkipCountdownMarkerID == nil)

        secondEngine.state = .playing
        secondViewModel.sync()
        try await Task.sleep(for: .seconds(5.2))
        #expect(secondEngine.seekTargets == [20.5])
    }

    @Test func knownOpeningAutoSkipsAfterTheFingerprintWindow() async throws {
        let preferences = UserPreferences()
        let previousMode = preferences.autoSkipIntroMode
        preferences.autoSkipIntroMode = .alwaysExceptFirstEpisode
        defer { preferences.autoSkipIntroMode = previousMode }

        let marker = PlexMarker(
            id: 75,
            type: "intro",
            startTimeOffset: 5_000,
            endTimeOffset: 20_000
        )
        let decoder = JSONDecoder()
        decoder.userInfo[.duskServerID] = "plex-a"
        let details = try decoder.decode(
            PlexMediaDetails.self,
            from: Data(#"{"ratingKey":"episode-3","key":"/library/metadata/episode-3","type":"episode","title":"Episode 3","index":3,"parentRatingKey":"season-1"}"#.utf8)
        )
        let suiteName = "IntroFingerprintTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IntroFingerprintStore(defaults: defaults)
        let season = IntroFingerprintSeasonKey(serverID: "plex-a", seasonRatingKey: "season-1")
        store.insert(fingerprint(hashes: openingAHashes), for: season)

        let engine = IntroAutoSkipPlaybackEngine(currentTime: 10)
        engine.introSampleHashes = openingAHashes
        let viewModel = PlayerViewModel(
            engine: engine,
            markers: [marker],
            introFingerprintStore: store
        )
        defer { viewModel.cleanup() }

        viewModel.sync()
        viewModel.configureAutomaticTrackSelection(
            preferences: preferences,
            part: nil,
            mediaDetails: details
        )
        try await Task.sleep(for: .seconds(5.2))

        #expect(engine.seekTargets == [20.5])
        #expect(engine.introSampleRequestCount >= 5)
    }

    @Test func matcherAllowsSmallVisualAndTimingDifferences() {
        let openingA = fingerprint(hashes: openingAHashes)
        let shiftedAndNear = IntroOpeningFingerprint(points: openingAHashes.enumerated().map { index, hash in
            IntroFingerprintPoint(slot: index + 1, hash: hash ^ 0x3)
        })
        let openingB = fingerprint(hashes: openingAHashes.map { ~$0 })
        let uncertain = fingerprint(hashes: openingAHashes.enumerated().map { index, hash in
            index == 4 ? ~hash : hash
        })

        #expect(IntroOpeningFingerprintMatcher.matches(openingA, shiftedAndNear))
        #expect(!IntroOpeningFingerprintMatcher.matches(openingA, openingB))
        #expect(IntroOpeningFingerprintMatcher.recognize(uncertain, among: [openingA]) == .ambiguous)
        #expect(IntroOpeningFingerprintMatcher.recognize(nil, among: [openingA]) == .incomplete)
    }

    @Test func repeatedOpeningRecognitionHandlesAABAAcrossASeason() {
        let suiteName = "IntroFingerprintTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = IntroFingerprintStore(defaults: defaults)
        let season = IntroFingerprintSeasonKey(serverID: "plex-a", seasonRatingKey: "season-1")
        let openingA = fingerprint(hashes: openingAHashes)
        let openingB = fingerprint(hashes: openingAHashes.map { ~$0 })
        var wasRepeat: [Bool] = []

        for candidate in [openingA, openingA, openingB, openingA] {
            switch IntroOpeningFingerprintMatcher.recognize(
                candidate,
                among: store.fingerprints(for: season)
            ) {
            case let .firstOccurrence(fingerprint):
                store.insert(fingerprint, for: season)
                wasRepeat.append(false)
            case .repeatOccurrence:
                wasRepeat.append(true)
            case .ambiguous, .incomplete:
                wasRepeat.append(false)
            }
        }

        #expect(wasRepeat == [false, true, false, true])
    }

    @Test func fingerprintCachePersistsAndIsolatesServersAndSeasons() {
        let suiteName = "IntroFingerprintTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let originalSeason = IntroFingerprintSeasonKey(serverID: "plex-a", seasonRatingKey: "season-1")
        let anotherSeason = IntroFingerprintSeasonKey(serverID: "plex-a", seasonRatingKey: "season-2")
        let anotherServer = IntroFingerprintSeasonKey(serverID: "plex-b", seasonRatingKey: "season-1")
        let openingA = fingerprint(hashes: openingAHashes)

        IntroFingerprintStore(defaults: defaults).insert(openingA, for: originalSeason)
        let reloadedStore = IntroFingerprintStore(defaults: defaults)

        #expect(reloadedStore.fingerprints(for: originalSeason) == [openingA])
        #expect(reloadedStore.fingerprints(for: anotherSeason).isEmpty)
        #expect(reloadedStore.fingerprints(for: anotherServer).isEmpty)
    }

    @Test func repeatOnlyPreferenceKeepsItsStoredValueAndNewLabel() {
        #expect(AutoSkipIntroMode(rawValue: "alwaysExceptFirstEpisode") == .alwaysExceptFirstEpisode)
        #expect(AutoSkipIntroMode.alwaysExceptFirstEpisode.displayName == "Skip Repeated Intros")
    }
}

private let openingAHashes: [UInt64] = [
    0x0123_4567_89ab_cdef,
    0x1357_9bdf_2468_ace0,
    0xfedc_ba98_7654_3210,
    0x0f0f_f0f0_0ff0_0f0f,
    0x5555_aaaa_3333_cccc,
]

private func fingerprint(hashes: [UInt64]) -> IntroOpeningFingerprint {
    IntroOpeningFingerprint(points: hashes.enumerated().map { index, hash in
        IntroFingerprintPoint(slot: index, hash: hash)
    })
}

@MainActor
private final class IntroAutoSkipPlaybackEngine: PlaybackEngine {
    var state: PlaybackState
    let currentTime: TimeInterval
    let duration: TimeInterval = 120
    var isBuffering = false
    let error: PlaybackError? = nil
    let videoEnhancementStatus = VideoEnhancementStatus.disabled
    var onPlaybackEnded: (@MainActor () -> Void)?
    let availableSubtitleTracks: [SubtitleTrack] = []
    let availableAudioTracks: [AudioTrack] = []
    let selectedSubtitleTrackID: Int? = nil
    let selectedAudioTrackID: Int? = nil
    private let player = AVPlayer()
    private(set) var seekTargets: [TimeInterval] = []
    private(set) var introSampleRequestCount = 0
    var introSampleHashes: [UInt64]?
    private var introSampleHandler: (@MainActor (IntroFrameSample) -> Void)?

    var playbackCoordinator: AVPlaybackCoordinator { player.playbackCoordinator }

    init(currentTime: TimeInterval, state: PlaybackState = .playing) {
        self.currentTime = currentTime
        self.state = state
    }

    func load(source: PlaybackSource) {}
    func configureVideoEnhancement(_ request: VideoEnhancementRequest) {}
    func setIntroFrameSampleHandler(_ handler: (@MainActor (IntroFrameSample) -> Void)?) {
        introSampleHandler = handler
    }
    func requestIntroFrameSample() {
        introSampleRequestCount += 1
        guard let introSampleHashes,
              !introSampleHashes.isEmpty,
              let introSampleHandler else {
            return
        }
        let mediaTime = currentTime + Double(introSampleRequestCount - 1) * 0.8
        let slot = min(
            introSampleHashes.count - 1,
            Int(mediaTime - currentTime)
        )
        introSampleHandler(
            IntroFrameSample(mediaTime: mediaTime, hash: introSampleHashes[slot])
        )
    }
    func play() {}
    func pause() {}
    func stop() {}
    func seek(to position: TimeInterval) { seekTargets.append(position) }
    func setPlaybackRate(_ rate: Float) {}
    func configureCoordinatedPlayback(itemIdentifier: String?) {}
    func recoverFromStall() {}
    func handleReturnToForeground() {}
    func selectSubtitleTrack(_ track: SubtitleTrack?) {}
    func selectAudioTrack(_ track: AudioTrack) {}
    func makePlayerView() -> AnyView { AnyView(EmptyView()) }
}
