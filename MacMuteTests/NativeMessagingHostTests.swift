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

    func testHasOnlyTheKeysChromeReads() {
        let manifest = NativeMessagingHost.manifest(helperPath: "/tmp/MacMuteHelper")

        XCTAssertEqual(Set(manifest.keys), ["name", "description", "path", "type", "allowed_origins"])
    }

    func testInstallWritesTheManifestChromeLooksFor() throws {
        let directory = try makeTemporaryDirectory()

        _ = try NativeMessagingHost.install(helperPath: "/tmp/MacMuteHelper", into: directory)

        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL(in: directory))) as? NSDictionary
        XCTAssertEqual(written, NativeMessagingHost.manifest(helperPath: "/tmp/MacMuteHelper") as NSDictionary)
    }

    func testInstallFailsWhenTheDirectoryIsNotWritable() throws {
        try XCTSkipIf(geteuid() == 0, "root ignores directory permissions")
        let directory = try makeTemporaryDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        XCTAssertThrowsError(try NativeMessagingHost.install(helperPath: "/tmp/MacMuteHelper", into: directory))
    }

    func testInstallFailsWhenADirectoryTakesTheManifestPath() throws {
        let directory = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(at: manifestURL(in: directory), withIntermediateDirectories: false)

        XCTAssertThrowsError(try NativeMessagingHost.install(helperPath: "/tmp/MacMuteHelper", into: directory))
    }

    func testInstallReplacesASymlinkInsteadOfWritingThroughIt() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory().appendingPathComponent("victim.txt")
        try Data("untouched".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: manifestURL(in: directory), withDestinationURL: elsewhere)

        _ = try NativeMessagingHost.install(helperPath: "/tmp/MacMuteHelper", into: directory)

        let type = try FileManager.default.attributesOfItem(atPath: manifestURL(in: directory).path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeRegular)
        XCTAssertEqual(try String(contentsOf: elsewhere, encoding: .utf8), "untouched")
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

    private func manifestURL(in directory: URL) -> URL {
        directory.appendingPathComponent("com.macmute.helper.json")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
