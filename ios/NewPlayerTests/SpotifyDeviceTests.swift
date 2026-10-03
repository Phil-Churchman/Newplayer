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

    /// The regression this covers stopped Spotify playback altogether.
    ///
    /// The state poll was feeding the device from /me/player back into the controller, so every
    /// command went out pinned to it. /me/player goes on naming a device after it has left
    /// Connect, so once that id went stale every command was refused — and the recovery path
    /// re-read /me/player and returned the very same dead id, making the retry identical to the
    /// request that had just failed.
    ///
    /// So: a device the poll believes in must never outrank the device list. Recovery has to
    /// reach a device that is really there, or report that there isn't one.
    func testAStaleDeviceDoesNotStrandPlayback() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        // The live device, which is not the one a stale /me/player would name.
        client.devices = [device("phone-live", active: true)]
        client.playerState = SpotifyPlayerState(
            isPlaying: false, progressSeconds: 0, durationSeconds: 0,
            trackID: nil, activeDeviceID: "phone-dead"
        )

        let controller = makeController(client: client)
        controller.selectDevice(id: "phone-dead") // a device that has since gone

        try await controller.play(trackIDs: ["t1"], startAt: 0)

        XCTAssertEqual(client.deviceIDsUsed.last, "phone-live",
                       "playback must end up on a device that actually exists")
    }

    /// The other half of the same regression: with no device registered, the honest answer is
    /// the error, not a guess taken from /me/player. The message tells the user to open Spotify,
    /// which is the thing that actually fixes it.
    func testAnEmptyDeviceListIsNotPaperedOverWithThePolledDevice() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = []
        client.playerState = SpotifyPlayerState(
            isPlaying: true, progressSeconds: 10, durationSeconds: 100,
            trackID: "t1", activeDeviceID: "phone-dead"
        )

        let controller = makeController(client: client)

        do {
            try await controller.play(trackIDs: ["t1"], startAt: 0)
            XCTFail("expected a refusal rather than a command aimed at a device that has gone")
        } catch {
            XCTAssertEqual(error as? SpotifyError, .noActiveDevice)
        }
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

    /// The regression this covers dragged playback off the phone.
    ///
    /// A device discovered after a refusal was remembered for the rest of the session. Pick up a
    /// speaker once and every later command kept going to it, even after playback had moved to
    /// the phone — and those commands *succeed*, because the speaker is a real device, so
    /// nothing ever noticed. Choosing a track in the app pulled the music back to the speaker.
    func testADiscoveredDeviceIsNotUsedOnceSpotifyHasMovedElsewhere() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.devices = [
            device("speaker", name: "raspotify", active: true, type: "Speaker"),
            device("phone", active: false),
        ]

        let controller = makeController(client: client)
        try await controller.resume()                       // discovers the speaker
        XCTAssertEqual(client.deviceIDsUsed.last, "speaker")

        // Spotify is now playing on the phone, started from the Spotify app itself.
        controller.noteActiveDevice(id: "phone")
        client.resetCommands()
        client.requiresNamedDevice = false                  // something is active, so a bare command lands

        try await controller.play(trackIDs: ["t1"], startAt: 0)

        // Doubly optional: the array holds `String?`, so `.last` is `String??` and comparing it
        // against a bare nil asks whether the array was empty, not whether the command named a
        // device. Unwrap the "was there a command" layer, then assert on the device itself.
        let deviceUsed = try XCTUnwrap(client.deviceIDsUsed.last, "no command was sent at all")
        XCTAssertNil(deviceUsed,
                     "with the stale discovery forgotten, Spotify routes it to what is active")
    }

    /// Only clears, never pins. The earlier attempt at following the active device *set* the
    /// target from this signal, and /me/player goes on naming a device after it has gone — so a
    /// dead id got pinned to every command. Clearing cannot go stale.
    func testNotingAnActiveDeviceNeverPinsCommandsToIt() async throws {
        let client = FakeSpotifyClient()
        client.devices = [device("phone")]
        let controller = makeController(client: client)

        controller.noteActiveDevice(id: "a-device-that-has-since-gone")
        try await controller.play(trackIDs: ["t1"], startAt: 0)

        XCTAssertEqual(client.deviceIDsUsed, [nil], "nothing should be named off the back of a poll")
    }

    /// A device the user pinned is theirs, and Spotify moving does not override it.
    func testAPinnedDeviceSurvivesSpotifyMovingElsewhere() async throws {
        let client = FakeSpotifyClient()
        client.devices = [device("speaker", name: "raspotify", type: "Speaker"), device("phone")]
        let controller = makeController(client: client)

        controller.selectDevice(id: "speaker")
        controller.noteActiveDevice(id: "phone")
        try await controller.play(trackIDs: ["t1"], startAt: 0)

        XCTAssertEqual(client.deviceIDsUsed.last, "speaker")
    }

    // MARK: - "Restriction violated"

    /// Observed with Spotify paused on a speaker and the app asked to play on the phone:
    ///
    ///     PUT me/player/play?device_id=<phone> → HTTP 403
    ///     "Player command failed: Restriction violated"
    ///
    /// Naming a device in a play request reads as though it claims that device. It does not —
    /// only a transfer does. So the refusal is answered by claiming the device and sending the
    /// command again, rather than reporting a dead end to the user.
    func testADeviceThatIsNotInChargeIsClaimedWithATransferThenCommanded() async throws {
        let client = FakeSpotifyClient()
        client.devices = [
            device("speaker", name: "raspotify", active: true, type: "Speaker"),
            device("phone"),
        ]
        client.activeDeviceID = "speaker"
        client.refusesCommandsToInactiveDevices = true

        let controller = makeController(client: client)
        controller.selectDevice(id: "phone")

        try await controller.play(trackIDs: ["t1"], startAt: 0)

        XCTAssertTrue(client.commands.contains("transfer:phone:false"),
                      "the phone has to be claimed before it will accept a play: \(client.commands)")
        XCTAssertEqual(client.deviceIDsUsed.last, "phone", "and the play then goes to it")
    }

    /// Refused with nothing named is the "nothing is active" state wearing a different status
    /// code, so it is answered the same way as the 404: find a device and name it.
    func testARefusalWithNoDeviceNamedLooksOneUp() async throws {
        let client = FakeSpotifyClient()
        client.requiresNamedDevice = true
        client.refusalForUnnamedDevice = .actionNotAllowed("Player command failed: Restriction violated")
        client.devices = [device("phone-1")]

        let controller = makeController(client: client)
        try await controller.resume()

        XCTAssertEqual(client.commands, ["resume", "fetchDevices", "resume"])
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
        // Both are real devices. The speaker used to be named without being in the list, which
        // only passed because the fake accepted any id at all — Spotify answers a device it has
        // never heard of with 404, and a test that pins fiction proves nothing about precedence.
        client.devices = [device("phone-1"), device("speaker", name: "Kitchen", type: "Speaker")]

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

    // MARK: - When Spotify's two endpoints disagree

    // The test that used to sit here asserted the opposite of what the app now does: that an
    // empty device list should be answered by targeting whatever /me/player names. That reads
    // the disagreement backwards — /me/player serves the last known context and goes on naming
    // a device after it has gone, while the list reports what Connect can reach now — and it is
    // what stopped playback working. `testAnEmptyDeviceListIsNotPaperedOverWithThePolledDevice`
    // above covers the behaviour that replaced it.

    /// With nothing listed and nothing playing there is genuinely nowhere to send it.
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

    /// The device list is the authority, and what /me/player reports does not override it.
    func testAListedDeviceIsStillPreferred() async throws {
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
