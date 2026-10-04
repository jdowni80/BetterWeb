import AVKit
import SwiftUI

/// Native playback for video pages Servo can't play, docked above the page.
struct MediaPlayerPanel: View {
    @ObservedObject var session: MediaSession

    var body: some View {
        ZStack {
            Color.black
            NativePlayerView(player: session.player)
                .opacity(session.phase == .ready ? 1 : 0)

            switch session.phase {
            case .resolving:
                ZStack {
                    if let thumb = session.media?.thumbnail ?? Self.thumbnail(for: session.videoID) {
                        AsyncImage(url: URL(string: thumb)) { image in
                            image.resizable().aspectRatio(contentMode: .fit)
                        } placeholder: {
                            Color.black
                        }
                        .opacity(0.45)
                    }
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Loading video…")
                            .font(.system(size: 12))
                            .foregroundStyle(ApheleiaTheme.textSecondary)
                    }
                }
            case .failed(let message):
                VStack(spacing: 10) {
                    Image(systemName: "play.slash")
                        .font(.system(size: 26))
                        .foregroundStyle(ApheleiaTheme.textMuted)
                    Text("This video couldn't be played")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ApheleiaTheme.textPrimary)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(ApheleiaTheme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .frame(maxWidth: 460)
                        .textSelection(.enabled)
                    Button(action: session.retry) {
                        Text("Try again")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14)
                            .frame(height: 30)
                    }
                    .buttonStyle(AccentButtonStyle())
                }
                .padding(20)
            case .ready:
                EmptyView()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(ApheleiaTheme.border).frame(height: 1)
        }
    }

    private static func thumbnail(for videoID: String) -> String? {
        "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg"
    }
}

private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.showsFullScreenToggleButton = true
        view.updatesNowPlayingInfoCenter = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
