import SwiftUI

struct AlbumSongListView: View {
    @State private var artworkScope = UUID()
    let album: Album
    @Environment(PlaybackManager.self) private var playback

    private var songs: [Song] {
        album.songs.sorted { $0.track < $1.track }
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    AlbumArtworkView(album: album, size: .full, cornerRadius: 10)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 200)
                        .frame(maxWidth: .infinity)
                    Text(album.name)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    if let artistName = album.artist?.name {
                        Text(artistName)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Spacer(minLength: 0)
                        Button {
                            playback.play(songs: songs)
                        } label: {
                            // Built as an explicit HStack rather than a `Label`: inside a List,
                            // Label picks up the list's label styling, which reserves a
                            // fixed-width icon column and aligns the title against it — the
                            // icon reads as invisible and the text sits off-centre in the pill.
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                Text("Play Album")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }

            Section {
                ForEach(songs) { song in
                    SongRowView(song: song, isCurrent: playback.isCurrent(song))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Tapping one song plays it — jumping to it if it's already queued,
                            // appending it if not. Only "Play Album" replaces the queue.
                            playback.playNow(song)
                        }
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerContentInset()
        .navigationTitle(album.name)
        .navigationBarTitleDisplayMode(.inline)
        .artworkScope(artworkScope)
    }
}
