//===--- ProcessRunnerTests.swift - SwiftDelta ------------------------------------------===//
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
import SwiftDeltaCore
import XCTest

final class ProcessRunnerTests: XCTestCase {
    func testArgumentsWithSpacesUnicodeAndShellCharactersArePassedLiterally() throws {
        let value = "路径 with spaces; $(not-executed) 'quoted'"
        let result = try ProcessRunner().run(
            executable: "/usr/bin/printf",
            arguments: ["%s", value],
            timeout: 5
        )

        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.standardOutputString, value)
    }

    func testNonzeroProcessStatusIsCaptured() throws {
        let result = try ProcessRunner().run(
            executable: "/usr/bin/false",
            arguments: [],
            timeout: 5
        )

        XCTAssertNotEqual(result.exitStatus, 0)
    }

    func testTimeoutAndCancellationAreDistinct() throws {
        XCTAssertThrowsError(
            try ProcessRunner().run(
                executable: "/bin/sleep",
                arguments: ["2"],
                environment: [:],
                workingDirectory: nil,
                timeout: 0.05,
                cancellation: { false }
            )
        ) { error in
            guard case SwiftDeltaError.processTimedOut = error else {
                return XCTFail("Expected timeout, received \(error)")
            }
        }
        XCTAssertThrowsError(
            try ProcessRunner().run(
                executable: "/bin/sleep",
                arguments: ["2"],
                environment: [:],
                workingDirectory: nil,
                timeout: 5,
                cancellation: { true }
            )
        ) { error in
            guard case SwiftDeltaError.processCancelled = error else {
                return XCTFail("Expected cancellation, received \(error)")
            }
        }

    }

    func testSecretRedactionDoesNotExposeValues() {
        let source = "ACCESS_TOKEN=top-secret OTHER=value PASSWORD = hunter2"
        let redacted = SecretRedactor.redact(source)

        XCTAssertFalse(redacted.contains("top-secret"))
        XCTAssertFalse(redacted.contains("hunter2"))
        XCTAssertTrue(redacted.contains("ACCESS_TOKEN=<redacted>"))
        XCTAssertTrue(redacted.contains("PASSWORD=<redacted>"))
    }

    func testToolchainSelectionVariablesAreNotInherited() throws {
        let runner = ProcessRunner()
        let result = try runner.run(
            executable: "/usr/bin/env",
            arguments: [],
            environment: [
                "DEVELOPER_DIR": "/Synthetic/Selected.app/Contents/Developer",
            ],
            timeout: 10
        )
        let output = result.standardOutputString

        XCTAssertTrue(
            output.contains(
                "DEVELOPER_DIR=/Synthetic/Selected.app/Contents/Developer"
            )
        )
        XCTAssertFalse(output.contains("SDKROOT="))
        XCTAssertFalse(output.contains("TOOLCHAINS="))
    }

    func testProcessUsesPrivateHomeTemporaryAndCacheDirectories() throws {
        let parentHome = FileManager.default.homeDirectoryForCurrentUser.path
        let result = try ProcessRunner().run(
            executable: "/usr/bin/env",
            arguments: [],
            timeout: 10
        )
        let values = Dictionary(
            uniqueKeysWithValues: result.standardOutputString
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> (String, String)? in
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { return nil }
                    return (String(parts[0]), String(parts[1]))
                }
        )

        XCTAssertNotEqual(values["HOME"], parentHome)
        XCTAssertEqual(values["CFFIXED_USER_HOME"], values["HOME"])
        XCTAssertTrue(values["TMPDIR"]?.contains("swiftdelta-process-") == true)
        XCTAssertTrue(values["XDG_CACHE_HOME"]?.contains("swiftdelta-process-") == true)
        XCTAssertNil(values["DEVELOPER_DIR"])
        XCTAssertNil(values["SDKROOT"])
        XCTAssertNil(values["TOOLCHAINS"])
    }

    func testTemporaryDirectoryCleanupIsIdempotent() throws {
        let directory = try TemporaryDirectory(prefix: "swiftdelta-cleanup-test")
        let path = directory.url.path
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        directory.remove()
        directory.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
}
