//===--- RealXCResultIntegrationTests.swift - SwiftDelta ------------------------------------------===//
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

final class RealXCResultIntegrationTests: XCTestCase {
func testRealCandidateXCResultDiagnosticParsing() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-candidate-xcresult")
        let fixture = try makeSyntheticXcodeProject(in: directory)
        let outcome = try XcodeProjectBuilder().build(
            BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(
                    kind: .project,
                    path: fixture.project.path
                ),
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            cancellation: { false }
        )

        XCTAssertTrue(
            outcome.succeeded,
            "Build diagnostics: \(outcome.diagnostics)"
        )
        XCTAssertEqual(outcome.diagnosticSource, .modernXCResult)
        let warning = outcome.diagnostics.first {
                $0.message.lowercased()
                    .contains("synthetic candidate-only project diagnostic")
            }
        XCTAssertNotNil(
            warning,
            "Structured diagnostics: \(outcome.diagnostics)"
        )
        XCTAssertEqual(
            warning?.severity,
            .warning,
            "Structured diagnostics: \(outcome.diagnostics)"
        )
    }

    func testRealCandidateXCResultPreservesCompilerErrorSeverity() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-candidate-xcresult-error")
        let fixture = try makeSyntheticXcodeProject(
            in: directory,
            candidateOnlyWarning: false
        )
        try Data(
            """
            public func syntheticFailure() {
                let value: Int = "fictional"
                _ = value
            }
            """.utf8
        ).write(to: fixture.source)

        let outcome = try XcodeProjectBuilder().build(
            BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(
                    kind: .project,
                    path: fixture.project.path
                ),
                scheme: fixture.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            cancellation: { false }
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(
            outcome.diagnostics.contains {
                $0.severity == .error
                    && $0.location?.path == fixture.source.path
            },
            "Structured diagnostics: \(outcome.diagnostics)"
        )
    }
}
