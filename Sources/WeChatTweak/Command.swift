//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
import Darwin
import ArgumentParser

struct Command {
    enum Error: @unchecked Sendable, LocalizedError {
        case executing(command: String, error: NSDictionary)

        var errorDescription: String? {
            switch self {
            case let .executing(command, error):
                return "executing: \(command) error: \(error)"
            }
        }
    }

    static func version(app: URL) async throws -> String? {
        try await Command.execute(command: "defaults read \(app.appendingPathComponent("Contents/Info.plist").path) CFBundleVersion")
    }

    /// `patch` 阶段抓到的 entitlements 临时文件，供随后的 `resign` 使用
    nonisolated(unsafe) private static var capturedEntitlements: String?

    static func patch(app: URL, config: Config) async throws {
        let defaultBinary = "Contents/MacOS/WeChat"
        let grouped = Dictionary(grouping: config.targets) { target in
            target.binary ?? defaultBinary
        }

        // 必须在改动任何二进制之前抓 entitlements：
        // 一旦 app 被改动，其签名失效，codesign 就取不到 entitlements 了。
        capturedEntitlements = try await dumpEntitlements(app: app)

        for (binary, targets) in grouped {
            let binaryURL = app.appendingPathComponent(binary)
            let subConfig = Config(version: config.version, targets: targets)
            try Patcher.patch(binary: binaryURL, config: subConfig)

            // 嵌套二进制必须显式重签。`codesign --deep` 不会重签
            // Resources/wechat.dylib 这类大文件（实测 4.1.15+ 会保留腾讯原始签名），
            // 内容一改其嵌入签名即失效，WCDYWrapper 的完整性校验就会让 app 启动失败。
            if binary != defaultBinary {
                try await Command.execute(command: "codesign --force --sign - \(binaryURL.path)")
            }
        }
    }

    static func resign(app: URL) async throws {
        var command = "codesign --force --deep --sign -"
        if let entitlements = capturedEntitlements {
            command += " --entitlements \(entitlements)"
        }
        command += " \(app.path)"
        try await Command.execute(command: command)
        // xattr 清理尽力而为：个别只读文件（如 gpu_shader_cache.bin，mode 444）清不动，
        // 不能因此让整个 patch 失败（此时签名已生效）。用 `; true` 吞掉非零退出。
        try await Command.execute(command: "xattr -cr \(app.path) 2>/dev/null; true")
    }

    /// 运行时组件（libwxrevoketip.dylib / add_load_dylib.py）的搜索目录，覆盖三种布局：
    ///   1. 开发：<repo>/wechattweak 与 <repo>/runtime/build/
    ///   2. 扁平分发（release tarball 解压）：与可执行文件同目录
    ///   3. brew：Cellar/<ver>/bin 与 Cellar/<ver>/libexec（解析符号链接后定位）
    private static func runtimeAssetDirs() -> [URL] {
        var dirs: [URL] = []
        if let override = ProcessInfo.processInfo.environment["WXRT_RUNTIME_DIR"], !override.isEmpty {
            dirs.append(URL(fileURLWithPath: override))
        }
        // 真实可执行文件路径（解析符号链接 → 兼容 brew Cellar 布局）
        var size = UInt32(PATH_MAX)
        var buf = [CChar](repeating: 0, count: Int(size))
        var realBinDir: URL?
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let real = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
            realBinDir = real.deletingLastPathComponent()
        }
        let argvDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for base in [realBinDir, argvDir].compactMap({ $0 }) {
            dirs.append(base)                                         // 扁平：同目录
            dirs.append(base.deletingLastPathComponent()
                .appendingPathComponent("libexec"))                   // brew keg
            dirs.append(base.appendingPathComponent("runtime"))       // 开发
            dirs.append(base.appendingPathComponent("runtime/build")) // 开发
        }
        return dirs
    }

    private static func firstExistingRuntimeAsset(_ name: String) -> URL? {
        let fm = FileManager.default
        return runtimeAssetDirs()
            .map { $0.appendingPathComponent(name) }
            .first { fm.fileExists(atPath: $0.path) }
    }

    /// 安装撤回提示运行时组件：
    /// 1. 把 libwxrevoketip.dylib 拷进 Contents/Resources/
    /// 2. 向主二进制加 LC_LOAD_WEAK_DYLIB（弱依赖，dylib 缺失不影响启动）
    /// 3. 写配置文件（提示模板）到 app 容器可读位置
    /// 注：必须在 resign 之前调用（本函数改主二进制，重签要放在最后）。
    static func installTipRuntime(app: URL, template: String) async throws {
        let fm = FileManager.default

        // 本 dylib 只编了 x86_64；arm64 原生跑微信时弱依赖会被 dyld 静默跳过，功能不生效。
        if let host = try? await Command.execute(command: "uname -m")?
            .trimmingCharacters(in: .whitespacesAndNewlines), host == "arm64" {
            print("⚠️  撤回提示组件目前仅支持 x86_64；本机为 arm64，微信原生运行时该组件不会生效。")
        }

        // 1. 定位随包分发的 dylib
        guard let dylibSrc = firstExistingRuntimeAsset("libwxrevoketip.dylib") else {
            throw Tweak.Error.runtimeDylibNotFound
        }

        // 2. 拷贝到 Resources/
        let dylibDst = app.appendingPathComponent("Contents/Resources/libwxrevoketip.dylib")
        if fm.fileExists(atPath: dylibDst.path) { try fm.removeItem(at: dylibDst) }
        try fm.copyItem(at: dylibSrc, to: dylibDst)

        // 3. 主二进制加 LC_LOAD_WEAK_DYLIB（幂等：已有则跳过）
        let mainBinary = app.appendingPathComponent("Contents/MacOS/WeChat")
        let loadName = "@executable_path/../Resources/libwxrevoketip.dylib"
        let alreadyLinked = try await Command.execute(
            command: "otool -l \(mainBinary.path) | grep -c wxrevoketip || true"
        ) ?? "0"
        if alreadyLinked.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            guard let pySrc = firstExistingRuntimeAsset("add_load_dylib.py") else {
                throw Tweak.Error.runtimeDylibNotFound
            }
            try await Command.execute(
                command: "python3 \(pySrc.path) \(mainBinary.path) '\(loadName)'"
            )
        } else {
            print("Runtime dylib already linked, skip LC injection")
        }

        // 4. 写模板配置。组件按运行时 $HOME 读 ~/wxrevoketip.conf：
        //    - 非沙盒（重签名没带 sandbox entitlement）：$HOME = 真实主目录
        //    - 沙盒（patch 流程会把原始 entitlements 重新签回，含 sandbox）：$HOME 自动映射到容器 Data 目录
        //    两处都写，无论哪种情况组件都能读到模板。
        let homeConf = URL(fileURLWithPath: NSString(string: "~/wxrevoketip.conf").expandingTildeInPath)
        let containerConf = URL(fileURLWithPath: NSString(string: "~/Library/Containers/com.tencent.xinWeChat/Data/wxrevoketip.conf").expandingTildeInPath)
        try FileManager.default.createDirectory(at: containerConf.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = "tip=\(template)\n"
        try content.write(to: homeConf, atomically: true, encoding: .utf8)
        try? content.write(to: containerConf, atomically: true, encoding: .utf8)
        print("Tip template written: \(homeConf.path)")
    }

    /// 把 app 当前的 entitlements 导出到临时文件；取不到时返回 nil
    private static func dumpEntitlements(app: URL) async throws -> String? {
        let path = NSTemporaryDirectory() + "wechattweak-entitlements-\(UUID().uuidString).plist"
        do {
            try await Command.execute(command: "codesign -d --entitlements :- \(app.path) > \(path)")
        } catch {
            return nil
        }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return nil
        }
        return path
    }

    @discardableResult
    private static func execute(command: String) async throws -> String? {
        guard let script = NSAppleScript(source: "do shell script \"\(command)\"") else {
            throw Error.executing(
                command: command,
                error: ["error": "Create script failed."]
            )
        }

        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)

        if let error = error {
            throw Error.executing(
                command: command,
                error: error
            )
        } else {
            return descriptor.stringValue
        }
    }
}
