//
//  Patcher.swift
//  WeChatTweak
//
//  Created by Sunny Young on 2025/12/4.
//

import Darwin
import MachO
import Foundation

struct Patcher {
    enum Error: Swift.Error {
        case invalidFile
        case not64BitMachO(magic: UInt32)
        case vaNotFound(arch: String, va: UInt64)
        case noArchMatched
    }

    /// apply = 写入 `asm`；revert = 写回 `expected`（原始字节）
    enum Mode {
        case apply
        case revert
    }

    static func patch(binary: URL, config: Config) throws {
        try run(binary: binary, config: config, mode: .apply)
    }

    /// 撤销补丁。只有带 `expected` 的条目可撤销（expected 就是它原本的字节）。
    /// 追加安全闸：只在"当前字节 == 本工具写的补丁形态"时才写回，避免误改别的版本。
    static func revert(binary: URL, config: Config) throws {
        try run(binary: binary, config: config, mode: .revert)
    }

    private static func run(binary: URL, config: Config, mode: Mode) throws {
        guard FileManager.default.fileExists(atPath: binary.path) else {
            throw Error.invalidFile
        }

        let entries = config.targets.flatMap { $0.entries }
        guard !entries.isEmpty else { throw Error.noArchMatched }

        // 整文件映射读一遍：特征码扫描需要随机访问切片字节
        let fileData = try Data(contentsOf: binary, options: .mappedIfSafe)

        let fh = try FileHandle(forUpdating: binary)
        defer { try? fh.close() }

        // 读 magic 判断 fat / thin
        guard let magicData = try fh.read(upToCount: 4), magicData.count == 4 else {
            throw Error.invalidFile
        }
        let magicBE = magicData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let isSwappedFat = (magicBE == FAT_CIGAM)

        var patchedCount = 0
        if magicBE == FAT_MAGIC || magicBE == FAT_CIGAM {
            // FAT header: magic(4) + nfat_arch(4)
            guard let nfatData = try fh.read(upToCount: 4), nfatData.count == 4 else {
                throw Error.invalidFile
            }
            let rawNfat = nfatData.withUnsafeBytes { $0.load(as: UInt32.self) }
            let nfat = isSwappedFat ? UInt32(littleEndian: rawNfat) : UInt32(bigEndian: rawNfat)

            // 先读完 fat_arch 表，避免 patch 时移动文件指针影响后续读取
            var archEntries: [(cputype: UInt32, offset: UInt32, size: UInt32)] = []

            for _ in 0..<nfat {
                // fat_arch: cputype(4) cpusub(4) offset(4) size(4) align(4) big-endian
                guard let archData = try fh.read(upToCount: 20), archData.count == 20 else {
                    throw Error.invalidFile
                }
                let rawCpu = archData.withUnsafeBytes { $0.load(fromByteOffset: 0, as: UInt32.self) }
                let rawOff = archData.withUnsafeBytes { $0.load(fromByteOffset: 8, as: UInt32.self) }
                let rawSize = archData.withUnsafeBytes { $0.load(fromByteOffset: 12, as: UInt32.self) }
                let cputype = isSwappedFat ? UInt32(littleEndian: rawCpu) : UInt32(bigEndian: rawCpu)
                let offset  = isSwappedFat ? UInt32(littleEndian: rawOff) : UInt32(bigEndian: rawOff)
                let size    = isSwappedFat ? UInt32(littleEndian: rawSize) : UInt32(bigEndian: rawSize)
                archEntries.append((cputype, offset, size))
            }

            for entry in archEntries {
                let matching = entries.filter { $0.arch.cpu == entry.cputype }
                let sliceVMAddr = sliceBaseVMAddr(fileData: fileData, sliceOffset: UInt64(entry.offset))
                for target in matching {
                    let va = resolveVA(target, sliceVMAddr: sliceVMAddr,
                                       sliceOffset: UInt64(entry.offset),
                                       sliceSize: UInt64(entry.size),
                                       fileData: fileData,
                                       archName: target.arch.rawValue)
                    try patchOneSlice(file: fh,
                                      sliceOffset: UInt64(entry.offset),
                                      targetVA: va,
                                      patch: target.asm,
                                      expected: target.expected,
                                      mode: mode,
                                      archName: target.arch.rawValue)
                    patchedCount += 1
                }
            }
        } else {
            // thin mach-o：回到开头按 mach_header_64 解析（小端）
            try fh.seek(toOffset: 0)
            guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
                throw Error.invalidFile
            }
            let magic = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cputype = hdr.withUnsafeBytes { $0.load(fromByteOffset: 4, as: Int32.self).littleEndian }

            guard magic == MH_MAGIC_64 else {
                throw Error.not64BitMachO(magic: magic)
            }

            let matching = entries.filter { Int32(bitPattern: $0.arch.cpu) == cputype }
            if matching.isEmpty {
                throw Error.noArchMatched
            }

            let fileSize = (try? FileManager.default.attributesOfItem(atPath: binary.path)[.size] as? NSNumber)??.uint64Value ?? 0
            let sliceVMAddr = sliceBaseVMAddr(fileData: fileData, sliceOffset: 0)
            for target in matching {
                let va = resolveVA(target, sliceVMAddr: sliceVMAddr,
                                   sliceOffset: 0, sliceSize: fileSize,
                                   fileData: fileData, archName: target.arch.rawValue)
                try patchOneSlice(file: fh,
                                  sliceOffset: 0,
                                  targetVA: va,
                                  patch: target.asm,
                                  expected: target.expected,
                                  mode: mode,
                                  archName: target.arch.rawValue)
                patchedCount += 1
            }
        }

        if patchedCount <= 0 {
            throw Error.noArchMatched
        }
    }

    // MARK: - 特征码定位

    /// 切片基址 vmaddr（取 fileoff==0 的段，通常是 __TEXT）
    private static func sliceBaseVMAddr(fileData: Data, sliceOffset: UInt64) -> UInt64 {
        guard sliceOffset + 32 <= UInt64(fileData.count) else { return 0 }
        let ncmds = fileData.withUnsafeBytes {
            $0.load(fromByteOffset: Int(sliceOffset) + 16, as: UInt32.self).littleEndian
        }
        var o = Int(sliceOffset) + 32
        for _ in 0..<ncmds {
            guard o + 8 <= fileData.count else { break }
            let (cmd, cmdsize) = fileData.withUnsafeBytes {
                ($0.load(fromByteOffset: o, as: UInt32.self).littleEndian,
                 $0.load(fromByteOffset: o + 4, as: UInt32.self).littleEndian)
            }
            if cmd == LC_SEGMENT_64, o + 32 <= fileData.count {
                let vmaddr = fileData.withUnsafeBytes { $0.load(fromByteOffset: o + 24, as: UInt64.self).littleEndian }
                let fileoff = fileData.withUnsafeBytes { $0.load(fromByteOffset: o + 40, as: UInt64.self).littleEndian }
                if fileoff == 0 { return vmaddr }
            }
            o += Int(cmdsize)
        }
        return 0
    }

    /// 解析补丁点 VA：有特征码则优先用特征码（要求唯一命中），否则回退 addr
    private static func resolveVA(_ e: Config.Entry,
                                  sliceVMAddr: UInt64,
                                  sliceOffset: UInt64,
                                  sliceSize: UInt64,
                                  fileData: Data,
                                  archName: String) -> UInt64 {
        guard let sig = e.sig, let mask = e.sigMask, !sig.isEmpty else { return e.addr }
        let hits = scan(fileData: fileData, range: sliceOffset..<(sliceOffset + sliceSize),
                        sig: sig, mask: mask)
        if hits.count == 1 {
            let va = sliceVMAddr + (UInt64(hits[0]) - sliceOffset)
            let note = va == e.addr ? "== addr" : "!= addr(0x\(String(e.addr, radix: 16)))"
            print("[\(archName)] sig hit @ 0x\(String(va, radix: 16)) \(note)")
            return va
        }
        print("[\(archName)] sig \(hits.isEmpty ? "not found" : "ambiguous(\(hits.count))") → fallback addr 0x\(String(e.addr, radix: 16))")
        return e.addr
    }

    /// 带通配的特征码扫描，返回文件内偏移列表
    private static func scan(fileData: Data, range: Range<UInt64>,
                             sig: Data, mask: Data) -> [Int] {
        let n = sig.count
        let start = Int(range.lowerBound)
        let end = min(Int(range.upperBound), fileData.count)
        guard n > 0, start >= 0, end - start >= n else { return [] }
        var hits: [Int] = []
        fileData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            sig.withUnsafeBytes { (sp: UnsafeRawBufferPointer) in
                mask.withUnsafeBytes { (mp: UnsafeRawBufferPointer) in
                    let s = sp.bindMemory(to: UInt8.self).baseAddress!
                    let m = mp.bindMemory(to: UInt8.self).baseAddress!
                    // 用第 0 字节做快速过滤（要求精确）
                    let anchor = m[0] == 0xFF ? s[0] : nil
                    var i = start
                    let last = end - n
                    while i <= last {
                        if let a = anchor, base[i] != a { i += 1; continue }
                        var ok = true
                        for k in 0..<n where (base[i + k] & m[k]) != (s[k] & m[k]) { ok = false; break }
                        if ok {
                            hits.append(i)
                            if hits.count > 8 { return }   // 明显不唯一，提前退出
                        }
                        i += 1
                    }
                }
            }
        }
        return hits
    }

    // MARK: - 写入

    private static func patchOneSlice(file fh: FileHandle,
                                      sliceOffset: UInt64,
                                      targetVA: UInt64,
                                      patch: Data,
                                      expected: Data?,
                                      mode: Mode,
                                      archName: String) throws {

        // 读 slice 内 mach_header_64
        try fh.seek(toOffset: sliceOffset)
        guard let hdr = try fh.read(upToCount: 32), hdr.count == 32 else {
            throw Error.invalidFile
        }

        let magic   = hdr.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        let ncmds   = hdr.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt32.self).littleEndian }

        guard magic == MH_MAGIC_64 else {
            throw Error.not64BitMachO(magic: magic)
        }

        var lcOffset = sliceOffset + 32

        for _ in 0..<ncmds {
            try fh.seek(toOffset: lcOffset)
            guard let lcHead = try fh.read(upToCount: 8), lcHead.count == 8 else {
                throw Error.invalidFile
            }

            let cmd     = lcHead.withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
            let cmdsize = lcHead.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self).littleEndian }

            if cmd == LC_SEGMENT_64 {
                guard let segData = try fh.read(upToCount: 64), segData.count == 64 else {
                    throw Error.invalidFile
                }

                let vmaddr  = segData.withUnsafeBytes { $0.load(fromByteOffset: 16, as: UInt64.self).littleEndian }
                let vmsize  = segData.withUnsafeBytes { $0.load(fromByteOffset: 24, as: UInt64.self).littleEndian }
                let fileoff = segData.withUnsafeBytes { $0.load(fromByteOffset: 32, as: UInt64.self).littleEndian }

                if vmaddr <= targetVA && targetVA < vmaddr + vmsize {
                    let fileOffset = sliceOffset + fileoff + (targetVA - vmaddr)
                    // 调试用（WXRT_DEBUG=1 打开）；普通用户看不懂这些，默认静音
                    debugLog("[\(archName)] vmaddr=\(String(format: "0x%llx", vmaddr)), fileoff=\(String(format: "0x%llx", fileoff)), sliceoff=\(String(format: "0x%llx", sliceOffset))")
                    debugLog("[\(archName)] patch VA=\(String(format: "0x%llx", targetVA)), fileoff=\(String(format: "0x%llx", fileOffset))")

                    // 读足够长做比较：`patch` 与 `expected` 长度可能不同（如 1B 补丁 vs 4B 原版）
                    let probe = max(patch.count, expected?.count ?? 0)
                    let cur = readBytes(fh, at: fileOffset, count: probe)

                    switch mode {
                    case .apply:
                        // 写入前校验原始字节（防止版本漂移打错位置）
                        if let exp = expected, !exp.isEmpty {
                            if Data(cur.prefix(exp.count)) == exp {
                                // 原版 → 正常写入（继续往下）
                            } else if Data(cur.prefix(patch.count)) == patch {
                                // 已经是本工具打的补丁 → 重复 patch 的正常情况，不是错误
                                print("[\(archName)] 已是补丁状态 @ \(fmt(targetVA)) → 跳过（正常）")
                                return
                            } else {
                                // 既不是原版也不是本工具的补丁 → 版本/地址对不上，不猜，跳过
                                print("[\(archName)] ⚠️ 目标处字节既非原版也非本工具的补丁 @ \(fmt(targetVA))："
                                      + "期望 \(hex(exp))，实际 \(hex(cur)) → 跳过（此版本可能还没适配）")
                                return
                            }
                        }
                        try fh.seek(toOffset: fileOffset)
                        try fh.write(contentsOf: patch)
                        print("[\(archName)] patched @ \(fmt(targetVA)) → \(hex(patch))")

                    case .revert:
                        guard let exp = expected, !exp.isEmpty else {
                            print("[\(archName)] ⚠️ 该条目没有 expected，无法撤销 @ \(fmt(targetVA)) → 跳过")
                            return
                        }
                        if Data(cur.prefix(patch.count)) == patch {
                            // 当前确实是本工具写的补丁形态 → 写回原字节
                            try fh.seek(toOffset: fileOffset)
                            try fh.write(contentsOf: exp)
                            print("[\(archName)] reverted @ \(fmt(targetVA)) → \(hex(exp))")
                        } else if Data(cur.prefix(exp.count)) == exp {
                            print("[\(archName)] already original @ \(fmt(targetVA)) → 跳过")
                        } else {
                            print("[\(archName)] ⚠️ 当前字节既非补丁也非原版 @ \(fmt(targetVA))："
                                  + "实际 \(hex(cur)) → 跳过")
                        }
                    }
                    return
                }
            }

            lcOffset += UInt64(cmdsize)
        }

        throw Error.vaNotFound(arch: archName, va: targetVA)
    }

    // MARK: - 小工具

    /// 调试输出开关：只有设了 WXRT_DEBUG=1 才打印（普通用户不需要看 vmaddr/fileoff 这些）
    private static func debugLog(_ message: String) {
        guard let v = getenv("WXRT_DEBUG"), v.pointee != 0 else { return }
        print(message)
    }

    private static func readBytes(_ fh: FileHandle, at offset: UInt64, count: Int) -> Data {
        try? fh.seek(toOffset: offset)
        return (try? fh.read(upToCount: count)).flatMap { $0 } ?? Data()
    }

    private static func hex(_ d: Data) -> String {
        d.map { String(format: "%02x", $0) }.joined()
    }

    private static func fmt(_ va: UInt64) -> String {
        "0x" + String(va, radix: 16)
    }
}
