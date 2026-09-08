import SwiftUI

struct QueueView: View {
    @State private var artworkScope = UUID()
    @State private var showingClearConfirmation = false
    @Environment(PlaybackManager.self) private var playback

    var body: some View {
        Group {
            if playback.isSpotifySource {
                // Spotify mode always shows Spotify's queue, never the library-backed one —
                // even while it is empty. Falling back on emptiness meant a momentary gap after
                // a context change dropped the screen to the other list, which in this mode holds
                // nothing, so the queue appeared to vanish.
                List {
                    ForEach(Array(playback.spotifyQueue.enumerated()), id: \.offset) { position, entry in
                        SpotifyQueueRowView(entry: entry, isCurrent: position == 0)
                            .onTapGesture {
                                playback.playSpotifyQueueEntry(at: position)
                            }
                    }
                }
                .listStyle(.plain)
                .miniPlayerContentInset()
            } else if playback.queue.isEmpty {
                ContentUnavailableView(
                    "Queue is Empty",
                    systemImage: "list.bullet",
                    description: Text("Play a song or album to build a queue.")
                )
            } else {
                List {
                    // Identity is the queue *position*, not the song: the same track can sit in
                    // several slots (tapping a song appends it again), and keying by the song's
                    // persistent ID gives duplicate ForEach ids and undefined rendering. Every
                    // operation here is position-addressed anyway — jumpTo(index:), remove(at:).
                    ForEach(Array(playback.queue.enumerated()), id: \.offset) { index, song in
                        QueueRowView(song: song, isCurrent: index == playback.currentIndex)
                            .onTapGesture {
                                playback.jumpTo(index: index)
                            }
                    }
                    .onDelete { offsets in
                        for index in offsets.sorted(by: >) {
                            playback.remove(at: index)
                        }
                    }
                }
                .listStyle(.plain)
                .miniPlayerContentInset()
            }
        }
        .navigationTitle("Queue")
        // Spotify owns its queue: it can be played from, but not reordered or emptied from here,
        // because Connect offers no way to do either.
        .artworkScope(artworkScope)
        .toolbar {
            if !playback.queue.isEmpty, !playback.isSpotifySource {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        showingClearConfirmation = true
                    } label: {
                        Label("Clear Queue", systemImage: "trash")
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear the queue?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Stop and Clear Queue", role: .destructive) {
                playback.clearQueue()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This stops playback and removes every track from the queue.")
        }
    }
}
