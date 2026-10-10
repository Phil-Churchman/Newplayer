import SwiftData
import SwiftUI
import UIKit

struct SourcesView: View {
    @Query private var sources: [Source]
    @Environment(\.modelContext) private var modelContext
    @Environment(PlaybackManager.self) private var playback
    @StateObject private var viewModel = SourcesViewModel()
    @State private var isPickerPresented = false
    @State private var hostInput = ""
    @State private var portInput = "6600"

    // One source at a time. The switches are an exclusive choice rather than four independent
    // ones: turning a source on is choosing it, which is the same act as turning the others off.
    // Kept per *kind* so a source can be chosen before it has a row — before a folder is picked,
    // a host entered, or Spotify signed into.
    @AppStorage("selectedSourceKind") private var selectedSourceKindRaw: Int = -1

    private var selectedKind: SourceKind? {
        selectedSourceKindRaw == -1 ? nil : SourceKind(rawValue: selectedSourceKindRaw)
    }

    /// Turning one on selects it and deselects the rest; turning it off leaves nothing selected.
    private func selectionBinding(for kind: SourceKind) -> Binding<Bool> {
        Binding(
            get: { selectedKind == kind },
            set: { isOn in
                let newKind: SourceKind? = isOn ? kind : nil
                SourceSelection.select(newKind, among: sources, modelContext: modelContext)
                selectedSourceKindRaw = newKind?.rawValue ?? -1
                // Switching *into* Spotify mode is one of the two moments this phone should be
                // brought into Spotify's device list — the other is Refresh Devices. Done here
                // rather than when the screen appears, because appearing says nothing about
                // which mode the user is in: this screen shows a Spotify source whenever one
                // exists, so activating on appearance woke Spotify in MPD mode too.
                if newKind == .spotify, let spotifySource {
                    viewModel.loadSpotifyDevices(source: spotifySource, activatingThisPhone: true)
                }
            }
        )
    }

    private var showLocal: Bool { selectedKind == .local }
    private var showMediaLibrary: Bool { selectedKind == .mediaLibrary }
    private var showNetwork: Bool { selectedKind == .network }
    private var showSpotify: Bool { selectedKind == .spotify }
    @State private var spotifyClientIDInput = ""
    /// Seeded from the stored id, so re-authorizing normally needs no typing — but correctable
    /// in place when the stored id is what Spotify is rejecting.
    @State private var reauthorizeClientIDInput = ""
    @State private var infoTopic: SourceInfoTopic?

    private var localSource: Source? {
        sources.first { $0.kind == .local }
    }

    private var networkSource: Source? {
        sources.first { $0.kind == .network }
    }

    private var mediaLibrarySource: Source? {
        sources.first { $0.kind == .mediaLibrary }
    }

    private var spotifySource: Source? {
        sources.first { $0.kind == .spotify }
    }

    /// Writes the choice through to the source and to the player in one place, so the picker
    /// can't end up showing something the player isn't using.
    private func spotifyDeviceBinding(for source: Source) -> Binding<String?> {
        Binding(
            get: { source.spotifyDeviceID },
            set: { newValue in
                viewModel.selectSpotifyDevice(newValue, source: source, modelContext: modelContext)
                playback.selectSpotifyDevice(id: newValue)
                // Re-read afterwards: the transfer changes which device Spotify reports as
                // active, and the picker should show what is actually true.
                viewModel.loadSpotifyDevices(source: source)
            }
        )
    }

    private var serverSyncInProgress: Bool {
        viewModel.serverSyncPhase != .idle
    }

    /// Only ever "in progress" or nothing — the sync runs on the server, so there is no state
    /// in which the app can report it as interrupted or needing a restart.
    private var serverSyncStatusText: String? {
        switch viewModel.serverSyncPhase {
        case .idle: return nil
        case .requested: return "Asking the server to sync…"
        case .syncing: return "Server is rescanning its music directory…"
        case .refreshingLibrary:
            if let progress = viewModel.syncProgress {
                return "Refreshing this app's copy of the library… \(progress.processed) / \(progress.total) tracks"
            }
            return "Refreshing this app's copy of the library…"
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                    Toggle("Local files", isOn: selectionBinding(for: .local))
                    InfoButton { infoTopic = .local }
                }
                if showLocal, let localSource {
                    SourceRowView(
                        source: localSource,
                        progress: viewModel.syncProgress,
                        onRescan: { viewModel.rescan(source: localSource, modelContext: modelContext) }
                    )
                    Button("Choose a Different Folder") {
                        isPickerPresented = true
                    }
                } else if showLocal {
                    VStack(spacing: 12) {
                        Image(systemName: "folder.badge.plus")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Choose a folder containing your music to build your library.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Choose Folder") {
                            isPickerPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowSeparator(.hidden)
                }
            }

            Section {
                HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                    Toggle("Apple Music", isOn: selectionBinding(for: .mediaLibrary))
                    InfoButton { infoTopic = .mediaLibrary }
                }
                if showMediaLibrary, let mediaLibrarySource {
                    SourceRowView(
                        source: mediaLibrarySource,
                        progress: viewModel.syncProgress,
                        onRescan: { viewModel.rescan(source: mediaLibrarySource, modelContext: modelContext) }
                    )
                } else if showMediaLibrary {
                    Button {
                        viewModel.importMediaLibrary(
                            existingSource: nil,
                            allSources: sources,
                            modelContext: modelContext
                        )
                    } label: {
                        HStack {
                            Text("Import from Apple Music")
                            if viewModel.isImportingMediaLibrary {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isImportingMediaLibrary)
                }
                if showMediaLibrary, let summary = viewModel.mediaLibraryImportSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                    Toggle("MPD", isOn: selectionBinding(for: .network))
                    InfoButton { infoTopic = .network }
                }
                if showNetwork, let networkSource {
                    SourceRowView(
                        source: networkSource,
                        progress: viewModel.syncProgress,
                        onRescan: { viewModel.rescan(source: networkSource, modelContext: modelContext) }
                    )
                    HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                        Button {
                            viewModel.syncWithMusicServer(source: networkSource, modelContext: modelContext)
                        } label: {
                            HStack {
                                Text("Sync MPD Host to Music Server")
                                if serverSyncInProgress {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(serverSyncInProgress)
                        // Its own topic rather than the MPD one: the difference between this and
                        // the refresh icon is the thing people need explaining, and burying it in
                        // a general description of MPD is where it was already failing to land.
                        InfoButton { infoTopic = .mpdServerSync }
                    }
                    if let serverSyncStatusText {
                        Text(serverSyncStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Disconnect", role: .destructive) {
                        viewModel.disconnectNetworkHost(source: networkSource, allSources: sources, modelContext: modelContext)
                    }
                } else if showNetwork {
                    TextField("Host or IP address", text: $hostInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $portInput)
                        .keyboardType(.numberPad)
                    Button {
                        guard let port = Int(portInput), !hostInput.isEmpty else { return }
                        viewModel.connectNetworkHost(
                            host: hostInput,
                            port: port,
                            existingNetworkSource: nil,
                            allSources: sources,
                            modelContext: modelContext
                        )
                    } label: {
                        if viewModel.isConnecting {
                            ProgressView()
                        } else {
                            Text("Connect")
                        }
                    }
                    .disabled(hostInput.isEmpty || Int(portInput) == nil || viewModel.isConnecting)
                }
            }

            Section {
                HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                    Toggle("Spotify", isOn: selectionBinding(for: .spotify))
                    InfoButton { infoTopic = .spotify }
                }
                if showSpotify, let spotifySource {
                    SourceRowView(
                        source: spotifySource,
                        progress: viewModel.syncProgress,
                        onRescan: { viewModel.rescan(source: spotifySource, modelContext: modelContext) }
                    )
                    if let account = spotifySource.spotifyAccountName {
                        Text("Signed in as \(account)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Spotify plays the audio, so which of its devices does it come out of.
                    Picker("Play On", selection: spotifyDeviceBinding(for: spotifySource)) {
                        Text("Automatic").tag(String?.none)
                        ForEach(viewModel.spotifyDevices) { device in
                            Text(device.displayName(thisDeviceName: UIDevice.current.name))
                                .tag(Optional(device.id))
                        }
                    }
                    Button {
                        viewModel.loadSpotifyDevices(source: spotifySource, activatingThisPhone: true)
                    } label: {
                        HStack {
                            Text("Refresh Devices")
                            if viewModel.isLoadingSpotifyDevices {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(viewModel.isLoadingSpotifyDevices)
                    if let deviceMessage = viewModel.spotifyDeviceMessage {
                        Text(deviceMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    // Plays through the Spotify app on this phone instead of over Connect,
                    // and stops polling Spotify's servers. The library itself is already local,
                    // so browsing works offline either way.
                    HStack(spacing: LayoutMetrics.infoButtonSpacing) {
                        Toggle("Offline mode", isOn: Binding(
                            get: { spotifySource.isOfflineMode },
                            set: { isOn in
                                viewModel.setSpotifyOfflineMode(isOn, source: spotifySource, modelContext: modelContext)
                                // Told directly, the same way the device picker is: the player
                                // reads this when a source becomes active, and toggling a switch
                                // doesn't change which source that is.
                                playback.setSpotifyOfflineMode(isOn)
                            }
                        ))
                        InfoButton { infoTopic = .spotifyOfflineMode }
                    }
                    if spotifySource.isOfflineMode {
                        Text("Opens the Spotify app at the track you pick, which plays it if it's downloaded. No queue; skip and pause come from Spotify's own controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Shown only when the stored token can no longer do what playback needs.
                    // Signing in again is the only fix — a refresh cannot widen a token — and
                    // without this the only route to one was Sign Out and start over.
                    if viewModel.spotifyNeedsReauthorization {
                        // The id is editable here because the sign-in it feeds can fail on the
                        // id itself: Spotify's authorize page answers "client_id: invalid" for
                        // an id that no longer matches an app in the dashboard, and correcting
                        // it was reachable only through Sign Out — which deletes the source, and
                        // the entire imported library with it.
                        TextField("Spotify client ID", text: $reauthorizeClientIDInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .task(id: spotifySource.spotifyClientID) {
                                if reauthorizeClientIDInput.isEmpty {
                                    reauthorizeClientIDInput = spotifySource.spotifyClientID
                                }
                            }
                        Button {
                            viewModel.connectSpotify(
                                clientID: reauthorizeClientIDInput,
                                existingSource: spotifySource,
                                allSources: sources,
                                modelContext: modelContext
                            )
                        } label: {
                            HStack {
                                Text("Authorize Spotify Again")
                                if viewModel.isSigningIntoSpotify {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(
                            viewModel.isSigningIntoSpotify
                                || reauthorizeClientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                    Button("Sign Out", role: .destructive) {
                        viewModel.signOutOfSpotify(source: spotifySource, allSources: sources, modelContext: modelContext)
                    }
                } else if showSpotify {
                    TextField("Spotify client ID", text: $spotifyClientIDInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        viewModel.connectSpotify(
                            clientID: spotifyClientIDInput,
                            existingSource: nil,
                            allSources: sources,
                            modelContext: modelContext
                        )
                    } label: {
                        HStack {
                            Text("Sign In with Spotify")
                            if viewModel.isSigningIntoSpotify {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(spotifyClientIDInput.isEmpty || viewModel.isSigningIntoSpotify)
                }
                if showSpotify, let summary = viewModel.spotifyImportSummary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
        .miniPlayerContentInset()
        .navigationTitle("Sources")
        // Starts the poll that reports a server-side sync. Without this nothing ever advanced
        // the phase past "Asking the server to sync…": the request was sent, the monitor that
        // watches for the server finishing was written, and the call that starts it was missing —
        // so the button worked and the screen said it hadn't.
        .task(id: networkSource?.persistentModelID) {
            guard let networkSource else { return }
            await viewModel.monitorServerSync(source: networkSource, modelContext: modelContext)
        }
        // Re-reads the list when this phone has just been made Spotify's active device. Spotify
        // lists a device only once something has played to it, so until that happens the phone is
        // simply absent from "Play On" — and without this it would stay absent until the screen
        // was opened afresh.
        .onChange(of: playback.localSpotifyActivations) { _, _ in
            if let spotifySource { viewModel.loadSpotifyDevices(source: spotifySource) }
        }
        .onAppear {
            viewModel.setSourcesScreenVisible(true)
            if showSpotify, let spotifySource { viewModel.loadSpotifyDevices(source: spotifySource) }
        }
        .onDisappear { viewModel.setSourcesScreenVisible(false) }
        .sheet(item: $infoTopic) { topic in
            SourceInfoSheet(topic: topic) { infoTopic = nil }
        }
        .sheet(isPresented: $isPickerPresented) {
            FolderDocumentPicker(
                onPick: { url in
                    isPickerPresented = false
                    viewModel.handleFolderPick(url: url, existingLocalSource: localSource, allSources: sources, modelContext: modelContext)
                },
                onCancel: {
                    isPickerPresented = false
                }
            )
        }
    }
}
