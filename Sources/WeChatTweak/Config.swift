//
//  Config.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/5.
//

import Foundation
import MachO

struct Config: Decodable {
    enum Arch: String, Decodable {
        case arm64
        case x86_64

        var cpu: UInt32 {
            switch self {
            case .arm64:
                return UInt32(CPU_TYPE_ARM64)
            case .x86_64:
                return UInt32(CPU_TYPE_X86_64)
            }
        }
    }

    struct Entry: Decodable {
        let arch: Arch
        let addr: UInt64
        let asm: Data
        /// 可选特征码（hex，支持 `??` 通配）：优先用它在切片里定位补丁点；
        /// 命中唯一时覆盖 addr，命中 0/多 次则回退 addr（再由 expected 校验）。
        let sig: Data?
        let sigMask: Data?
        /// 可选：写入前校验目标处原始字节，不匹配则跳过（防止版本漂移后打错位置）。
        let expected: Data?

        private enum CodingKeys: CodingKey {
            case arch
            case addr
            case asm
            case sig
            case expected
        }

        /// 解析 "5548??e5" 形式 → (bytes, mask)，mask 0xFF=精确、0x00=通配
        static func parseSig(_ s: String) -> (Data, Data)? {
            let hex = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "")
            guard hex.count % 2 == 0, !hex.isEmpty else { return nil }
            var bytes = Data(), mask = Data()
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let end = hex.index(idx, offsetBy: 2)
                let pair = String(hex[idx..<end])
                if pair == "??" {
                    bytes.append(0); mask.append(0)
                } else {
                    guard let v = UInt8(pair, radix: 16) else { return nil }
                    bytes.append(v); mask.append(0xFF)
                }
                idx = end
            }
            return (bytes, mask)
        }

        init(from decoder: any Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            self.arch = try container.decode(Arch.self, forKey: .arch)
            if let sigHex = try container.decodeIfPresent(String.self, forKey: .sig) {
                guard let (b, m) = Entry.parseSig(sigHex) else {
                    throw DecodingError.dataCorruptedError(forKey: .sig, in: container,
                                                           debugDescription: "Invalid Entry.sig")
                }
                self.sig = b; self.sigMask = m
            } else {
                self.sig = nil; self.sigMask = nil
            }
            if let expHex = try container.decodeIfPresent(String.self, forKey: .expected) {
                guard let d = Data(hex: expHex) else {
                    throw DecodingError.dataCorruptedError(forKey: .expected, in: container,
                                                           debugDescription: "Invalid Entry.expected")
                }
                self.expected = d
            } else {
                self.expected = nil
            }
            self.addr = try {
                let hex = try container.decode(String.self, forKey: .addr)
                guard let value = UInt64(hex, radix: 16) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: CodingKeys.addr,
                        in: container,
                        debugDescription: "Invalid Entry.addr"
                    )
                }
                return value
            }()
            self.asm = try {
                let hex = try container.decode(String.self, forKey: .asm)
                guard let value = Data(hex: hex) else {
                    throw DecodingError.dataCorruptedError(
                        forKey: CodingKeys.asm,
                        in: container,
                        debugDescription: "Invalid Entry.asm"
                    )
                }
                return value
            }()
        }
    }

    struct Target: Decodable {
        let identifier: String
        let entries: [Entry]
        let binary: String?

        private enum CodingKeys: CodingKey {
            case identifier
            case entries
            case binary
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.identifier = try container.decode(String.self, forKey: .identifier)
            self.entries = try container.decode([Entry].self, forKey: .entries)
            self.binary = try container.decodeIfPresent(String.self, forKey: .binary)
        }
    }

    let version: String
    let targets: [Target]

    static func load(url: URL) async throws -> [Config] {
        if url.isFileURL {
            return try JSONDecoder().decode(
                [Config].self,
                from: Data(contentsOf: url)
            )
        } else {
            return try JSONDecoder().decode(
                [Config].self,
                from: try await URLSession.shared.data(from: url).0
            )
        }
    }
}

private extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }

        self.init()
        self.reserveCapacity(chars.count / 2)

        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57:  return c - 48       // '0'...'9'
            case 65...70:  return c - 55       // 'A'...'F'
            case 97...102: return c - 87       // 'a'...'f'
            default:       return nil
            }
        }

        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]),
                  let lo = nibble(chars[i + 1]) else { return nil }
            append(hi << 4 | lo)
            i += 2
        }
    }
}
