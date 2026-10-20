import ArgumentParser
import Darwin
import Foundation

extension Tweak {
    struct MiniProgram: ParsableCommand {
        enum Action: String, ExpressibleByArgument {
            case status, prepare
        }

        static let configuration = CommandConfiguration(
            commandName: "mini-program",
            abstract: "Inspect or prepare a copy with the WMPF startup-stall repair."
        )

        @Argument(help: "status inspects files; prepare creates a repaired app copy.")
        var action: Action = .status

        @Option(name: .long, help: "Source application. It is never modified.")
        var app: String = "/Applications/WeChat.app"

        @Option(name: .long, help: "New .app path for prepare; must not already exist.")
        var output: String?

        mutating func run() throws {
            guard let script = Command.firstExistingRuntimeAsset("miniprogram.py") else {
                throw ValidationError("miniprogram.py is missing from the runtime assets.")
            }
            var arguments = ["python3", script.path, action.rawValue, "--app", app]
            if action == .prepare {
                guard let output else {
                    throw ValidationError("prepare requires --output <new-path.app>.")
                }
                arguments += ["--output", output]
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
            Darwin.exit(EXIT_SUCCESS)
        }
    }
}
