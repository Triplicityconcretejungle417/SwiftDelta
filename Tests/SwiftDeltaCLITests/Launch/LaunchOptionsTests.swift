//===--- LaunchOptionsTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDelta
import SwiftDeltaCore
import XCTest

final class LaunchOptionsTests: XCTestCase {
    func testNoArgumentsLaunchesInteractiveApplication() throws {
        XCTAssertEqual(
            try LaunchOptions.parse([]),
            LaunchOptions(action: .application, safeMode: false, projectPath: nil)
        )
    }

    func testHelpVersionAndAliasesRemainNoninteractive() throws {
        XCTAssertEqual(try LaunchOptions.parse(["--help"]).action, .help)
        XCTAssertEqual(try LaunchOptions.parse(["-h"]).action, .help)
        XCTAssertEqual(try LaunchOptions.parse(["--version"]).action, .version)
        XCTAssertEqual(try LaunchOptions.parse(["-V"]).action, .version)
        XCTAssertTrue(LaunchOptions.help.contains("--safe-mode"))
        XCTAssertTrue(LaunchOptions.help.contains("--project <path>"))
        XCTAssertFalse(LaunchOptions.help.contains("<subcommand>"))
    }

    func testSafeModeAndProjectPreselectionComposeWithoutStartingWork() throws {
        let directory = try TUITestDirectory()
        let parsed = try LaunchOptions.parse([
            "--safe-mode", "--project", directory.url.path,
        ])

        XCTAssertEqual(parsed.action, .application)
        XCTAssertTrue(parsed.safeMode)
        XCTAssertEqual(parsed.projectPath, directory.url.path)
    }

    func testProjectPreselectionRejectsMissingPath() {
        XCTAssertThrowsError(
            try LaunchOptions.parse(["--project", "/tmp/does-not-exist-\(UUID())"])
        )
        XCTAssertThrowsError(try LaunchOptions.parse(["--project"]))
    }

    func testEveryFormerOperationalCommandIsRejectedWithTUIInstruction() {
        for command in [
            "scan", "compare", "repair", "doctor", "cache", "rules",
            "version", "status", "prune", "clear",
        ] {
            XCTAssertThrowsError(try LaunchOptions.parse([command])) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "interactive application"
                    ),
                    "\(command): \(error)"
                )
            }
        }
    }

    func testFormerOperationalOptionsAndUnknownOptionsAreRejected() {
        for option in [
            "--root", "--config", "--from", "--to", "--sdk",
            "--destination", "--format", "--output", "--apply",
            "--foundation-model", "--maximum-age-days",
        ] {
            XCTAssertThrowsError(try LaunchOptions.parse([option])) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains(
                        "interactive application"
                    )
                )
            }
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["--imaginary"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Unknown"))
        }
    }

    func testVersionValueIsOnePointZero() {
        XCTAssertEqual(SwiftDeltaVersion.current, "1.0.0")
    }
}
