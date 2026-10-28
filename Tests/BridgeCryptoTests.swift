import XCTest
@testable import ClipStorage

final class BridgeCryptoTests: XCTestCase {
    func testPythonAESGCMInteroperabilityVector() throws {
        // Generated independently with Python cryptography.AESGCM, nonce bytes 0...11.
        let frame = Data(base64Encoded: "AAECAwQFBgcICQoLr7V+82pIKrMNpCoeWHbL0qZyxOnM4RF5HSzgI6+7WA==")!
        XCTAssertEqual(try BridgeCrypto.open(frame, key: Data((0..<32).map(UInt8.init))), Data("跨语言录音".utf8))
    }
    func testEncryptedPayloadRoundTripsAndTamperingFails() throws {
        let key = Data(repeating: 0x31, count: 32), content = Data("私人转写与引用".utf8)
        let sealed = try BridgeCrypto.seal(content, key: key)
        XCTAssertFalse(sealed.range(of: content) != nil)
        XCTAssertEqual(try BridgeCrypto.open(sealed, key: key), content)
        var corrupted = sealed; corrupted[corrupted.count - 1] ^= 1
        XCTAssertThrowsError(try BridgeCrypto.open(corrupted, key: key))
        XCTAssertThrowsError(try BridgeCrypto.open(sealed, key: Data(repeating: 1, count: 32)))
    }
    func testRejectsInvalidKeyAndShortFrame() {
        XCTAssertThrowsError(try BridgeCrypto.seal(Data(), key: Data(count: 16)))
        XCTAssertThrowsError(try BridgeCrypto.open(Data(count: 12), key: Data(count: 32)))
    }
}
