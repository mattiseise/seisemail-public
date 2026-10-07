import CryptoKit
import Foundation

public enum PKCE {
    public static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return Base64URL.encode(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        Base64URL.encode(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
}
