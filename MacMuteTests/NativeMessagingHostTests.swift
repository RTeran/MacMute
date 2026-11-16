import CryptoKit
import XCTest

final class NativeMessagingHostTests: XCTestCase {
    func testAllowsOnlyThePinnedExtension() {
        let manifest = NativeMessagingHost.manifest(helperPath: "/Applications/MacMute.app/Contents/Resources/MacMuteHelper")

        XCTAssertEqual(manifest["allowed_origins"] as? [String], ["chrome-extension://\(NativeMessagingHost.extensionID)/"])
    }

    func testDescribesTheHelperChromeStarts() {
        let helperPath = "/Applications/MacMute.app/Contents/Resources/MacMuteHelper"

        let manifest = NativeMessagingHost.manifest(helperPath: helperPath)

        XCTAssertEqual(manifest["name"] as? String, "com.macmute.helper")
        XCTAssertEqual(manifest["path"] as? String, helperPath)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
    }

    func testProducesValidJSON() throws {
        let manifest = NativeMessagingHost.manifest(helperPath: "/tmp/MacMuteHelper")

        XCTAssertTrue(JSONSerialization.isValidJSONObject(manifest))
    }

    // The ID is derived from the extension's manifest key, so changing the key without this
    // constant would make Chrome refuse the helper.
    func testMatchesTheIDPinnedByTheExtensionKey() throws {
        let extensionManifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("chrome-extension/manifest.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: extensionManifest)) as? [String: Any]
        let key = try XCTUnwrap(json?["key"] as? String)
        let spki = try XCTUnwrap(Data(base64Encoded: key))

        let derivedID = SHA256.hash(data: spki).prefix(16)
            .flatMap { [$0 >> 4, $0 & 0x0F] }
            .map { String(UnicodeScalar(UInt8(ascii: "a") + $0)) }
            .joined()

        XCTAssertEqual(derivedID, NativeMessagingHost.extensionID)
    }
}
