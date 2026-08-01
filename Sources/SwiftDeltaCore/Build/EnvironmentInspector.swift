//===--- EnvironmentInspector.swift - SwiftDelta ------------------------------------------===//
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

public struct EnvironmentInspector: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func inspect(
        developerDirectory: String? = nil,
        timeout: TimeInterval = 15
    ) -> EnvironmentSnapshot {
        let environment = developerDirectory.map { ["DEVELOPER_DIR": $0] } ?? [:]
        let xcode = output(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            environment: environment,
            timeout: timeout
        )
        let swift = output(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "--version"],
            environment: environment,
            timeout: timeout
        )
        let sdk = output(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", "macosx", "--show-sdk-version"],
            environment: environment,
            timeout: timeout
        )
        let selectedDirectory = developerDirectory ?? output(
            executable: "/usr/bin/xcode-select",
            arguments: ["-p"],
            environment: [:],
            timeout: timeout
        )

        return EnvironmentSnapshot(
            xcodeVersion: xcode,
            swiftVersion: swift,
            sdkVersion: sdk,
            developerDirectory: selectedDirectory
        )
    }

    private func output(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> String? {
        guard let result = try? runner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: nil,
            timeout: timeout,
            cancellation: { false }
        ), result.exitStatus == 0 else {
            return nil
        }
        return result.standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
