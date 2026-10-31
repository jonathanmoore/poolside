import Foundation
import CommonCrypto

/// Remote logins send the password AES-encrypted (ECB, no padding) with the password,
/// zero-padded to 16 or 32 bytes, as the key and the gateway's challenge string as the
/// plaintext. The gateway only reads the first 16 bytes, which is all we send.
/// Matches node-screenlogic's HLEncoder test vector: password "1234", challenge
/// "00-00-00-00-00-00" -> 4e717f2effdafd5ddf34263223d71106.
enum SLPassword {
    static func encrypt(password: String, challenge: String) -> Data? {
        let pw = Array(password.utf8)
        guard !pw.isEmpty, pw.count <= 32 else { return nil }
        let keyLength = pw.count <= 16 ? kCCKeySizeAES128 : kCCKeySizeAES256
        let key = pw + [UInt8](repeating: 0, count: keyLength - pw.count)

        var block = Array(challenge.utf8.prefix(16))
        block += [UInt8](repeating: 0, count: 16 - block.count)

        var out = [UInt8](repeating: 0, count: 16)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionECBMode),
                             key, keyLength, nil,
                             block, 16,
                             &out, 16, &written)
        guard status == CCCryptorStatus(kCCSuccess), written == 16 else { return nil }
        return Data(out)
    }
}
