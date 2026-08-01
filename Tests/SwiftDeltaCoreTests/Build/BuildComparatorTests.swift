//===--- BuildComparatorTests.swift - SwiftDelta ------------------------------------------===//
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

final class BuildComparatorTests: XCTestCase {
func testComparisonDeduplicatesDiagnosticsAndReportsBuildSettingEvidence() throws {
        let directory = try TestDirectory(name: "comparison")
        let oldXcode = try makeSyntheticXcode(in: directory, name: "Xcode-old")
        let newXcode = try makeSyntheticXcode(in: directory, name: "Xcode-new")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let shared = CompilerDiagnostic(
            message: "existing warning",
            severity: .warning,
            location: SourceLocation(path: "/Synthetic/File.swift", line: 2, column: 1)
        )
        let introduced = CompilerDiagnostic(
            message: "new compiler failure",
            severity: .error,
            location: SourceLocation(path: "/Synthetic/File.swift", line: 4, column: 3)
        )
        let builder = RecordingBuilder(
            outcomes: [
                BuildOutcome(
                    xcodePath: oldXcode.path,
                    exitStatus: 0,
                    diagnostics: [shared],
                    buildSettings: [
                        BuildSettingsSnapshot(
                            target: "SyntheticTarget",
                            configuration: "Debug",
                            settings: ["SWIFT_STRICT_CONCURRENCY": "minimal"]
                        ),
                    ]
                ),
                BuildOutcome(
                    xcodePath: newXcode.path,
                    exitStatus: 1,
                    diagnostics: [shared, introduced, introduced],
                    buildSettings: [
                        BuildSettingsSnapshot(
                            target: "SyntheticTarget",
                            configuration: "Debug",
                            settings: ["SWIFT_STRICT_CONCURRENCY": "complete"]
                        ),
                    ]
                ),
            ]
        )
        let staticFinding = Finding(
            findingID: "sdk.synthetic",
            category: .sdk,
            title: "Synthetic SDK finding",
            explanation: "Synthetic SDK evidence.",
            severity: .notice,
            confidence: .high,
            origin: .sdk
        )
        let invocation = { (xcode: URL) in
            BuildInvocation(
                xcodePath: xcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "SyntheticTarget"
            )
        }

        let result = try BuildComparator(builder: builder).compare(
            old: invocation(oldXcode),
            new: invocation(newXcode),
            staticFindings: [staticFinding]
        )

        XCTAssertEqual(builder.invocations.count, 2)
        XCTAssertEqual(result.introducedDiagnostics, [introduced])
        XCTAssertEqual(result.buildSettingDifferences.map(\.name), ["SWIFT_STRICT_CONCURRENCY"])
        XCTAssertTrue(result.findings.contains { $0.findingID == "compiler.compiler" })
        XCTAssertTrue(
            result.findings.contains {
                $0.findingID == "build-setting.changed.SWIFT_STRICT_CONCURRENCY"
            }
        )
        XCTAssertTrue(result.findings.contains { $0.findingID == "sdk.synthetic" })
    }

    func testComparisonStopsWhenBaselineDoesNotBuild() throws {
        let directory = try TestDirectory(name: "baseline-failure")
        let oldXcode = try makeSyntheticXcode(in: directory, name: "Xcode-old")
        let newXcode = try makeSyntheticXcode(in: directory, name: "Xcode-new")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let builder = RecordingBuilder(
            outcomes: [
                BuildOutcome(
                    xcodePath: oldXcode.path,
                    exitStatus: 1,
                    diagnostics: [
                        CompilerDiagnostic(
                            message: "synthetic baseline failure",
                            severity: .error
                        ),
                    ],
                    buildSettings: []
                ),
                BuildOutcome(
                    xcodePath: newXcode.path,
                    exitStatus: 0,
                    diagnostics: [],
                    buildSettings: []
                ),
            ]
        )

        XCTAssertThrowsError(
            try BuildComparator(builder: builder).compare(
                old: BuildInvocation(
                    xcodePath: oldXcode.path,
                    container: ProjectContainer(kind: .project, path: project.path),
                    scheme: "Synthetic"
                ),
                new: BuildInvocation(
                    xcodePath: newXcode.path,
                    container: ProjectContainer(kind: .project, path: project.path),
                    scheme: "Synthetic"
                )
            )
        ) { error in
            guard case SwiftDeltaError.buildFailed = error else {
                return XCTFail("Expected baseline build failure, received \(error)")
            }
        }
        XCTAssertEqual(builder.invocations.count, 1)
    }

    func testIntroducedCompilerWarningRetainsWarningSeverity() throws {
        let directory = try TestDirectory(name: "warning-severity")
        let oldXcode = try makeSyntheticXcode(in: directory, name: "Xcode-old")
        let newXcode = try makeSyntheticXcode(in: directory, name: "Xcode-new")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let warning = CompilerDiagnostic(
            message: "Unnecessary platform availability check",
            severity: .warning,
            location: SourceLocation(path: "/Synthetic/File.swift", line: 4)
        )
        let builder = RecordingBuilder(
            outcomes: [
                BuildOutcome(
                    xcodePath: oldXcode.path,
                    exitStatus: 0,
                    diagnostics: [],
                    buildSettings: []
                ),
                BuildOutcome(
                    xcodePath: newXcode.path,
                    exitStatus: 0,
                    diagnostics: [warning],
                    buildSettings: []
                ),
            ]
        )

        let result = try BuildComparator(builder: builder).compare(
            old: BuildInvocation(
                xcodePath: oldXcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "Synthetic"
            ),
            new: BuildInvocation(
                xcodePath: newXcode.path,
                container: ProjectContainer(kind: .project, path: project.path),
                scheme: "Synthetic"
            )
        )

        XCTAssertEqual(result.introducedDiagnostics.first?.severity, .warning)
        XCTAssertEqual(
            result.findings.first { $0.origin == .compiler }?.severity,
            .warning
        )
    }

    func testCandidateEnvironmentFailureIsNotACompatibilityFinding() throws {
        let directory = try TestDirectory(name: "candidate-environment-failure")
        let oldXcode = try makeSyntheticXcode(in: directory, name: "Xcode-old")
        let newXcode = try makeSyntheticXcode(in: directory, name: "Xcode-new")
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        let builder = RecordingBuilder(
            outcomes: [
                BuildOutcome(
                    xcodePath: oldXcode.path,
                    exitStatus: 0,
                    diagnostics: [],
                    buildSettings: []
                ),
                BuildOutcome(
                    xcodePath: newXcode.path,
                    exitStatus: 70,
                    diagnostics: [
                        CompilerDiagnostic(
                            message:
                                "Destination selection failed with Xcode 27.0 for "
                                + "Synthetic.xcodeproj, scheme Synthetic, SDK iphoneos, "
                                + "destination generic/platform=iOS.",
                            severity: .error,
                            kind: .buildPhase
                        ),
                    ],
                    buildSettings: []
                ),
            ]
        )

        XCTAssertThrowsError(
            try BuildComparator(builder: builder).compare(
                old: BuildInvocation(
                    xcodePath: oldXcode.path,
                    container: ProjectContainer(kind: .project, path: project.path),
                    scheme: "Synthetic"
                ),
                new: BuildInvocation(
                    xcodePath: newXcode.path,
                    container: ProjectContainer(kind: .project, path: project.path),
                    scheme: "Synthetic"
                )
            )
        ) { error in
            guard case SwiftDeltaError.buildFailed = error else {
                return XCTFail("Expected environment build failure, received \(error)")
            }
        }
    }
}

private final class RecordingBuilder: ProjectBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [BuildOutcome]
    private var recorded: [BuildInvocation] = []

    init(outcomes: [BuildOutcome]) {
        remaining = outcomes
    }

    var invocations: [BuildInvocation] {
        lock.withLock { recorded }
    }

    func build(
        _ invocation: BuildInvocation,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> BuildOutcome {
        try lock.withLock {
            recorded.append(invocation)
            guard !remaining.isEmpty else {
                throw SwiftDeltaError.processFailed(
                    executable: "synthetic-builder",
                    status: 1,
                    message: "missing synthetic outcome"
                )
            }
            return remaining.removeFirst()
        }
    }
}
