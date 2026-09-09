import XCTest
@testable import NewPlayer

/// The bug this covers: with the Spotify app open on the phone but not yet playing anything,
/// every command came back "no active device". Spotify distinguishes *available* from *active*,
/// and refuses commands that name no device while nothing is active — so an app sitting open,
/// visibly ready, still refuses everything until it is named explicitly.
@MainActor
final class SpotifyDeviceTests: XCTestCase {
    private func makeController(
        client: FakeSpotifyClient
    ) -> SpotifyPlaybackController {
        let session = SpotifySession(
            auth: FakeSpotifyAuth(),
            tokens: InMemorySpotifyTokenStore(tokens: SpotifyTokens(
                accessToken: "token", refreshToken: "r",
                expiresAt: Date().addingTimeInterval(3600),
                scopes: SpotifyAuth.requiredScopes
            ))
        )
        let controller = SpotifyPlaybackController(session: session, client: client)
        controller.configure(clientID: "abc")
        return controller
    }

    private func device(
        _ id: String,
        name: String = "Phil's iPhone",
        active: Bool = false,
        restricted: Bool = false,
        type: String = "Smartphone"
    ) -> SpotifyDevice {
        SpotifyDevice(id: id, name: name, isActive: active, isRestricted: restricted, type: type)
    }

    func testAnOpenButIdleSpotifyAppIsWokenByNamingIt() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true // exactly how Spotify behaves with nothing active
        client.devices = [device("phone-1")]

        let controller = makeController(client: client)
        try await controller.play(trackIDs: ["t1"], startAt: 0)

        XCTAssertEqual(client.commands, ["play", "fetchDevices", "play"],
                       "the refusal should trigger a device lookup and a retry")
        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1", "the retry must name the device")
    }

    /// Having found a device, later commands go straight to it.
    func testTheChosenDeviceIsRememberedForLaterCommands() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("phone-1")]

        let controller = makeController(client: client)
        try await controller.play(trackIDs: ["t1"], startAt: 0)
        client.resetCommands()

        try await controller.pause()

        XCTAssertEqual(client.commands, ["pause"], "no second device lookup should be needed")
        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1")
    }

    /// A device already playing is the right target, in preference to anything else.
    func testAnActiveDeviceIsPreferred() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [
            device("speaker", name: "Kitchen", type: "Speaker"),
            device("phone-1", active: true),
        ]

        let controller = makeController(client: client)
        try await controller.resume()

        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1")
    }

    /// With nothing active, a phone is the better guess than a speaker somewhere else.
    func testAPhoneIsPreferredWhenNothingIsActive() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [
            device("speaker", name: "Kitchen", type: "Speaker"),
            device("phone-1", type: "Smartphone"),
        ]

        let controller = makeController(client: client)
        try await controller.resume()

        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1")
    }

    /// Some Connect devices refuse Web API control outright; those aren't a usable target.
    func testRestrictedDevicesAreNotChosen() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("locked", restricted: true)]

        let controller = makeController(client: client)

        do {
            try await controller.resume()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .onlyRestrictedDevices)
        }
    }

    /// Genuinely nothing to play on: the error should stand.
    func testNoDevicesAtAllStillReportsNoActiveDevice() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = []

        let controller = makeController(client: client)

        do {
            try await controller.resume()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .noActiveDevice)
        }
    }

    /// The message must not tell the user to do something they have already done.
    func testTheNoDeviceMessageDoesNotAskForPlaybackToBeStartedFirst() {
        let message = SpotifyError.noActiveDevice.errorDescription ?? ""
        XCTAssertFalse(message.lowercased().contains("start anything playing"),
                       "the app wakes an idle device itself now: \(message)")
    }

    // MARK: - Choosing a device in Sources

    /// A device chosen in Sources is used directly, without the discovery round trip.
    func testAChosenDeviceIsUsedWithoutLookingAnyUp() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("phone-1"), device("speaker", name: "Kitchen", type: "Speaker")]

        let controller = makeController(client: client)
        controller.selectDevice(id: "speaker")

        try await controller.resume()

        XCTAssertEqual(client.deviceIDsUsed, ["speaker"], "the chosen device should be named on the first try")
        XCTAssertFalse(client.commands.contains("fetchDevices"), "no discovery needed when one is chosen")
    }

    /// The user's choice outranks whatever discovery previously settled on.
    func testAChosenDeviceOverridesOneFoundAutomatically() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("phone-1")]

        let controller = makeController(client: client)
        try await controller.resume()          // discovers phone-1
        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1")

        controller.selectDevice(id: "speaker")
        client.resetCommands()
        try await controller.pause()

        XCTAssertEqual(client.deviceIDsUsed.last, "speaker")
    }

    /// Clearing the choice returns to picking automatically.
    func testClearingTheChoiceRestoresAutomaticSelection() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("phone-1")]

        let controller = makeController(client: client)
        controller.selectDevice(id: "speaker")
        controller.selectDevice(id: nil)
        client.resetCommands()

        try await controller.resume()

        XCTAssertTrue(client.commands.contains("fetchDevices"), "with no choice it should look devices up again")
        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1")
    }

    // MARK: - When the device list disagrees with reality

    /// The reported bug: "Spotify has no device to play on" while Spotify was open and playing.
    /// The device list reports what Spotify's backend has registered, which can lag what is
    /// actually happening — so when it comes back empty, what is playing is asked instead.
    func testAnEmptyDeviceListFallsBackToTheDevicePlayingNow() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [] // backend lists nothing…
        client.playerState = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 12, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "phone-1" // …but something is plainly playing
        )

        let controller = makeController(client: client)
        try await controller.resume()

        XCTAssertEqual(client.deviceIDsUsed.last, "phone-1", "it should talk to whatever is playing")
    }

    /// With nothing listed and nothing playing, the refusal stands — there genuinely is nowhere
    /// to send the command.
    func testAnEmptyListAndNothingPlayingStillRefuses() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = []
        client.playerState = nil

        let controller = makeController(client: client)

        do {
            try await controller.resume()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .noActiveDevice)
        }
    }

    /// A listed device is still preferred: the fallback is for when the list fails us.
    func testAListedDeviceIsPreferredOverTheFallback() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [device("listed", active: true)]
        client.playerState = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 0, durationSeconds: 200,
            trackID: "t1", activeDeviceID: "reported"
        )

        let controller = makeController(client: client)
        try await controller.resume()

        XCTAssertEqual(client.deviceIDsUsed.last, "listed")
    }
}
