import ArgumentParser
import Darwin
import Foundation

extension Tweak {
    struct HotPatch: ParsableCommand {
        enum Action: String, ExpressibleByArgument {
            case status, prepare
        }

        static let configuration = CommandConfiguration(
            commandName: "hot-patch",
            abstract: "Inspect or prepare a separate app with the Magic/Magicdy guard."
        )

        @Argument(help: "status reads the source; prepare creates a separate guarded app.")
        var action: Action = .status

        @Option(name: .long, help: "Source application. It is never modified.")
        var app: String = "/Applications/WeChat.app"

        @Option(name: .long, help: "New .app path for prepare; must not already exist.")
        var output: String?

        mutating func run() throws {
            guard let script = Command.firstExistingRuntimeAsset("hotpatch.py") else {
                throw ValidationError("hotpatch.py is missing from the runtime assets.")
            }
            var arguments = ["python3", script.path, action.rawValue, "--app", app]
            if action == .prepare {
                guard let output else {
                    throw ValidationError("prepare requires --output <new-path.app>.")
                }
                guard let library = Command.firstExistingRuntimeAsset("libwxhotpatchguard.dylib") else {
                    throw ValidationError("Build the guard with: make hotpatch-runtime")
                }
                arguments += ["--output", output, "--library", library.path]
            } else if output != nil {
                throw ValidationError("--output is only valid with prepare.")
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw ExitCode.failure
            }
            // The executable starts its command tree from a Task and keeps a
            // Dispatch main loop alive (see main.swift), so success must exit.
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}
