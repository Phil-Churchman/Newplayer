import SwiftUI

struct NowPlayingView: View {
    @State private var artworkScope = UUID()
    @Environment(PlaybackManager.self) private var playback
    let onDismiss: () -> Void

    @State private var isSeeking = false
    @State private var seekValue: TimeInterval = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if playback.isHostSyncingDatabase {
                    HostSyncingView()
                } else if let item = playback.nowPlayingItem {
                    // `nowPlayingItem`, not `currentSong`: in Spotify mode the track playing may
                    // have no library row, and reading the library-backed queue left this screen
                    // showing the last track the app itself started.
                    NowPlayingArtworkView(item: item, size: .full, cornerRadius: 12)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 4) {
                        Text(item.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        Text(item.artist)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 4) {
                        Slider(
                            value: Binding(
                                get: { isSeeking ? seekValue : playback.currentTime },
                                set: { seekValue = $0 }
                            ),
                            in: 0...max(playback.duration, 1),
                            onEditingChanged: { editing in
                                isSeeking = editing
                                if !editing {
                                    playback.seek(to: seekValue)
                                }
                            }
                        )
                        HStack {
                            Text(DurationFormatter.format(isSeeking ? seekValue : playback.currentTime))
                            Spacer()
                            Text(DurationFormatter.format(playback.duration))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 48) {
                        Button {
                            playback.skipToPrevious()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.title)
                        }
                        Button {
                            playback.togglePlayPause()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 64))
                        }
                        Button {
                            playback.skipToNext()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.title)
                        }
                    }
                } else {
                    ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                }
                if let playbackErrorMessage = playback.playbackErrorMessage {
                    Text(playbackErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .padding(.top, 32)
            // Applied once to the column rather than to each child: per-child insets are how the
            // artwork, the track bar and the title ended up on three different left edges.
            .padding(.horizontal, LayoutMetrics.horizontalPadding)
            .frame(maxWidth: LayoutMetrics.maxPlayerWidth)
            // Fills the rest of the width so the capped column sits centred rather than hard
            // against the leading edge on an iPad.
            .frame(maxWidth: .infinity)
            .artworkScope(artworkScope)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                }
            }
            // Presented as a full-screen cover, so this screen sits outside the TabView and
            // doesn't get the persistent bars the tabs share — add the source indicator here
            // so it's consistent with every other view.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ActiveSourceBar()
            }
        }
    }
}
