//===--- SwiftDeltaCommand.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
import SwiftDeltaCore

@main
public enum SwiftDeltaCommand {
    public static func main() {
        do {
            let launch = try LaunchOptions.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            switch launch.action {
            case .help:
                FileHandle.standardOutput.write(
                    Data((LaunchOptions.help + "\n").utf8)
                )
            case .version:
                FileHandle.standardOutput.write(
                    Data("SwiftDelta \(SwiftDeltaVersion.current)\n".utf8)
                )
            case .application:
                let status = try TUIApplication(launch: launch).run()
                Darwin.exit(status)
            }
        } catch let error as LaunchError {
            FileHandle.standardError.write(Data((error.message + "\n").utf8))
            Darwin.exit(2)
        } catch {
            FileHandle.standardError.write(
                Data("SwiftDelta could not start: \(error.localizedDescription)\n".utf8)
            )
            Darwin.exit(2)
        }
    }
}
