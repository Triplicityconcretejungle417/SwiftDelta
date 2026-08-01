//===--- SDKCompilerCompatibilityEvidenceTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKCompilerCompatibilityEvidenceTests: XCTestCase {
    func testIncompleteCandidateTargetCannotConfirmRemoval() {
        let fixtures = removalFixtures(candidateSymbols: [])
        let location = SourceLocation(
            path: "/Synthetic/Sources/Use.swift",
            line: 3,
            column: 5
        )
        let findings = SDKProjectMatcher.findings(
            changes: SDKSnapshotDiffer.compare(
                baseline: fixtures.baseline,
                candidate: fixtures.candidate
            ),
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR,
                    target: "FictionalApp"
                ),
            ],
            candidateDiagnostics: [
                CompilerDiagnostic(
                    message: "fictional error",
                    severity: .error,
                    location: location,
                    target: "FictionalApp"
                ),
            ],
            candidateCompleteTargets: [],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )

        XCTAssertTrue(findings.isEmpty)
    }

    func testCandidateCompilerResolutionSuppressesIdentityLoss() {
        let candidateSymbol = makeSDKSymbol(
            "usr.candidate.resolved",
            "ReplacementContainer.perform(value:)",
            declaration: "func perform(value: Int)"
        )
        let fixtures = removalFixtures(candidateSymbols: [candidateSymbol])
        let changes = [
            SDKSymbolChange(
                kind: .removed,
                baseline: fixtures.baseline.symbols[0],
                candidate: nil,
                observedChange: "The stable baseline identity is absent."
            ),
        ]
        let location = SourceLocation(
            path: "/Synthetic/Sources/Use.swift",
            line: 4,
            column: 8
        )
        let findings = SDKProjectMatcher.findings(
            changes: changes,
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            candidateReferences: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.candidate.resolved",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )

        XCTAssertTrue(findings.isEmpty)
    }

    func testCandidateProjectLocalIdentityCannotSuppressSDKRemoval() {
        let fixtures = removalFixtures(candidateSymbols: [])
        let location = SourceLocation(
            path: "/Synthetic/Sources/Use.swift",
            line: 5,
            column: 8
        )
        let findings = SDKProjectMatcher.findings(
            changes: SDKSnapshotDiffer.compare(
                baseline: fixtures.baseline,
                candidate: fixtures.candidate
            ),
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            candidateReferences: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.project.local",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings[0].confidence, .low)
    }

    func testGenuineRemovalRequiresCorrelatedCandidateCompilerErrorForHighConfidence() {
        let fixtures = removalFixtures(candidateSymbols: [])
        let changes = SDKSnapshotDiffer.compare(
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )
        let location = SourceLocation(
            path: "/Synthetic/Sources/Use.swift",
            line: 7,
            column: 12
        )
        let confirmed = SDKProjectMatcher.findings(
            changes: changes,
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            candidateDiagnostics: [
                CompilerDiagnostic(
                    message: "fictional candidate type-check failure",
                    severity: .error,
                    location: location
                ),
            ],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )
        XCTAssertEqual(confirmed.first?.confidence, .high)
        XCTAssertEqual(confirmed.first?.severity, .error)

        let unconfirmed = SDKProjectMatcher.findings(
            changes: changes,
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )
        XCTAssertEqual(unconfirmed.first?.confidence, .low)
        XCTAssertEqual(unconfirmed.first?.severity, .notice)
    }

    func testAmbiguousStructuralOverloadsRemainUncertainUntilCompilerResolvesCall() {
        let first = callable(
            "usr.new.first",
            parameters: [
                parameter("value", "Int"),
                parameter("context", "String", defaulted: true),
            ]
        )
        let second = callable(
            "usr.new.second",
            parameters: [
                parameter("value", "Int"),
                parameter("options", "Bool", defaulted: true),
            ]
        )
        let fixtures = removalFixtures(candidateSymbols: [first, second])
        let changes = SDKSnapshotDiffer.compare(
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )
        XCTAssertEqual(changes.first?.matchConfidence, .low)
        XCTAssertTrue(
            changes.first?.observedChange.contains(
                "multiple candidate overloads"
            ) == true
        )

        let location = SourceLocation(
            path: "/Synthetic/Sources/Use.swift",
            line: 9,
            column: 3
        )
        let resolved = SDKProjectMatcher.findings(
            changes: changes,
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.old",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            candidateReferences: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.new.first",
                    sourceLocation: location,
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: fixtures.baseline,
            candidate: fixtures.candidate
        )
        XCTAssertTrue(resolved.isEmpty)
    }

    func testEquivalentAttributeOrderAndFormattingProduceNoSignatureChange() {
        let identity = makeSDKIdentity(
            xcode: "1",
            build: "1A1",
            sdk: "1",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.equivalent",
            "Container.perform()",
            declaration: "@preconcurrency @FictionalActor func perform()"
        )
        let new = makeSDKSymbol(
            "usr.equivalent",
            "Container.perform()",
            declaration: "  @FictionalActor   @preconcurrency   func perform( ) "
        )
        let changes = SDKSnapshotDiffer.compare(
            baseline: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [old]
            ),
            candidate: SDKSnapshot(
                identity: identity,
                modules: ["FictionalSDK"],
                symbols: [new]
            )
        )

        XCTAssertFalse(changes.contains { $0.kind == .signatureChanged })
    }

    func testMultipleSignatureFacetsBecomeOneFinding() {
        let identity = makeSDKIdentity(
            xcode: "1",
            build: "1A1",
            sdk: "1",
            path: "/Synthetic/Xcode.app"
        )
        let old = callable(
            "usr.facets",
            parameters: [parameter("value", "Int")]
        )
        let new = makeSDKSymbol(
            "usr.facets",
            "Container.perform(input:)",
            declaration:
                "@FictionalActor func perform(input: String) -> String",
            parameters: [parameter("input", "String")],
            returnType: "String",
            concurrency: SDKConcurrencyMetadata(
                actorIsolation: "FictionalActor"
            )
        )
        let baseline = SDKSnapshot(
            identity: identity,
            modules: ["FictionalSDK"],
            symbols: [old]
        )
        let candidate = SDKSnapshot(
            identity: identity,
            modules: ["FictionalSDK"],
            symbols: [new]
        )
        let findings = SDKProjectMatcher.findings(
            changes: SDKSnapshotDiffer.compare(
                baseline: baseline,
                candidate: candidate
            ),
            references: [
                SDKSymbolReference(
                    preciseIdentifier: "usr.facets",
                    sourceLocation: SourceLocation(
                        path: "/Synthetic/Sources/Use.swift",
                        line: 1,
                        column: 1
                    ),
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: baseline,
            candidate: candidate
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertTrue(
            findings[0].sdkEvidence?.observedChange.contains(
                "Parameter labels changed"
            ) == true
        )
        XCTAssertTrue(
            findings[0].sdkEvidence?.observedChange.contains(
                "return type changed"
            ) == true
        )
    }

    private func removalFixtures(
        candidateSymbols: [SDKSymbol]
    ) -> (baseline: SDKSnapshot, candidate: SDKSnapshot) {
        let oldIdentity = makeSDKIdentity(
            xcode: "1",
            build: "1A1",
            sdk: "1",
            path: "/Synthetic/Old.app"
        )
        let newIdentity = makeSDKIdentity(
            xcode: "2",
            build: "2A1",
            sdk: "2",
            path: "/Synthetic/New.app"
        )
        return (
            SDKSnapshot(
                identity: oldIdentity,
                modules: ["FictionalSDK"],
                symbols: [
                    callable(
                        "usr.old",
                        parameters: [parameter("value", "Int")]
                    ),
                ]
            ),
            SDKSnapshot(
                identity: newIdentity,
                modules: ["FictionalSDK"],
                symbols: candidateSymbols
            )
        )
    }

    private func callable(
        _ identifier: String,
        parameters: [SDKFunctionParameter]
    ) -> SDKSymbol {
        makeSDKSymbol(
            identifier,
            "Container.perform(value:)",
            declaration: "func perform(value: Int)",
            parameters: parameters
        )
    }

    private func parameter(
        _ label: String,
        _ type: String,
        defaulted: Bool? = false
    ) -> SDKFunctionParameter {
        SDKFunctionParameter(
            name: label,
            externalName: label,
            type: type,
            hasDefaultValue: defaulted
        )
    }
}
