import Foundation
import SwiftData

/// Mirrors what the server reports, and nothing else. There is deliberately no failure or
/// "interrupted" case: a sync runs on the MPD host, so backgrounding the app or the phone going
/// to standby has no bearing on it. Losing the connection means we temporarily can't *observe*
/// the sync — never that it stopped — so the monitor simply reconnects and reports the truth.
enum ServerSyncPhase: Equatable {
    case idle
    /// Asked the server to start; it hasn't reported the update yet.
    case requested
    /// The server reports `updating_db`.
    case syncing
    /// The server finished; pulling the refreshed catalogue into the app.
    case refreshingLibrary
}

struct LibrarySyncProgress: Equatable {
    var processed: Int
    var total: Int
}

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published var errorMessage: String?
    @Published var isConnecting = false
    @Published private(set) var isImportingMediaLibrary = false
    @Published private(set) var serverSyncPhase: ServerSyncPhase = .idle
    /// Non-nil only while a rescan (of either source kind) is actively inserting rows.
    @Published private(set) var syncProgress: LibrarySyncProgress?

    /// Non-nil after a Music-library import, so the screen can say what happened — in
    /// particular how many Apple Music items had to be skipped, which is otherwise baffling.
    @Published var mediaLibraryImportSummary: String?

    @Published private(set) var isSigningIntoSpotify = false
    @Published var spotifyImportSummary: String?
    /// Connect devices Spotify can currently see for this account.
    @Published private(set) var spotifyDevices: [SpotifyDevice] = []
    @Published private(set) var isLoadingSpotifyDevices = false
    @Published var spotifyDeviceMessage: String?

    private let mediaLibrary: MediaLibraryProviding
    private let spotifyAuth: SpotifyAuthorizing
    private let spotifyClient: SpotifyAPIClient
    private let spotifyTokens: SpotifyTokenStoring
    private let spotifySession: SpotifySession
    private let spotifyAppLink: SpotifyAppLinking
    private let makeMPDClient: () -> MPDClientProtocol
    private let monitorIntervalNanoseconds: UInt64
    /// Whether the Sources screen is actually on screen. A TabView keeps every tab it has shown
    /// alive, so the monitor's `.task` is never cancelled once you've visited Sources — without
    /// this it would hold a connection open and poll the host forever, from behind whatever tab
    /// you're actually looking at, competing with playback and artwork for the server.
    private var isSourcesScreenVisible = true

    init(
        makeMPDClient: @escaping () -> MPDClientProtocol = { MPDClient() },
        monitorIntervalNanoseconds: UInt64 = 2_000_000_000,
        mediaLibrary: MediaLibraryProviding? = nil,
        spotifyAuth: SpotifyAuthorizing? = nil,
        spotifyClient: SpotifyAPIClient = SpotifyWebAPIClient(),
        spotifyTokens: SpotifyTokenStoring? = nil,
        spotifyAppLink: SpotifyAppLinking? = nil
    ) {
        self.makeMPDClient = makeMPDClient
        self.monitorIntervalNanoseconds = monitorIntervalNanoseconds
        self.mediaLibrary = mediaLibrary ?? SystemMediaLibrary()
        self.spotifyAuth = spotifyAuth ?? SpotifyAuth()
        self.spotifyClient = spotifyClient
        self.spotifyTokens = spotifyTokens ?? SpotifyKeychainTokenStore()
        // The app-wide session unless a test supplied its own pieces, so this and PlaybackManager
        // share one token and one refresh rather than competing over the Keychain.
        self.spotifyAppLink = spotifyAppLink ?? SpotifyAppLink()
        self.spotifySession = (spotifyAuth == nil && spotifyTokens == nil)
            ? .shared
            : SpotifySession(auth: self.spotifyAuth, tokens: self.spotifyTokens)
    }

    // MARK: - Spotify

    /// Signs in (or reuses a stored token), checks the account is Premium, then imports the
    /// account's saved library. Sign-in happens on Spotify's own page — this never sees a
    /// password, which is both their rule and the only safe way to do it.
    func connectSpotify(clientID: String, existingSource: Source?, allSources: [Source], modelContext: ModelContext) {
        guard !isSigningIntoSpotify else { return }
        let trimmedID = clientID.trimmingCharacters(in: .whitespaces)
        guard !trimmedID.isEmpty else {
            errorMessage = SpotifyError.missingClientID.errorDescription
            return
        }

        isSigningIntoSpotify = true
        errorMessage = nil
        spotifyImportSummary = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.validAccessToken(clientID: trimmedID)
                let account = try await self.spotifyClient.fetchAccount(accessToken: token)
                guard account.isPremium else {
                    throw SpotifyError.notPremium(product: account.product)
                }

                // Reuses whatever Spotify source already exists, even when the caller passed
                // none. Creating a second one leaves the first — and its whole library — behind,
                // so a sync appears to add and remove nothing.
                let existingSpotifySource = existingSource
                    ?? (try? modelContext.fetch(FetchDescriptor<Source>()))?
                        .first { $0.kind == .spotify }
                let source = existingSpotifySource ?? {
                    let created = Source(name: "Spotify", kind: .spotify)
                    modelContext.insert(created)
                    return created
                }()
                source.spotifyClientID = trimmedID
                source.spotifyAccountName = account.displayName

                let result = try await SpotifyImportService.rescan(
                    source: source,
                    client: self.spotifyClient,
                    accessToken: token,
                    modelContext: modelContext,
                    onProgress: self.makeProgressHandler()
                )
                self.syncProgress = nil
                self.activate(source, among: allSources + [source])
                try? modelContext.save()
                self.spotifyImportSummary = "Imported \(result.imported) track\(result.imported == 1 ? "" : "s") from \(account.displayName)."
            } catch {
                self.syncProgress = nil
                if existingSource == nil {
                    // Don't leave an empty source behind for a sign-in that never completed.
                    if let stranded = allSources.first(where: { $0.kind == .spotify && $0.songs.isEmpty }) {
                        modelContext.delete(stranded)
                        try? modelContext.save()
                    }
                }
                self.errorMessage = (error as? SpotifyError)?.errorDescription ?? error.localizedDescription
            }
            self.isSigningIntoSpotify = false
        }
    }

    /// Asks Spotify which devices are available. Deliberately non-interactive: this runs when the
    /// Sources screen appears, and a screen appearing must never throw up a sign-in page.
    func loadSpotifyDevices(source: Source) {
        guard !isLoadingSpotifyDevices, !source.spotifyClientID.isEmpty else { return }
        isLoadingSpotifyDevices = true
        spotifyDeviceMessage = nil

        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await self.spotifySession.accessToken(
                    clientID: source.spotifyClientID,
                    interactive: false
                )
                let devices = try await self.spotifyClient.fetchDevices(accessToken: token)
                self.spotifyDevices = devices
                self.spotifyDeviceMessage = Self.deviceHint(for: devices)
            } catch {
                self.spotifyDevices = []
                self.spotifyDeviceMessage = (error as? SpotifyError)?.errorDescription
                    ?? "Couldn't ask Spotify which devices are available."
            }
            self.isLoadingSpotifyDevices = false
        }
    }

    /// What to tell the user about the list they can see.
    ///
    /// Spotify only reports devices it can currently reach, and a Spotify app that has been
    /// opened but has never played anything does not register — so "my phone isn't in the list"
    /// is the common case and has a specific remedy rather than being a fault.
    static func deviceHint(for devices: [SpotifyDevice]) -> String? {
        if devices.isEmpty {
            return "Spotify reports no devices. Open the Spotify app on the device you want to play on and start any track once, then tap Refresh Devices."
        }
        if !devices.contains(where: \.isPhone) {
            return "To play on this phone, open the Spotify app here and start any track once, then tap Refresh Devices."
        }
        // Said whenever the list is short, because "why is this fewer than the Spotify app shows"
        // is the obvious question and the answer isn't a fault in this app.
        return "This is the list Spotify publishes for your account. The Spotify app also finds Bluetooth, AirPlay and speakers on your network directly, and those only appear here once you have played to them from Spotify at least once."
    }

    /// Whether to offer to open Spotify, as the way to make this phone appear in the list.
    ///
    /// Only when it would actually help: Spotify installed, and no phone among the devices it
    /// reports. Offering it when the phone is already there would be advice to do nothing.
    var shouldOfferToOpenSpotify: Bool {
        Self.shouldOfferToOpenSpotify(devices: spotifyDevices, isSpotifyInstalled: spotifyAppLink.isInstalled)
    }

    static func shouldOfferToOpenSpotify(devices: [SpotifyDevice], isSpotifyInstalled: Bool) -> Bool {
        isSpotifyInstalled && !devices.contains(where: \.isPhone)
    }

    func openSpotifyApp() {
        spotifyAppLink.open()
    }

    /// Pins playback to one device, or back to automatic when nil. Remembered on the source so
    /// the choice survives relaunching.
    func selectSpotifyDevice(_ deviceID: String?, source: Source, modelContext: ModelContext) {
        source.spotifyDeviceID = deviceID
        try? modelContext.save()
    }

    func signOutOfSpotify(source: Source, allSources: [Source], modelContext: ModelContext) {
        spotifyTokens.clear()
        spotifyImportSummary = nil
        spotifyDevices = []
        spotifyDeviceMessage = nil
        modelContext.delete(source)
        SourceSelection.select(nil, among: allSources.filter { $0 != source }, modelContext: modelContext)
    }

    private func validAccessToken(clientID: String) async throws -> String {
        try await spotifySession.accessToken(clientID: clientID)
    }

    // MARK: - Music (iTunes) library source

    /// Imports the device's Music library, creating the source on first use. Unlike the folder
    /// source there is nothing for the user to pick — the library is simply there, subject to
    /// permission.
    func importMediaLibrary(existingSource: Source?, allSources: [Source], modelContext: ModelContext) {
        guard !isImportingMediaLibrary else { return }
        isImportingMediaLibrary = true
        errorMessage = nil
        mediaLibraryImportSummary = nil

        Task { [weak self] in
            guard let self else { return }
            let source = existingSource ?? {
                let created = Source(name: "Music Library", kind: .mediaLibrary)
                modelContext.insert(created)
                return created
            }()

            do {
                let result = try await MediaLibraryImportService.rescan(
                    source: source,
                    provider: self.mediaLibrary,
                    modelContext: modelContext,
                    onProgress: self.makeProgressHandler()
                )
                self.syncProgress = nil
                self.activate(source, among: allSources + [source])
                try? modelContext.save()
                self.mediaLibraryImportSummary = Self.summary(for: result)
            } catch SpotifyError.permissionsMissing {
                // The user is here and can approve, so this is the one place it's right to throw
                // the token away and start again.
                self.spotifySession.discardStoredTokens()
                self.syncProgress = nil
                self.errorMessage = "Spotify needs to be re-authorized. Tap Sign In with Spotify again."
            } catch MediaLibraryImportError.accessDenied {
                self.syncProgress = nil
                self.rollBack(source, wasExisting: existingSource != nil, modelContext: modelContext)
                self.errorMessage = "New player doesn't have permission to read your Music library. You can grant it in Settings › Privacy & Security › Media & Apple Music."
            } catch MediaLibraryImportError.accessRestricted {
                self.syncProgress = nil
                self.rollBack(source, wasExisting: existingSource != nil, modelContext: modelContext)
                self.errorMessage = "Access to the Music library is restricted on this device."
            } catch {
                self.syncProgress = nil
                self.rollBack(source, wasExisting: existingSource != nil, modelContext: modelContext)
                self.errorMessage = "Couldn't read the Music library."
            }
            self.isImportingMediaLibrary = false
        }
    }

    /// Don't leave an empty source behind when the import never got off the ground.
    private func rollBack(_ source: Source, wasExisting: Bool, modelContext: ModelContext) {
        guard !wasExisting else { return }
        modelContext.delete(source)
        try? modelContext.save()
    }

    private static func summary(for result: MediaLibraryImportService.Result) -> String {
        let tracks = "\(result.imported) track\(result.imported == 1 ? "" : "s")"
        var notes: [String] = []
        if result.skippedProtected > 0 {
            notes.append("\(result.skippedProtected) not downloaded to this device, or Apple Music tracks that can only be played in the Music app")
        }
        if result.skippedUnplayable > 0 {
            notes.append("\(result.skippedUnplayable) that wouldn't open")
        }
        guard !notes.isEmpty else { return "Imported \(tracks)." }
        return "Imported \(tracks). Skipped \(notes.joined(separator: ", and "))."
    }

    func setSourcesScreenVisible(_ visible: Bool) {
        isSourcesScreenVisible = visible
    }

    /// Polls the host for as long as the Sources screen is open and reports exactly what it
    /// says. Reconnects silently if the connection drops — that only means we lost sight of the
    /// sync, not that the sync stopped.
    func monitorServerSync(source: Source, modelContext: ModelContext) async {
        guard source.kind == .network, !source.host.isEmpty else { return }
        let host = source.host
        let port = UInt16(clamping: max(0, source.port))

        var client: MPDClientProtocol?
        var pollsWithoutUpdating = 0
        defer {
            if let client {
                Task { await client.disconnect() }
            }
        }

        while !Task.isCancelled {
            guard isSourcesScreenVisible else {
                // Nothing to report to and nobody looking: drop the connection rather than
                // holding one open, and check back on the next tick.
                if let active = client {
                    await active.disconnect()
                    client = nil
                }
                try? await Task.sleep(nanoseconds: monitorIntervalNanoseconds)
                continue
            }

            if client == nil {
                let fresh = makeMPDClient()
                do {
                    try await fresh.connect(host: host, port: port)
                    client = fresh
                } catch {
                    // Can't see the server right now. Leave the phase alone and try again.
                }
            }

            if let active = client {
                do {
                    let status = try await active.fetchStatus()
                    if status.isUpdatingDatabase {
                        pollsWithoutUpdating = 0
                        serverSyncPhase = .syncing
                    } else {
                        pollsWithoutUpdating += 1
                        await handleServerNotSyncing(
                            pollsWithoutUpdating: pollsWithoutUpdating,
                            source: source,
                            client: active,
                            modelContext: modelContext
                        )
                    }
                } catch {
                    await active.disconnect()
                    client = nil
                }
            }

            try? await Task.sleep(nanoseconds: monitorIntervalNanoseconds)
        }
    }

    private func handleServerNotSyncing(
        pollsWithoutUpdating: Int,
        source: Source,
        client: MPDClientProtocol,
        modelContext: ModelContext
    ) async {
        switch serverSyncPhase {
        case .syncing:
            // It was running and now isn't: finished, so pull the refreshed catalogue.
            await refreshLibrary(source: source, client: client, modelContext: modelContext)
        case .requested where pollsWithoutUpdating >= 2:
            // Either it completed before we looked, or there was nothing to update. Either way
            // the request is done — refresh and settle rather than waiting forever.
            await refreshLibrary(source: source, client: client, modelContext: modelContext)
        case .requested, .idle, .refreshingLibrary:
            break
        }
    }

    private func refreshLibrary(source: Source, client: MPDClientProtocol, modelContext: ModelContext) async {
        serverSyncPhase = .refreshingLibrary
        await MPDLibrarySyncService.rescan(
            source: source,
            client: client,
            modelContext: modelContext,
            onProgress: makeProgressHandler()
        )
        syncProgress = nil
        serverSyncPhase = .idle
    }

    // MARK: - Local folder source

    func handleFolderPick(url: URL, existingLocalSource: Source?, allSources: [Source], modelContext: ModelContext) {
        do {
            let bookmark = try FolderBookmarkStore.makeBookmark(for: url)
            let source = existingLocalSource ?? {
                let newSource = Source(name: "Local", kind: .local)
                modelContext.insert(newSource)
                return newSource
            }()
            source.bookmarkData = bookmark
            source.bookmarkDisplayName = url.lastPathComponent
            activate(source, among: allSources + [source])
            try? modelContext.save()

            Task {
                await LibraryImportService.rescan(source: source, modelContext: modelContext, onProgress: makeProgressHandler())
                self.syncProgress = nil
            }
        } catch {
            errorMessage = "Couldn't access that folder. Please try again."
        }
    }

    // MARK: - Network (MPD) source

    func connectNetworkHost(host: String, port: Int, existingNetworkSource: Source?, allSources: [Source], modelContext: ModelContext) {
        errorMessage = nil
        isConnecting = true
        Task {
            let client = makeMPDClient()
            do {
                try await client.connect(host: host, port: UInt16(clamping: max(0, port)))

                let source = existingNetworkSource ?? {
                    let newSource = Source(name: "Network", host: host, port: port, kind: .network)
                    modelContext.insert(newSource)
                    return newSource
                }()
                source.host = host
                source.port = port
                activate(source, among: allSources + [source])
                try? modelContext.save()

                await MPDLibrarySyncService.rescan(source: source, client: client, modelContext: modelContext, onProgress: makeProgressHandler())
                syncProgress = nil
                await client.disconnect()
            } catch {
                errorMessage = "Couldn't connect to that server. Check the host and port."
            }
            isConnecting = false
        }
    }

    func disconnectNetworkHost(source: Source, allSources: [Source], modelContext: ModelContext) {
        modelContext.delete(source)
        // Nothing is selected afterwards rather than quietly moving to another source: which one
        // to use next is the user's choice, and the library screens say so plainly.
        SourceSelection.select(nil, among: allSources.filter { $0 != source }, modelContext: modelContext)
    }

    func makeActive(_ source: Source, among allSources: [Source], modelContext: ModelContext) {
        activate(source, among: allSources)
        try? modelContext.save()
    }

    /// Tells the MPD server itself to rescan its music directory (distinct from `rescan`,
    /// which only re-fetches whatever the server already has into our mirrored catalogue).
    /// Runs as a background task so it keeps going for a while even if the app is backgrounded
    /// mid-sync, and doesn't block navigating the app while it's in progress.
    /// Asks the server to rescan its own music directory. Deliberately fire-and-forget: the
    /// sync then belongs to the server, and `monitorServerSync` reports its progress. Nothing
    /// here holds a background task or tracks a deadline, because nothing the app does (being
    /// backgrounded, the phone sleeping, the app being killed) can interrupt it.
    func syncWithMusicServer(source: Source, modelContext: ModelContext) {
        guard serverSyncPhase == .idle else { return }
        errorMessage = nil
        serverSyncPhase = .requested

        let host = source.host
        let port = UInt16(clamping: max(0, source.port))
        Task { [weak self] in
            guard let self else { return }
            let client = self.makeMPDClient()
            do {
                try await client.connect(host: host, port: port)
                try await client.updateDatabase()
            } catch {
                // Couldn't even ask. Drop back to idle so the monitor's view of the server
                // stands — there is no half-finished state of ours to report.
                self.serverSyncPhase = .idle
                self.errorMessage = "Couldn't reach the server to start the sync."
            }
            await client.disconnect()
        }
    }

    // MARK: - Shared

    func rescan(source: Source, modelContext: ModelContext) {
        if source.kind == .spotify {
            connectSpotify(
                clientID: source.spotifyClientID,
                existingSource: source,
                allSources: [],
                modelContext: modelContext
            )
            return
        }
        if source.kind == .mediaLibrary {
            importMediaLibrary(existingSource: source, allSources: [], modelContext: modelContext)
            return
        }
        if source.kind == .network {
            let host = source.host
            let port = source.port
            Task {
                let client = self.makeMPDClient()
                do {
                    try await client.connect(host: host, port: UInt16(clamping: max(0, port)))
                    await MPDLibrarySyncService.rescan(source: source, client: client, modelContext: modelContext, onProgress: makeProgressHandler())
                    syncProgress = nil
                    await client.disconnect()
                } catch {
                    syncProgress = nil
                    source.lastSyncStatus = .failed
                    try? modelContext.save()
                }
            }
        } else {
            Task {
                await LibraryImportService.rescan(source: source, modelContext: modelContext, onProgress: makeProgressHandler())
                syncProgress = nil
            }
        }
    }

    /// Enforces the single-active-source rule: activating one source deactivates every other,
    /// and records the choice so it survives relaunching and is visible to the Sources switches.
    ///
    /// Setting up a source is choosing it — picking a folder, connecting a host or signing into
    /// Spotify would otherwise leave the user with a configured source they still had to go and
    /// select before anything appeared.
    private func activate(_ target: Source, among allSources: [Source]) {
        SourceSelection.selectedKind = target.kind
        for source in allSources {
            source.isActive = (source.persistentModelID == target.persistentModelID)
        }
    }

    private func makeProgressHandler() -> (Int, Int) -> Void {
        { [weak self] processed, total in
            self?.syncProgress = LibrarySyncProgress(processed: processed, total: total)
        }
    }
}
