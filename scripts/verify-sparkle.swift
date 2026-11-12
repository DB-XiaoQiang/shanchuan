import Foundation
import CryptoKit

// Only public verification material enters arguments. No keychain or private key access.
guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64,
      let rawKey = Data(base64Encoded: CommandLine.arguments[3]), rawKey.count == 32 else {
    fputs("Sparkle 签名或公钥格式无效。\n", stderr)
    exit(1)
}
do {
    let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]), options: .mappedIfSafe)
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
    guard key.isValidSignature(signature, for: archive) else {
        fputs("Sparkle 签名与应用内公钥不匹配。\n", stderr)
        exit(1)
    }
    print("Sparkle 更新包与内置公钥验签通过")
} catch {
    fputs("Sparkle 更新包验签失败。\n", stderr)
    exit(1)
}
