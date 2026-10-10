import XCTest
@testable import NewPlayer

/// The device list is the whole of the user's control over where Spotify plays, so what it says
/// matters as much as what it contains — particularly when the device they are looking for
/// isn't in it.
@MainActor
final class SpotifyDeviceListTests: XCTestCase {
    private func device(
        _ id: String,
        name: String,
        active: Bool = false,
        restricted: Bool = false,
        type: String = "Smartphone"
    ) -> SpotifyDevice {
        SpotifyDevice(id: id, name: name, isActive: active, isRestricted: restricted, type: type)
    }

    func testThisHandsetIsCalledOut() {
        let phone = device("1", name: "Phil's iPhone")
        XCTAssertEqual(
            phone.displayName(thisDeviceName: "Phil's iPhone"),
            "Phil's iPhone (this device)"
        )
    }

    func testAnotherDeviceIsNotCalledOutAsThisOne() {
        let speaker = device("2", name: "Kitchen", type: "Speaker")
        XCTAssertEqual(speaker.displayName(thisDeviceName: "Phil's iPhone"), "Kitchen")
    }

    func testThePlayingDeviceIsMarked() {
        let phone = device("1", name: "Kitchen", active: true, type: "Speaker")
        XCTAssertTrue(phone.displayName(thisDeviceName: "").contains("playing"))
    }

    func testADeviceThatCannotBeDrivenSaysSo() {
        let locked = device("3", name: "Car", restricted: true, type: "Automobile")
        XCTAssertTrue(locked.displayName(thisDeviceName: "").contains("not controllable"))
    }

    func testAnEmptyListExplainsHowToMakeAnyDeviceAppear() {
        let hint = SourcesViewModel.deviceHint(for: [])
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("Refresh Devices") == true)
    }

    /// A list with devices in it carries no note at all now.
    func testAListWithDevicesCarriesNoNote() {
        let devices = [
            device("1", name: "Phil's iPhone"),
            device("2", name: "Kitchen", type: "Speaker"),
        ]
        XCTAssertNil(SourcesViewModel.deviceHint(for: devices))
    }
}
