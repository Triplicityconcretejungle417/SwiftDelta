//===--- CompilerDiagnosticTests.swift - SwiftDelta ------------------------------------------===//
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

final class CompilerDiagnosticTests: XCTestCase {
    func testStableDiagnosticIdentityKeepsFindingIdentityAcrossMessageChanges()
    {
        let location = SourceLocation(
            path: "/Synthetic/File.swift",
            line: 4,
            column: 2
        )
        let first = CompilerFindingAdapter.findings(
            from: [
                CompilerDiagnostic(
                    message: "first wording",
                    severity: .warning,
                    location: location,
                    diagnosticID: "org.swift.synthetic.warning"
                ),
            ],
            targetVersion: "27"
        )[0]
        let second = CompilerFindingAdapter.findings(
            from: [
                CompilerDiagnostic(
                    message: "revised wording",
                    severity: .warning,
                    location: location,
                    diagnosticID: "org.swift.synthetic.warning"
                ),
            ],
            targetVersion: "27"
        )[0]
        let distinct = CompilerFindingAdapter.findings(
            from: [
                CompilerDiagnostic(
                    message: "first wording",
                    severity: .warning,
                    location: location,
                    diagnosticID: "org.swift.synthetic.other-warning"
                ),
            ],
            targetVersion: "27"
        )[0]

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.findingID, second.findingID)
        XCTAssertNotEqual(first.id, distinct.id)
        XCTAssertNotEqual(first.findingID, distinct.findingID)
    }

func testTextFallbackNormalizesPathsAndEquivalentFormatting() {
        let root = URL(fileURLWithPath: "/Synthetic Project")
        let old = CompilerDiagnosticParser.parse(
            "Sources/File.swift:2:5: warning: 'fictional value' is unavailable.\n",
            projectRoot: root
        )
        let new = CompilerDiagnosticParser.parse(
            "file:///Synthetic%20Project/Sources/File.swift:2:5: warning: `fictional value`   is unavailable\n",
            projectRoot: root
        )

        XCTAssertEqual(old.first?.location?.path, "/Synthetic Project/Sources/File.swift")
        XCTAssertEqual(new.first?.location?.path, "/Synthetic Project/Sources/File.swift")
        XCTAssertTrue(DiagnosticComparator.introduced(old: old, new: new).isEmpty)
    }

func testSwiftPMProgressDiagnosticMergesWithCanonicalLocatedDiagnostic() {
        let path = "/Synthetic Package/Sources/File.swift"
        let diagnostics = CompilerDiagnosticParser.parse(
            """
            warning: \(path):4:10 synthetic candidate-only diagnostic
            \(path):4:10: warning: synthetic candidate-only diagnostic
            """,
            projectRoot: URL(fileURLWithPath: "/Synthetic Package")
        )

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics.first?.message, "synthetic candidate-only diagnostic")
        XCTAssertEqual(diagnostics.first?.location?.path, path)
        XCTAssertEqual(diagnostics.first?.location?.line, 4)
        XCTAssertEqual(diagnostics.first?.location?.column, 10)
    }

func testCompilerDiagnosticsBecomeHighConfidenceEvidenceWithoutInventedAdvice() {
        let findings = CompilerFindingAdapter.findings(
            from: [
                CompilerDiagnostic(
                    message: "no such module 'FictionalDependency'",
                    severity: .error,
                    location: SourceLocation(path: "/Synthetic/File.swift", line: 1),
                    kind: .module
                ),
            ],
            targetVersion: "17.0"
        )

        XCTAssertEqual(findings.first?.findingID, "compiler.module")
        XCTAssertEqual(findings.first?.confidence, .high)
        XCTAssertNil(findings.first?.migrationMessage)
    }

    func testTextFallbackPreservesErrorsWarningsNotesAndRemarks() {
        let diagnostics = CompilerDiagnosticParser.parse(
            """
            /Synthetic/File.swift:1:1: error: fictional error
            /Synthetic/File.swift:2:1: warning: fictional warning
            /Synthetic/File.swift:3:1: note: fictional note
            /Synthetic/File.swift:4:1: remark: fictional remark
            """
        )

        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: diagnostics.map {
                ($0.message, $0.severity)
            }),
            [
                "fictional error": .error,
                "fictional warning": .warning,
                "fictional note": .notice,
                "fictional remark": .notice,
            ]
        )
    }

    func testConflictingDuplicateDiagnosticsRetainAuthoritativeError() {
        let location = SourceLocation(
            path: "/Synthetic/File.swift",
            line: 1,
            column: 1
        )
        let diagnostics = CompilerDiagnosticParser.deduplicate([
            CompilerDiagnostic(
                message: "fictional diagnostic",
                severity: .error,
                location: location
            ),
            CompilerDiagnostic(
                message: "fictional diagnostic",
                severity: .warning,
                location: location
            ),
            CompilerDiagnostic(
                message: "fictional diagnostic",
                severity: .notice,
                location: location
            ),
        ])

        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(diagnostics[0].severity, .error)
    }

    func testDiagnosticSeverityTransitionsAreDirectional() {
        let location = SourceLocation(path: "/Synthetic/File.swift", line: 4)
        func diagnostic(_ severity: Severity) -> CompilerDiagnostic {
            CompilerDiagnostic(
                message: "fictional diagnostic",
                severity: severity,
                location: location,
                diagnosticID: "fictional.id"
            )
        }

        XCTAssertEqual(
            DiagnosticComparator.introduced(
                old: [diagnostic(.warning)],
                new: [diagnostic(.error)]
            ).map(\.severity),
            [.error]
        )
        XCTAssertTrue(
            DiagnosticComparator.introduced(
                old: [diagnostic(.error)],
                new: [diagnostic(.warning)]
            ).isEmpty
        )
        XCTAssertTrue(
            DiagnosticComparator.introduced(
                old: [diagnostic(.warning)],
                new: [diagnostic(.notice)]
            ).isEmpty
        )
    }

    func testStableDiagnosticIdentitySurvivesMessageEvolution() {
        let location = SourceLocation(
            path: "/Synthetic/File.swift",
            line: 8,
            column: 4
        )
        let baseline = CompilerDiagnostic(
            message: "earlier wording",
            severity: .warning,
            location: location,
            target: "SyntheticApp",
            diagnosticID: "fictional.stable.id"
        )
        let candidate = CompilerDiagnostic(
            message: "new wording with additional context",
            severity: .warning,
            location: location,
            target: "SyntheticApp",
            diagnosticID: "fictional.stable.id"
        )

        XCTAssertTrue(
            DiagnosticComparator.introduced(
                old: [baseline],
                new: [candidate]
            ).isEmpty
        )
    }

    func testGeneratedDiagnosticPathsMatchAcrossIsolatedBuildRoots() {
        let baseline = CompilerDiagnostic(
            message: "fictional generated warning",
            severity: .warning,
            location: SourceLocation(
                path:
                    "/tmp/baseline/DerivedData/Build/Intermediates.noindex/Fictional.build/Generated.swift",
                line: 2
            )
        )
        let candidate = CompilerDiagnostic(
            message: "fictional generated warning",
            severity: .warning,
            location: SourceLocation(
                path:
                    "/tmp/candidate/DerivedData/Build/Intermediates.noindex/Fictional.build/Generated.swift",
                line: 2
            )
        )

        XCTAssertTrue(
            DiagnosticComparator.introduced(
                old: [baseline],
                new: [candidate]
            ).isEmpty
        )
    }
}
