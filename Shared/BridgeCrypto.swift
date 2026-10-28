import Foundation
import CryptoKit

enum BridgeCrypto {
    static func seal(_ plaintext: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.invalidKey }
        guard let combined = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key)).combined else { throw Failure.invalidFrame }
        return combined
    }
    static func open(_ combined: Data, key: Data) throws -> Data {
        guard key.count == 32 else { throw Failure.invalidKey }
        guard combined.count >= 28 else { throw Failure.invalidFrame }
        return try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: SymmetricKey(data: key))
    }
    enum Failure: Error { case invalidKey, invalidFrame }
}
