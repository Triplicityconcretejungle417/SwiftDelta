//===--- ReportingContractTests.swift - SwiftDelta ------------------------------------------===//
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

final class ReportingContractTests: XCTestCase {
    func testEmptyTerminalReportTextRemainsStable() {
        let report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/Synthetic",
            findings: []
        )

        XCTAssertEqual(
            TerminalReportRenderer.render(report),
            """
            PASS
            No findings matched the configured severity and confidence thresholds.

            Summary: 0 error(s), 0 warning(s), 0 notice(s), 0 analysis issue(s).

            """
        )
    }

    func testJSONFieldNamesRemainStable() throws {
        let report = makeFullyPopulatedReport()
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: JSONReportRenderer.render(report)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "reportFormatVersion", "generatedAt", "projectRoot",
                "targetXcodeVersion", "environment", "baselineEnvironment",
                "candidateEnvironment", "referenceResolutionCoverage",
                "findings", "failures", "analysisState",
                "sdkModuleSelections",
            ]
        )
        let finding = try XCTUnwrap((object["findings"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(finding.keys),
            [
                "id", "findingID", "category", "title", "explanation",
                "severity", "confidence", "location", "targetVersion",
                "migrationMessage", "referenceURL", "origin",
                "automaticRemediationSupported", "target", "configuration",
                "sdkEvidence",
            ]
        )
        let evidence = try XCTUnwrap(finding["sdkEvidence"] as? [String: Any])
        XCTAssertEqual(
            Set(evidence.keys),
            [
                "baseline", "candidate", "platform", "moduleName",
                "preciseIdentifier", "fullyQualifiedName", "sourceLocation",
                "changeKind", "observedChange", "oldDeclaration",
                "newDeclaration", "oldAvailability", "newAvailability",
                "migrationMessage", "resolutionMethod",
            ]
        )
    }

    func testSARIFShapeRemainsStable() throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: SARIFReportRenderer.render(makeFullyPopulatedReport())
            ) as? [String: Any]
        )

        XCTAssertEqual(Set(object.keys), ["$schema", "version", "runs"])
        let run = try XCTUnwrap((object["runs"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(run.keys),
            [
                "tool", "properties", "results", "originalUriBaseIds",
                "invocations",
            ]
        )
        let result = try XCTUnwrap((run["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(result.keys),
            ["ruleId", "level", "message", "properties", "locations"]
        )
    }

    private func makeFullyPopulatedReport() -> AnalysisReport {
        let baseline = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode-Old.app",
            developerDirectory: "/Synthetic/Xcode-Old.app/Contents/Developer",
            xcodeVersion: "1.0",
            xcodeBuild: "1A1",
            platform: "SyntheticOS",
            sdkIdentifier: "syntheticos",
            sdkVersion: "1.0",
            sdkPath: "/Synthetic/SDK1.sdk",
            swiftVersion: "Swift 1.0"
        )
        let candidate = SDKInstallationIdentity(
            xcodeApplicationPath: "/Synthetic/Xcode-New.app",
            developerDirectory: "/Synthetic/Xcode-New.app/Contents/Developer",
            xcodeVersion: "2.0",
            xcodeBuild: "2A2",
            platform: "SyntheticOS",
            sdkIdentifier: "syntheticos",
            sdkVersion: "2.0",
            sdkPath: "/Synthetic/SDK2.sdk",
            swiftVersion: "Swift 2.0"
        )
        let location = SourceLocation(path: "/Synthetic/File.swift", line: 4, column: 2)
        let availability = SDKAvailability(
            domain: "SyntheticOS",
            introduced: "1.0",
            deprecated: "2.0",
            obsoleted: "3.0",
            isUnconditionallyDeprecated: true,
            isUnconditionallyUnavailable: false,
            renamed: "replacement()",
            message: "Use the replacement."
        )
        let evidence = SDKFindingEvidence(
            baseline: baseline,
            candidate: candidate,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.fictional.changed",
            fullyQualifiedName: "FictionalSDK.Gizmo.changed()",
            sourceLocation: location,
            changeKind: .signatureChanged,
            observedChange: "The declaration changed.",
            oldDeclaration: "func changed() -> Int",
            newDeclaration: "func changed() -> String",
            oldAvailability: [availability],
            newAvailability: [availability],
            migrationMessage: "Use the replacement.",
            resolutionMethod: .compilerUSR
        )
        let environment = EnvironmentSnapshot(
            xcodeVersion: "Xcode 2.0",
            swiftVersion: "Swift 2.0",
            sdkVersion: "2.0",
            developerDirectory: candidate.developerDirectory
        )
        let finding = Finding(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            findingID: "sdk.signature.usr.fictional.changed",
            category: .sdk,
            title: "SDK signature changed",
            explanation: "The declaration changed.",
            severity: .warning,
            confidence: .high,
            location: location,
            targetVersion: "2.0",
            migrationMessage: "Use the replacement.",
            referenceURL: URL(string: "https://example.invalid/reference"),
            origin: .sdk,
            automaticRemediationSupported: false,
            target: "SyntheticTarget",
            configuration: "Debug",
            sdkEvidence: evidence
        )
        return AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            projectRoot: "/Synthetic",
            targetXcodeVersion: "2.0",
            environment: environment,
            baselineEnvironment: environment,
            candidateEnvironment: environment,
            referenceResolutionCoverage: [
                ReferenceResolutionCoverage(
                    sdkIdentifier: "syntheticos",
                    filesRequested: 1,
                    filesAnalyzed: 1,
                    filesFailed: 0,
                    declarationReferences: 1,
                    stableIdentityReferences: 1,
                    unresolvedReferences: 0,
                    unresolvedReasons: [:]
                ),
            ],
            findings: [finding],
            failures: [
                AnalysisFailure(
                    kind: .build,
                    message: "Synthetic issue.",
                    location: location
                ),
            ]
        )
    }
}
