import AVFoundation
import Foundation
@preconcurrency import LiveKitWebRTC
import os

private nonisolated let cloudAudioSessionLog = Logger(
    subsystem: "com.owenselles.CloudNow2",
    category: "CloudAudioSession"
)

/// The playback audio-session shape, shared by `CloudAudioSessionCoordinator` and
/// `CloudAudioDevice`. With the "AirPlay audio" setting on, the session declares long-form
/// audio: tvOS only routes apps that do to AirPlay 2 speakers. That route buffers about two
/// seconds and can't record, so the microphone stays off while it's set.
nonisolated enum CloudPlaybackAudioSession {
    static let airPlayDefaultsKey = "cloudAudio.airPlayAudio"

    static var prefersAirPlay: Bool {
        UserDefaults.standard.bool(forKey: airPlayDefaultsKey)
    }

    static var routeSharingPolicy: AVAudioSession.RouteSharingPolicy {
        prefersAirPlay ? .longFormAudio : .default
    }

    static func apply(to session: AVAudioSession) throws {
        try session.setCategory(
            .playback,
            mode: .default,
            policy: routeSharingPolicy,
            options: []
        )
    }

    static func isApplied(to session: AVAudioSession) -> Bool {
        session.category == .playback
            && session.mode == .default
            && session.routeSharingPolicy == routeSharingPolicy
    }
}

/// Provider-neutral owner of the audio-session and microphone negotiation
/// policy shared by native cloud-stream transports. It deliberately matches
/// GFN's current permission, category, mode, buffer, and track constraints.
@MainActor
final class CloudAudioSessionCoordinator {
    struct MicrophoneAttachment {
        let source: LKRTCAudioSource
        let track: LKRTCAudioTrack
    }

    func requestMicrophonePermission(if requested: Bool) async -> Bool {
        if requested, CloudPlaybackAudioSession.prefersAirPlay {
            cloudAudioSessionLog.info("AirPlay audio is on; microphone stays off")
            return false
        }
        guard CloudMicrophoneRoutePolicy.shouldRequestPermission(
            microphoneEnabled: requested
        ) else { return false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        if !granted {
            cloudAudioSessionLog.warning(
                "Microphone permission denied; using playback-only audio"
            )
        }
        return granted
    }

    /// Returns whether a physical capture route is ready now. Authorization
    /// remains valid when this is false: CloudAudioDevice retains recording
    /// intent and automatically rebuilds capture after route restoration.
    @discardableResult
    func configure(microphoneAuthorized: Bool) -> Bool {
        let session = AVAudioSession.sharedInstance()
        if microphoneAuthorized,
           !CloudPlaybackAudioSession.prefersAirPlay,
           session.availableCategories.contains(.playAndRecord)
        {
            do {
                try session.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.allowBluetoothHFP, .allowBluetoothA2DP]
                )
                try session.setPreferredIOBufferDuration(0.01)
                try session.setActive(true)
                let routePolicy = CloudMicrophoneRoutePolicy(
                    hasCaptureIntent: true,
                    hasUsableInputRoute: session.isInputAvailable
                        && !session.currentRoute.inputs.isEmpty
                        && session.inputNumberOfChannels > 0
                )
                guard routePolicy.audioPath == .playbackAndCapture else {
                    cloudAudioSessionLog.info(
                        "Microphone authorized; capture deferred until an input route appears"
                    )
                    return configurePlayback(session)
                }
                return true
            } catch {
                cloudAudioSessionLog.warning(
                    "Microphone audio-session configuration failed; falling back to playback: \(error, privacy: .private)"
                )
            }
        }
        return configurePlayback(session)
    }

    func attachMicrophone(
        to peerConnection: LKRTCPeerConnection
    ) -> MicrophoneAttachment? {
        let constraints = LKRTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: [
                "googEchoCancellation": "false",
                "googAutoGainControl": "false",
                "googNoiseSuppression": "false",
            ]
        )
        let source = CloudRTCRuntime.peerConnectionFactory.audioSource(
            with: constraints
        )
        let track = CloudRTCRuntime.peerConnectionFactory.audioTrack(
            with: source,
            trackId: "mic"
        )
        guard peerConnection.add(track, streamIds: ["mic"]) != nil else {
            cloudAudioSessionLog.warning(
                "Unable to attach microphone track; continuing without microphone"
            )
            return nil
        }
        return MicrophoneAttachment(source: source, track: track)
    }

    @discardableResult
    func configurePlayback() -> Bool {
        configurePlayback(.sharedInstance())
    }

    private func configurePlayback(_ session: AVAudioSession) -> Bool {
        do {
            try CloudPlaybackAudioSession.apply(to: session)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            cloudAudioSessionLog.error(
                "Playback audio-session configuration failed: \(error, privacy: .private)"
            )
        }
        return false
    }
}
