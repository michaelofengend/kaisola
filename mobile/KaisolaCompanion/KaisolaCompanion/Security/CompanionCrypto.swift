import CryptoKit
import Foundation

enum CompanionCryptoError: Error, Equatable {
    case invalidEncoding(String)
    case invalidIdentity(String)
    case invalidKeyRecord
    case identityProofFailed
    case roleMismatch
    case identityMismatch
    case invalidHandshakeMessage
    case handshakeOrder
    case authenticationFailed
    case invalidDH
    case invalidSecureFrame
    case replayOrOutOfOrder
    case frameTooLarge
    case counterExhausted
    case invalidSecurePayload
    case keyConfirmationFailed
}

extension Data {
    init?(base64URLString value: String) {
        guard !value.isEmpty,
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { return nil }
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        guard let decoded = Data(base64Encoded: base64), decoded.base64URLEncodedString() == value else { return nil }
        self = decoded
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var output = Data(capacity: hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            output.append(byte)
            index = next
        }
        self = output
    }
}

enum CompanionCrypto {
    static let noiseProtocol = "Noise_XX_25519_ChaChaPoly_SHA256"
    static let protocolVersion = 1
    static let maximumHandshakeMessageBytes = 64 * 1_024
    static let maximumSecurePlaintextBytes = 1_024 * 1_024

    static let keyRecordDomain = Data("kaisola-companion-key-record-v1\0".utf8)
    static let handshakeSignatureDomain = Data("kaisola-companion-noise-hash-v1\0".utf8)
    static let prologueDomain = Data("kaisola-companion-noise-prologue-v1\0".utf8)

    static func sha256(_ parts: Data...) -> Data {
        var hash = SHA256()
        for part in parts { hash.update(data: part) }
        return Data(hash.finalize())
    }

    static func hmac(key: Data, parts: Data...) -> Data {
        var input = Data()
        for part in parts { input.append(part) }
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key)))
    }

    static func noiseHKDF(chainingKey: Data, inputKeyMaterial: Data) -> (Data, Data) {
        let temporaryKey = hmac(key: chainingKey, parts: inputKeyMaterial)
        let output1 = hmac(key: temporaryKey, parts: Data([1]))
        let output2 = hmac(key: temporaryKey, parts: output1, Data([2]))
        return (output1, output2)
    }

    static func hkdf32(input: Data, salt: Data, info: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: input),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    static func nonce(counter: UInt64) throws -> ChaChaPoly.Nonce {
        var data = Data(repeating: 0, count: 4)
        var littleEndian = counter.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        return try ChaChaPoly.Nonce(data: data)
    }

    static func aeadEncrypt(key: Data, counter: UInt64, aad: Data, plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: nonce(counter: counter),
            authenticating: aad
        )
        var output = box.ciphertext
        output.append(box.tag)
        return output
    }

    static func aeadDecrypt(key: Data, counter: UInt64, aad: Data, combined: Data) throws -> Data {
        guard combined.count >= 16 else { throw CompanionCryptoError.authenticationFailed }
        let ciphertext = combined.dropLast(16)
        let tag = combined.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: nonce(counter: counter),
                ciphertext: ciphertext,
                tag: tag
            )
            return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw CompanionCryptoError.authenticationFailed
        }
    }

    static func sharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublic: Data
    ) throws -> Data {
        guard remotePublic.count == 32 else { throw CompanionCryptoError.invalidDH }
        do {
            let publicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublic)
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: publicKey).withUnsafeBytes { Data($0) }
            guard secret != Data(repeating: 0, count: 32) else { throw CompanionCryptoError.invalidDH }
            return secret
        } catch let error as CompanionCryptoError {
            throw error
        } catch {
            throw CompanionCryptoError.invalidDH
        }
    }

    static func validateIdentifier(_ value: String, label: String) throws -> String {
        guard !value.isEmpty, value.count <= 160,
              value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:@-]{0,159}$"#, options: .regularExpression) != nil else {
            throw CompanionCryptoError.invalidIdentity(label)
        }
        return value
    }

    static func decodeBase64URL(_ value: String, bytes: Int? = nil, label: String) throws -> Data {
        guard let data = Data(base64URLString: value), bytes == nil || data.count == bytes else {
            throw CompanionCryptoError.invalidEncoding(label)
        }
        return data
    }
}
