//===--- LaunchOptions.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Foundation

enum LaunchAction: Equatable {
    case application
    case help
    case version
}

struct LaunchOptions: Equatable {
    var action: LaunchAction = .application
    var safeMode = false
    var projectPath: String?

    static let help = """
    OVERVIEW: SwiftDelta is an interactive Apple-platform upgrade analysis application.

    USAGE: swiftdelta [--safe-mode] [--project <path>]
           swiftdelta --help
           swiftdelta --version

    OPTIONS:
      -h, --help             Show launch help.
      -V, --version          Show the SwiftDelta version.
      --safe-mode            Ignore stored settings and project history.
      --project <path>       Open the TUI with a project directory preselected.

    Analysis, comparison, doctor, repair, cache, and report operations are
    available inside the interactive application. An actual terminal or PTY
    is required.
    """

    static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var result = LaunchOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-h", "--help":
                result.action = .help
            case "-V", "--version":
                result.action = .version
            case "--safe-mode":
                result.safeMode = true
            case "--project":
                index += 1
                guard index < arguments.count else {
                    throw LaunchError(
                        "--project requires a path. Run swiftdelta --help for launch options."
                    )
                }
                let path = arguments[index]
                guard !path.hasPrefix("-") else {
                    throw LaunchError(
                        "--project requires a path. Run swiftdelta --help for launch options."
                    )
                }
                result.projectPath = try validatedProjectPath(path)
            default:
                let former = formerOperationalArguments.contains(argument)
                    || formerOperationalPrefixes.contains {
                        argument.hasPrefix($0)
                    }
                if former {
                    throw LaunchError(
                        "'\(argument)' is now available inside the SwiftDelta "
                            + "interactive application. Run swiftdelta to begin."
                    )
                }
                throw LaunchError(
                    "Unknown launch option '\(argument)'. "
                        + "Run swiftdelta --help for launch options."
                )
            }
            index += 1
        }
        return result
    }

    private static func validatedProjectPath(_ path: String) throws -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw LaunchError(
                "The project path is not an accessible directory: \(path)"
            )
        }
        return url.path
    }

    private static let formerOperationalArguments: Set<String> = [
        "scan", "compare", "repair", "doctor", "cache", "rules", "version",
        "status", "prune", "clear",
    ]

    private static let formerOperationalPrefixes: [String] = [
        "--root", "--config", "--workspace", "--scheme", "--from", "--to",
        "--baseline-xcode", "--candidate-xcode", "--build-configuration",
        "--destination", "--sdk", "--define", "--exclude",
        "--minimum-severity", "--minimum-confidence", "--include-uncertain",
        "--format", "--output", "--timeout", "--fail-on", "--quiet",
        "--allow-incomplete", "--no-sdk-cache", "--refresh-sdk-cache",
        "--file", "--repair-id", "--finding-id", "--plan", "--apply",
        "--foundation-model", "--maximum-age-days", "--maximum-size-mb",
    ]
}

struct LaunchError: Error, Equatable, LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}
