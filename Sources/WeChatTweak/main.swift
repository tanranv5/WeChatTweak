//
//  main.swift
//
//  Created by Sunny Young.
//

import Foundation
import Dispatch
import ArgumentParser

// MARK: Versions
extension Tweak {
    struct Versions: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List all supported WeChat versions")

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            print("------ Current version ------")
            print(try await Command.version(app: options.app) ?? "unknown")
            print("------ Supported versions ------")
            try await Config.load(url: options.config).forEach({ print($0.version) })
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Patch
extension Tweak {
    struct Patch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Patch WeChat.app")

        @OptionGroup
        var options: Tweak.Options

        @Flag(
            name: .long,
            help: "Install revoke-tip runtime component (shows [intercepted] tip with original message)"
        )
        var tip: Bool = false

        @Option(
            name: .long,
            help: "Custom tip template. Placeholders: {from} {time} {content} {marker}",
            completion: .file()
        )
        var tipTemplate: String = "[已拦截] {from} 撤回了：{content}"

        @Flag(
            name: .long,
            inversion: .prefixedNo,
            help: "屏蔽微信自动更新（**默认开启**）。加 --no-block-update 关闭，并撤销已打的屏蔽，让微信可重新自动升级"
        )
        var blockUpdate: Bool = true

        mutating func run() async throws {
            print("------ Version ------")
            let version = try await Command.version(app: options.app)
            print("WeChat version: \(version ?? "unknown")")

            print("------ Config ------")
            guard let config = (try await Config.load(url: options.config)).first(where: { $0.version == version }) else {
                throw Error.unsupportedVersion
            }
            print("Matched config: \(config)")

            // 屏蔽自动更新是默认行为；--no-block-update 时不仅不打，还会撤销已打的
            let targets = blockUpdate
                ? config.targets
                : config.targets.filter { $0.identifier != "blockUpdate" }
            if blockUpdate {
                let present = config.targets.contains { $0.identifier == "blockUpdate" }
                print("Block auto-update: enabled\(present ? "(默认)" : "(该版本 config 无此 target，跳过)")")
            } else {
                print("Block auto-update: disabled (--no-block-update) → 将撤销已打的屏蔽")
            }
            let effectiveConfig = Config(version: config.version, targets: targets)

            print("------ Patch ------")
            try await Command.patch(
                app: options.app,
                config: effectiveConfig
            )
            print("Done!")

            if !blockUpdate {
                print("------ Allow Update (revert blockUpdate) ------")
                try await Command.revertBlockUpdate(app: options.app, config: config)
                print("Done! (微信可重新自动升级；升级后 app 会被官方版本替换，需重新 patch)")
            }

            if tip {
                print("------ Revoke Tip Runtime ------")
                try await Command.installTipRuntime(
                    app: options.app,
                    template: tipTemplate
                )
                print("Done! (reboot WeChat to take effect; log at container Data/wxrevoketip.log)")
            }

            print("------ Resign ------")
            try await Command.resign(
                app: options.app
            )
            print("Done!")

            Darwin.exit(EXIT_SUCCESS)
        }
    }

}

// MARK: Restore
extension Tweak {
    struct Restore: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Restore WeChat.app to the official original from backup",
            discussion: "还原 patch 时自动备份的原版二进制，并移除注入的运行时组件。微信恢复官方签名，可直接启动。"
        )

        @OptionGroup
        var options: Tweak.Options

        mutating func run() async throws {
            try await Command.restore(app: options.app)
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}

// MARK: Tweak
struct Tweak: AsyncParsableCommand {
    enum Error: LocalizedError {
        case invalidApp
        case invalidConfig
        case invalidVersion
        case unsupportedVersion
        case runtimeDylibNotFound
        case backupNotFound(version: String, path: String)
        case backupSourceTainted(path: String)

        var errorDescription: String? {
            switch self {
            case .invalidApp:
                return "Invalid app path"
            case .invalidConfig:
                return "Invalid patch config"
            case .invalidVersion:
                return "Invalid app version"
            case .unsupportedVersion:
                return "Unsupported WeChat version"
            case .runtimeDylibNotFound:
                return "libwxrevoketip.dylib / add_load_dylib.py not found (build with: cd runtime && ./build.sh)"
            case let .backupNotFound(version, path):
                return "No backup for WeChat \(version) at \(path).\n备份在 patch 时自动创建；若此 app 从未用本工具 patch 过，无需还原。"
            case let .backupSourceTainted(path):
                return "Refusing to back up \(path): it already contains injected components (not pristine).\n这个 app 已被打过补丁且无原版备份，无法为其创建备份。请从官方安装包恢复后再 patch。"
            }
        }
    }

    struct Options: ParsableArguments {
        @Option(
            name: .shortAndLong,
            help: "Path of WeChat.app",
            transform: {
                guard FileManager.default.fileExists(atPath: $0) else {
                    throw Error.invalidApp
                }
                return URL(fileURLWithPath: $0)
            }
        )
        var app: URL = URL(fileURLWithPath: "/Applications/WeChat.app", isDirectory: true)

        @Option(
            name: .shortAndLong,
            help: "Local path or Remote URL of config.json",
            transform: {
                if FileManager.default.fileExists(atPath: $0) {
                    return URL(fileURLWithPath: $0)
                } else {
                    guard let url = URL(string: $0) else {
                        throw Error.invalidConfig
                    }
                    return url
                }
            }
        )
        var config: URL = URL(string:"https://raw.githubusercontent.com/tanranv5/WeChatTweak/master/config.json")!
    }

    static let configuration = CommandConfiguration(
        commandName: "wechattweak",
        abstract: "A command-line tool for tweaking WeChat.",
        subcommands: [
            Versions.self,
            Patch.self,
            Restore.self
        ]
    )

    mutating func run() async throws {
        print(Tweak.helpMessage())
        Darwin.exit(EXIT_SUCCESS)
    }
}

Task {
    await Tweak.main()
}

Dispatch.dispatchMain()
