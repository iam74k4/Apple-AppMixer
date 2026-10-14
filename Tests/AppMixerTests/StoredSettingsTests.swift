import XCTest
@testable import AppMixer

final class StoredSettingsTests: XCTestCase {

    func testRoundTripKeepsBalance() throws {
        var stored = StoredSettings(outputDeviceUID: "dev-1")
        stored.perDevice["dev-1"] = DeviceVolume(volume: 0.4, muted: true, balance: -0.3)
        stored.lastKnown = DeviceVolume(volume: 0.7, muted: false, balance: 0.2)

        let data = try JSONEncoder().encode(stored)
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: data)
        XCTAssertEqual(decoded, stored)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertFalse(decoded.isNewerThanSupported)
    }

    func testLegacyVersion1WithoutBalanceReadsAsCentered() throws {
        // 1.0.x が書いた形。balance が無い。
        let json = """
        {"version":1,"outputDeviceUID":null,
         "perDevice":{"dev-1":{"volume":0.5,"muted":false}},
         "lastKnown":{"volume":0.5,"muted":false}}
        """
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.perDevice["dev-1"], DeviceVolume(volume: 0.5, muted: false, balance: 0))
        XCTAssertEqual(decoded.lastKnown?.balance, 0)
        XCTAssertFalse(decoded.isNewerThanSupported)
    }

    func testMissingVersionAndFieldsFallBackToDefaults() throws {
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.version, 0)
        XCTAssertNil(decoded.outputDeviceUID)
        XCTAssertTrue(decoded.perDevice.isEmpty)
        XCTAssertNil(decoded.lastKnown)
    }

    func testNewerVersionIsReadableButMarkedForeign() throws {
        let json = """
        {"version":99,"perDevice":{"d":{"volume":0.1,"muted":true,"balance":1,"future":"x"}}}
        """
        let decoded = try JSONDecoder().decode(StoredSettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isNewerThanSupported)
        XCTAssertEqual(decoded.perDevice["d"]?.volume, 0.1)
        XCTAssertEqual(decoded.perDevice["d"]?.balance, 1)
    }

    func testEncodedFormStaysReadableByVersion1Readers() throws {
        // 1.0.x は volume / muted だけを読む。balance が増えてもそれらは同じ場所にある。
        var stored = StoredSettings()
        stored.perDevice["d"] = DeviceVolume(volume: 0.25, muted: false, balance: 0.5)
        let data = try JSONEncoder().encode(stored)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let perDevice = try XCTUnwrap(object["perDevice"] as? [String: [String: Any]])
        XCTAssertEqual(perDevice["d"]?["volume"] as? Double ?? -1, 0.25, accuracy: 1e-6)
        XCTAssertEqual(perDevice["d"]?["muted"] as? Bool, false)
        XCTAssertEqual(perDevice["d"]?["balance"] as? Double ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(object["version"] as? Int, 2)
    }
}
