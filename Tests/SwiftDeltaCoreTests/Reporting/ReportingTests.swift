//===--- ReportingTests.swift - SwiftDelta ------------------------------------------===//
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

final class ReportingTests: XCTestCase {
func testTerminalJSONAndSARIFContainSDKEvidence() throws {
        let baseline = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode-Old.app",
            developerDirectory: "/Synthetic/Xcode-Old.app/Contents/Developer",
            xcodeVersion: "16.0",
            xcodeBuild: "16A100",
            platform: "SyntheticOS",
            sdkIdentifier: "syntheticos",
            sdkVersion: "20.0",
            sdkPath: "/Synthetic/SDK20.sdk"
        )
        let candidate = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode-New.app",
            developerDirectory: "/Synthetic/Xcode-New.app/Contents/Developer",
            xcodeVersion: "17.0",
            xcodeBuild: "17A200",
            platform: "SyntheticOS",
            sdkIdentifier: "syntheticos",
            sdkVersion: "21.0",
            sdkPath: "/Synthetic/SDK21.sdk"
        )
        let location = SourceLocation(path: "/Synthetic/Fixture.swift", line: 7, column: 3)
        let evidence = SDKFindingEvidence(
            baseline: baseline,
            candidate: candidate,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.fictional.removed",
            fullyQualifiedName: "FictionalSDK.Gizmo.removed()",
            sourceLocation: location,
            changeKind: .removed,
            observedChange: "The symbol is absent from the candidate.",
            oldDeclaration: "func removed()",
            newDeclaration: nil,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/Synthetic",
            baselineEnvironment: EnvironmentSnapshot(xcodeVersion: "Xcode 16.0"),
            candidateEnvironment: EnvironmentSnapshot(xcodeVersion: "Xcode 17.0"),
            referenceResolutionCoverage: [
                ReferenceResolutionCoverage(
                    sdkIdentifier: "syntheticos",
                    filesRequested: 1,
                    filesAnalyzed: 1,
                    declarationReferences: 2,
                    stableIdentityReferences: 1,
                    unresolvedReferences: 1,
                    unresolvedReasons: ["synthetic unresolved reference": 1]
                ),
            ],
            findings: [
                Finding(
                    findingID: "sdk.removed.usr.fictional.removed",
                    category: .sdk,
                    title: "SDK API removed",
                    explanation: "The symbol is absent from the candidate.",
                    severity: .error,
                    confidence: .high,
                    location: location,
                    origin: .sdk,
                    sdkEvidence: evidence
                ),
            ]
        )

        let terminal = String(
            decoding: try ReportRenderer.render(report, format: .terminal),
            as: UTF8.self
        )
        XCTAssertTrue(terminal.contains("Baseline: Xcode 16.0 (16A100), SDK 20.0"))
        XCTAssertTrue(terminal.contains("Symbol: usr.fictional.removed"))
        XCTAssertTrue(terminal.contains("Old declaration: func removed()"))
        XCTAssertTrue(terminal.contains("1 stable identity reference(s), 1 unresolved"))

        let jsonData = try ReportRenderer.render(report, format: .json)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        )
        XCTAssertEqual(json["reportFormatVersion"] as? String, "3.0")
        XCTAssertNotNil(json["referenceResolutionCoverage"])
        let findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.first?["findingID"] as? String, "sdk.removed.usr.fictional.removed")
        XCTAssertNotNil(findings.first?["sdkEvidence"])

        let sarifData = try ReportRenderer.render(report, format: .sarif)
        let sarif = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: sarifData) as? [String: Any]
        )
        XCTAssertEqual(sarif["version"] as? String, "2.1.0")
        let runs = try XCTUnwrap(sarif["runs"] as? [[String: Any]])
        XCTAssertNotNil(runs.first?["properties"])
        let results = try XCTUnwrap(runs.first?["results"] as? [[String: Any]])
        XCTAssertEqual(results.first?["ruleId"] as? String, "sdk.removed.usr.fictional.removed")
    }

    func testExitStatusesZeroAndOneAreDeterministic() {
        let warning = Finding(
            findingID: "synthetic.warning",
            category: .compiler,
            title: "Warning",
            explanation: "Synthetic warning.",
            severity: .warning,
            confidence: .high,
            origin: .compiler
        )

        XCTAssertEqual(
            ExitStatusEvaluator.status(for: [], failureLevel: .warning),
            0
        )
        XCTAssertEqual(
            ExitStatusEvaluator.status(for: [warning], failureLevel: .warning),
            1
        )
        XCTAssertEqual(
            ExitStatusEvaluator.status(for: [warning], failureLevel: .error),
            0
        )
        let report = AnalysisReport(
            projectRoot: "/Synthetic",
            findings: [warning]
        )
        XCTAssertTrue(
            TerminalReportRenderer.render(
                report,
                failureLevel: .error
            ).hasPrefix("PASS\n")
        )
        XCTAssertTrue(
            TerminalReportRenderer.render(
                report,
                failureLevel: .warning
            ).hasPrefix("FAIL\n")
        )
    }

    func testIncompleteAndBlockedReportsUseExitStatusTwoByDefault() {
        let incomplete = AnalysisReport(
            projectRoot: "/Synthetic",
            referenceResolutionCoverage: [
                ReferenceResolutionCoverage(
                    sdkIdentifier: "syntheticos",
                    filesRequested: 2,
                    filesAnalyzed: 1,
                    filesFailed: 1,
                    compilerExitStatus: 1,
                    isComplete: false
                ),
            ],
            findings: []
        )
        let blocked = AnalysisReport(
            projectRoot: "/Synthetic",
            analysisState: .blocked,
            findings: []
        )

        XCTAssertEqual(
            ExitStatusEvaluator.status(
                for: incomplete,
                failureLevel: .error
            ),
            2
        )
        XCTAssertEqual(
            ExitStatusEvaluator.status(
                for: blocked,
                failureLevel: .error
            ),
            2
        )
        XCTAssertEqual(
            ExitStatusEvaluator.status(
                for: incomplete,
                failureLevel: .error,
                allowIncomplete: true
            ),
            0
        )
    }
}
