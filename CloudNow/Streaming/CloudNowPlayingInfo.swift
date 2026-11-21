import MediaPlayer
import UIKit

/// tvOS Now Playing (Control Center, the audio-route picker) for the game being streamed:
/// its title, the service, and its box art. Apps playing long-form audio (the AirPlay Audio
/// setting) are expected to publish it, and it names the stream on any audio route.
/// tvOS only treats an app as the Now Playing app (what Control Center and Home Assistant's Apple
/// TV integration show) once it handles a remote command. Only Stop is handled: the remote's
/// Play/Pause press opens the stream overlay (VideoSurfaceView), and the Siri Remote has no Stop
/// button. Stop does nothing; a stream ends from its own menu.
@MainActor
enum CloudNowPlayingInfo {
    private static var artworkTask: Task<Void, Never>?
    private static var stopTarget: Any?

    static func publish(title: String, service: String, artworkURL: URL?) {
        stopTarget = stopTarget ?? addStopTarget()
        artworkTask?.cancel()
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: service,
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
        center.playbackState = .playing

        guard let artworkURL else { return }
        artworkTask = Task {
            guard let (data, _) = try? await URLSession.shared.data(from: artworkURL),
                  let image = UIImage(data: data),
                  !Task.isCancelled
            else { return }
            info[MPMediaItemPropertyArtwork] = artwork(for: image)
            center.nowPlayingInfo = info
        }
    }

    static func clear() {
        artworkTask?.cancel()
        artworkTask = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        if let stopTarget {
            MPRemoteCommandCenter.shared().stopCommand.removeTarget(stopTarget)
        }
        stopTarget = nil
    }

    /// MediaPlayer may call command handlers off the main thread, so this one isn't main-actor
    /// isolated either.
    private nonisolated static func addStopTarget() -> Any {
        MPRemoteCommandCenter.shared().stopCommand.addTarget { _ in .success }
    }

    /// MediaPlayer asks for the image on its own queue, so the handler must not be
    /// main-actor isolated.
    private nonisolated static func artwork(for image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
