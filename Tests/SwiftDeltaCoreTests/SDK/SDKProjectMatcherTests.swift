//===--- SDKProjectMatcherTests.swift - SwiftDelta ------------------------------------------===//
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

final class SDKProjectMatcherTests: XCTestCase {
func testDeterministicSDKChangesOnlyReportReferencedResolvedSymbols() {
        let oldIdentity = makeSDKIdentity(
            xcode: "16.0",
            build: "16A100",
            sdk: "20.0",
            path: "/Synthetic/XcodeBaseline.app"
        )
        let newIdentity = makeSDKIdentity(
            xcode: "17.0",
            build: "17A200",
            sdk: "21.0",
            path: "/Synthetic/XcodeCandidate.app"
        )
        let baselineSymbols = [
            makeSDKSymbol("usr.removed", "Gizmo.removedFeature()", declaration: "func removedFeature()"),
            makeSDKSymbol("usr.deprecated", "Gizmo.oldFeature()", declaration: "func oldFeature()"),
            makeSDKSymbol("usr.unavailable", "Gizmo.platformFeature()", declaration: "func platformFeature()"),
            makeSDKSymbol("usr.renamed", "Gizmo.originalName()", declaration: "func originalName()"),
            makeSDKSymbol(
                "usr.signature",
                "Gizmo.transform(value:)",
                declaration: "func transform(value: Int) -> Int",
                parameters: [SDKFunctionParameter(name: "value", externalName: "value", type: "Int")],
                returnType: "Int"
            ),
            makeSDKSymbol(
                "usr.labels",
                "Gizmo.configure(first:)",
                declaration: "func configure(first value: Int)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "first", type: "Int")]
            ),
            makeSDKSymbol(
                "usr.availability",
                "Gizmo.versioned()",
                declaration: "func versioned()",
                availability: [SDKAvailability(domain: "SyntheticOS", introduced: "10.0")]
            ),
            makeSDKSymbol(
                "usr.concurrent",
                "Gizmo.perform()",
                declaration: "func perform()",
                concurrency: SDKConcurrencyMetadata()
            ),
            makeSDKSymbol("usr.unchanged", "Gizmo.stable()", declaration: "func stable()"),
            makeSDKSymbol(
                "usr.overload.a",
                "Gizmo.overloaded(_:)",
                declaration: "func overloaded(_ value: Int)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "_", type: "Int")]
            ),
            makeSDKSymbol(
                "usr.overload.b",
                "Gizmo.overloaded(_:)",
                declaration: "func overloaded(_ value: String)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "_", type: "String")]
            ),
            makeSDKSymbol("usr.typeA.same", "TypeA.sameName()", declaration: "func sameName()"),
            makeSDKSymbol("usr.typeB.same", "TypeB.sameName()", declaration: "func sameName()"),
            makeSDKSymbol("usr.unused", "Gizmo.unusedRemoved()", declaration: "func unusedRemoved()"),
            makeSDKSymbol("usr.conditional", "Gizmo.conditionalRemoved()", declaration: "func conditionalRemoved()"),
        ]
        let candidateSymbols = [
            makeSDKSymbol(
                "usr.deprecated",
                "Gizmo.oldFeature()",
                declaration: "func oldFeature()",
                availability: [
                    SDKAvailability(
                        domain: "SyntheticOS",
                        deprecated: "21.0",
                        message: "Use the newer SDK capability."
                    ),
                ]
            ),
            makeSDKSymbol(
                "usr.unavailable",
                "Gizmo.platformFeature()",
                declaration: "func platformFeature()",
                availability: [
                    SDKAvailability(
                        domain: "SyntheticOS",
                        isUnconditionallyUnavailable: true
                    ),
                ],
                isUnavailable: true
            ),
            makeSDKSymbol(
                "usr.renamed",
                "Gizmo.originalName()",
                declaration: "func originalName()",
                availability: [
                    SDKAvailability(
                        domain: "SyntheticOS",
                        renamed: "Gizmo.replacementName()",
                        message: "Use replacementName()."
                    ),
                ],
                renamedDestination: "Gizmo.replacementName()",
                migrationMessage: "Use replacementName()."
            ),
            makeSDKSymbol(
                "usr.signature",
                "Gizmo.transform(value:)",
                declaration: "func transform(value: String) -> String",
                parameters: [SDKFunctionParameter(name: "value", externalName: "value", type: "String")],
                returnType: "String"
            ),
            makeSDKSymbol(
                "usr.labels",
                "Gizmo.configure(second:)",
                declaration: "func configure(second value: Int)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "second", type: "Int")]
            ),
            makeSDKSymbol(
                "usr.availability",
                "Gizmo.versioned()",
                declaration: "func versioned()",
                availability: [SDKAvailability(domain: "SyntheticOS", introduced: "12.0")]
            ),
            makeSDKSymbol(
                "usr.concurrent",
                "Gizmo.perform()",
                declaration: "@SyntheticActor func perform() async",
                concurrency: SDKConcurrencyMetadata(
                    actorIsolation: "SyntheticActor",
                    isAsync: true
                )
            ),
            makeSDKSymbol("usr.unchanged", "Gizmo.stable()", declaration: "func stable()"),
            makeSDKSymbol(
                "usr.overload.a",
                "Gizmo.overloaded(_:)",
                declaration: "func overloaded(_ value: Double)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "_", type: "Double")]
            ),
            makeSDKSymbol(
                "usr.overload.b",
                "Gizmo.overloaded(_:)",
                declaration: "func overloaded(_ value: String)",
                parameters: [SDKFunctionParameter(name: "value", externalName: "_", type: "String")]
            ),
            makeSDKSymbol(
                "usr.typeA.same",
                "TypeA.sameName()",
                declaration: "func sameName(argument: Int)"
            ),
            makeSDKSymbol("usr.typeB.same", "TypeB.sameName()", declaration: "func sameName()"),
        ]
        let baseline = SDKSnapshot(
            identity: oldIdentity,
            modules: ["FictionalSDK"],
            symbols: baselineSymbols
        )
        let candidate = SDKSnapshot(
            identity: newIdentity,
            modules: ["FictionalSDK"],
            symbols: candidateSymbols
        )
        let changes = SDKSnapshotDiffer.compare(baseline: baseline, candidate: candidate)

        let referencedUSRs = [
            "usr.removed",
            "usr.deprecated",
            "usr.unavailable",
            "usr.renamed",
            "usr.signature",
            "usr.labels",
            "usr.availability",
            "usr.concurrent",
            "usr.unchanged",
            "usr.overload.b",
            "usr.typeB.same",
            "usr.local.shadow",
        ]
        var references = referencedUSRs.enumerated().map { index, usr in
            SDKSymbolReference(
                preciseIdentifier: usr,
                sourceLocation: SourceLocation(
                    path: "/Synthetic/Fixture.swift",
                    line: index + 1,
                    column: 1
                ),
                resolutionMethod: .compilerUSR
            )
        }
        references.append(
            SDKSymbolReference(
                preciseIdentifier: "usr.conditional",
                sourceLocation: SourceLocation(path: "/Synthetic/Fixture.swift", line: 50),
                resolutionMethod: .compilerUSR,
                isActiveCompilationBranch: false
            )
        )
        references.append(
            SDKSymbolReference(
                moduleName: "FictionalSDK",
                fullyQualifiedName: "FictionalSDK.Gizmo.removedFeature()",
                sourceLocation: SourceLocation(path: "/Synthetic/Fixture.swift", line: 60),
                resolutionMethod: .uncertainText
            )
        )

        let findings = SDKProjectMatcher.findings(
            changes: changes,
            references: references,
            baseline: baseline,
            candidate: candidate
        )
        let kinds = Set(findings.compactMap(\.sdkEvidence?.changeKind))

        XCTAssertTrue(kinds.contains(.removed))
        XCTAssertTrue(kinds.contains(.newlyDeprecated))
        XCTAssertTrue(kinds.contains(.newlyUnavailable))
        XCTAssertTrue(kinds.contains(.renamed))
        XCTAssertTrue(kinds.contains(.parameterLabelsChanged))
        XCTAssertTrue(kinds.contains(.parameterTypesChanged))
        XCTAssertTrue(kinds.contains(.availabilityChanged))
        XCTAssertTrue(kinds.contains(.concurrencyChanged))
        let transformed = findings.filter {
            $0.sdkEvidence?.preciseIdentifier == "usr.signature"
        }
        XCTAssertEqual(transformed.count, 1)
        let transformedExplanation = transformed[0].explanation.lowercased()
        XCTAssertTrue(
            transformedExplanation.contains("parameter types")
                && transformedExplanation.contains("return type")
                && transformedExplanation.contains("signature")
        )

        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.unchanged") })
        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.overload.a") })
        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.typeA.same") })
        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.unused") })
        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.conditional") })
        XCTAssertFalse(findings.contains { $0.findingID.contains("usr.local.shadow") })
        XCTAssertTrue(
            findings.filter {
                $0.sdkEvidence?.resolutionMethod == .uncertainText
            }.allSatisfy { $0.confidence == .low }
        )

        let deprecated = findings.first {
            $0.sdkEvidence?.changeKind == .newlyDeprecated
        }
        XCTAssertEqual(deprecated?.migrationMessage, "Use the newer SDK capability.")
        XCTAssertEqual(deprecated?.sdkEvidence?.baseline.xcodeBuild, "16A100")
        XCTAssertEqual(deprecated?.sdkEvidence?.candidate.sdkVersion, "21.0")
        XCTAssertEqual(deprecated?.sdkEvidence?.preciseIdentifier, "usr.deprecated")
    }

    func testConcurrencyRelaxationIsNoticeAndDoesNotBorrowMigrationGuidance() {
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
        let old = makeSDKSymbol(
            "usr.concurrent.relaxed",
            "Container.perform()",
            declaration: "@MainActor func perform()",
            concurrency: SDKConcurrencyMetadata(actorIsolation: "MainActor")
        )
        let new = makeSDKSymbol(
            "usr.concurrent.relaxed",
            "Container.perform()",
            declaration: "nonisolated func perform()",
            availability: [
                SDKAvailability(
                    domain: "SyntheticOS",
                    message: "Unrelated deprecation guidance."
                ),
            ],
            migrationMessage: "Unrelated deprecation guidance.",
            concurrency: SDKConcurrencyMetadata(isNonisolated: true)
        )
        let baseline = SDKSnapshot(
            identity: oldIdentity,
            modules: ["FictionalSDK"],
            symbols: [old]
        )
        let candidate = SDKSnapshot(
            identity: newIdentity,
            modules: ["FictionalSDK"],
            symbols: [new]
        )
        let changes = SDKSnapshotDiffer.compare(
            baseline: baseline,
            candidate: candidate
        )

        let finding = SDKProjectMatcher.findings(
            changes: changes,
            references: [
                SDKSymbolReference(
                    preciseIdentifier: old.id,
                    sourceLocation: SourceLocation(path: "/Synthetic/Fixture.swift", line: 1),
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: baseline,
            candidate: candidate
        ).first { $0.sdkEvidence?.changeKind == .concurrencyChanged }

        XCTAssertEqual(finding?.severity, .notice)
        XCTAssertNil(finding?.migrationMessage)
        XCTAssertNil(finding?.sdkEvidence?.migrationMessage)
    }

    func testSendableSignatureEvolutionProducesOneFinding() {
        let identity = makeSDKIdentity(
            xcode: "1",
            build: "1A1",
            sdk: "1",
            path: "/Synthetic/Xcode.app"
        )
        let old = makeSDKSymbol(
            "usr.sendable",
            "Container.perform(operation:)",
            declaration: "func perform(operation: () -> Void)",
            parameters: [
                SDKFunctionParameter(
                    name: "operation",
                    externalName: "operation",
                    type: "() -> Void"
                ),
            ],
            concurrency: SDKConcurrencyMetadata()
        )
        let new = makeSDKSymbol(
            "usr.sendable",
            "Container.perform(operation:)",
            declaration: "func perform(operation: @Sendable () -> Void)",
            parameters: [
                SDKFunctionParameter(
                    name: "operation",
                    externalName: "operation",
                    type: "@Sendable () -> Void"
                ),
            ],
            concurrency: SDKConcurrencyMetadata(isSendable: true)
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
                    preciseIdentifier: old.id,
                    sourceLocation: SourceLocation(path: "/Synthetic/Fixture.swift", line: 1),
                    resolutionMethod: .compilerUSR
                ),
            ],
            baseline: baseline,
            candidate: candidate
        )

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.sdkEvidence?.changeKind, .concurrencyChanged)
    }
}
