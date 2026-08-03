import CryptoKit
import Foundation

/// Pinned hashes for every model artifact Patchthrough loads on macOS.
/// Downloads are resumable in FluidAudio/WhisperKit; this verifier is the
/// trust boundary and runs after download but before Core ML sees the files.
enum ModelIntegrity {
    struct File: Sendable {
        let path: String
        let sha256: String
    }

    enum Manifest: Sendable {
        case parakeetV2
        case parakeetCTC110M
        case whisperLargeV3Turbo626MB

        var files: [File] {
            switch self {
            case .parakeetV2: return ModelIntegrity.parakeetV2
            case .parakeetCTC110M: return ModelIntegrity.parakeetCTC110M
            case .whisperLargeV3Turbo626MB: return ModelIntegrity.whisperLargeV3Turbo626MB
            }
        }
    }

    enum IntegrityError: Error, CustomStringConvertible {
        case missing(String)
        case mismatch(String)

        var description: String {
            switch self {
            case .missing(let path): return "verified model is missing \(path)"
            case .mismatch(let path): return "model SHA-256 mismatch for \(path)"
            }
        }
    }

    static func verify(_ manifest: Manifest, at directory: URL) throws {
        for expected in manifest.files {
            let url = directory.appendingPathComponent(expected.path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw IntegrityError.missing(expected.path)
            }
            guard try sha256(url) == expected.sha256 else {
                throw IntegrityError.mismatch(expected.path)
            }
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while let data = try input.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static let parakeetV2 = [
        File(path: "Decoder.mlmodelc/analytics/coremldata.bin", sha256: "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05"),
        File(path: "Decoder.mlmodelc/coremldata.bin", sha256: "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8"),
        File(path: "Decoder.mlmodelc/metadata.json", sha256: "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2"),
        File(path: "Decoder.mlmodelc/model.mil", sha256: "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579"),
        File(path: "Decoder.mlmodelc/weights/weight.bin", sha256: "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba"),
        File(path: "Encoder.mlmodelc/analytics/coremldata.bin", sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
        File(path: "Encoder.mlmodelc/coremldata.bin", sha256: "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030"),
        File(path: "Encoder.mlmodelc/metadata.json", sha256: "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63"),
        File(path: "Encoder.mlmodelc/model.mil", sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
        File(path: "Encoder.mlmodelc/weights/weight.bin", sha256: "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e"),
        File(path: "JointDecision.mlmodelc/analytics/coremldata.bin", sha256: "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7"),
        File(path: "JointDecision.mlmodelc/coremldata.bin", sha256: "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11"),
        File(path: "JointDecision.mlmodelc/metadata.json", sha256: "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c"),
        File(path: "JointDecision.mlmodelc/model.mil", sha256: "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0"),
        File(path: "JointDecision.mlmodelc/weights/weight.bin", sha256: "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d"),
        File(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", sha256: "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8"),
        File(path: "Preprocessor.mlmodelc/coremldata.bin", sha256: "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6"),
        File(path: "Preprocessor.mlmodelc/metadata.json", sha256: "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb"),
        File(path: "Preprocessor.mlmodelc/model.mil", sha256: "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e"),
        File(path: "Preprocessor.mlmodelc/weights/weight.bin", sha256: "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc"),
        File(path: "config.json", sha256: "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356"),
        File(path: "parakeet_vocab.json", sha256: "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97"),
    ]

    private static let parakeetCTC110M = [
        File(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "8906c823e9bb3bf6b16d9f0308f98cd70573526333ad85dd767dc3f9ae6b25fa"),
        File(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "a88b002b58193b4c31211754cdfdf220a85f9651dc61caf336ab84400cbc191a"),
        File(path: "AudioEncoder.mlmodelc/metadata.json", sha256: "193c3ec1ac92cf92253ee4aae10d1264143696302547738491c8ae74d5f44023"),
        File(path: "AudioEncoder.mlmodelc/model.mil", sha256: "a632f1bd46c5f309e1304058e0e359afc0df1607f3223dbe7d9baec70e439ca7"),
        File(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "af0734b4a5d7465ad9e8bb170f0c53c5e6b91ebb75a9bdf88d3f59ae4ad6aebd"),
        File(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "22f2a8cba1de25c984050566b534a1d8caf22a82f9fe6c1c6f3149a0dd7e8ae3"),
        File(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "3a32ec67c76aa0aa2faef518413c311493e89aeb7fa11289fa4b8653ab8a160c"),
        File(path: "MelSpectrogram.mlmodelc/metadata.json", sha256: "a93caab3a4004929ce533312939bdaea5da47d2a3d38333c45e49c2b496bb3b5"),
        File(path: "MelSpectrogram.mlmodelc/model.mil", sha256: "645fd4a11ab21a49c1f3bb52ee4f85c68b139517192315b055ec8428d54f3d10"),
        File(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "0a89c055bfde9022029d3cc59a23e949385e063974460d8eaec3a7614c3eaaa8"),
        File(path: "tokenizer.json", sha256: "011cb5e2f3c0a947f5e713d1027e8714fbdc6c9972788befa08e4156c3be9db3"),
        File(path: "vocab.json", sha256: "7282290c0ce1d788b20f75f88550a0ecb2efcbd037334b4c8dd2b2010318104e"),
    ]

    private static let whisperLargeV3Turbo626MB = [
        File(path: "AudioEncoder.mlmodelc/analytics/coremldata.bin", sha256: "56793886ab1adb9ca8a4e335efbe8af6640f40d958ab2d29c3ad2d7d6f712e95"),
        File(path: "AudioEncoder.mlmodelc/coremldata.bin", sha256: "ffa9eb76e8e9d9be75a4d527e5249e61d67fd43081c5aa110fd24efa6c8c5ea3"),
        File(path: "AudioEncoder.mlmodelc/weights/weight.bin", sha256: "e4740fa28ed65907af754af893dfce98473fafb84dd8d718ad346985fe7678c1"),
        File(path: "MelSpectrogram.mlmodelc/analytics/coremldata.bin", sha256: "c5be419f8622083ac7046306400643539f0e7577c843448c36defc090d41e7ce"),
        File(path: "MelSpectrogram.mlmodelc/coremldata.bin", sha256: "2bfc12cffc2e45e039c7a18f384f09adffb72c182fcd93f9413d405d1a6c1130"),
        File(path: "MelSpectrogram.mlmodelc/weights/weight.bin", sha256: "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
        File(path: "TextDecoder.mlmodelc/analytics/coremldata.bin", sha256: "3913b8c9716b284a917cf3744f4d415f2a05e2b910594a14c6cc10092284d3f8"),
        File(path: "TextDecoder.mlmodelc/coremldata.bin", sha256: "3faabaf66930e66956d8291d0ff485fb382496e30a91a7185548b9b898ce90a9"),
        File(path: "TextDecoder.mlmodelc/weights/weight.bin", sha256: "d69700903d518ada33170ab77faaaf464496fb9ff65752c6d5a6109aa2fb02db"),
    ]
}
