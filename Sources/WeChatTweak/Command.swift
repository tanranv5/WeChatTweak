//
//  Command.swift
//
//  Created by Sunny Young.
//

import Foundation
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
        try await Command.execute(command: "xattr -cr \(app.path)")
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
