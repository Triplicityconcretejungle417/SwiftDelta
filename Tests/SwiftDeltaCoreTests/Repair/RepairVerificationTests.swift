//===--- RepairVerificationTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDeltaCore
import XCTest

final class RepairVerificationTests: XCTestCase {
    func testSafeRepairAppliesWhenVerificationResolvesFinding() throws {
        let directory = try TestDirectory(name: "repair-verify-success")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            identifier: "repair.success",
            finding: "finding.success"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: false,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.success"]
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: []
            ),
        ])

        let result = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: [repair],
            projectRoot: directory.url,
            verifier: verifier
        )

        XCTAssertEqual(result.appliedRepairIdentifiers, ["repair.success"])
        XCTAssertEqual(try String(contentsOf: file), "let new = 1\n")
    }

    func testVerificationFailureRestoresAllFiles() throws {
        let directory = try TestDirectory(name: "repair-verify-failure")
        defer { directory.remove() }
        let firstFile = try directory.write("A.swift", "let oldA = 1\n")
        let secondFile = try directory.write("B.swift", "let oldB = 2\n")
        let firstDocument = try RepairSourceDocument(
            root: directory.url,
            file: firstFile
        )
        let secondDocument = try RepairSourceDocument(
            root: directory.url,
            file: secondFile
        )
        let first = try makeRepair(
            document: firstDocument,
            original: "oldA",
            replacement: "newA",
            finding: "finding.rollback"
        )
        let second = try makeRepair(
            document: secondDocument,
            original: "oldB",
            replacement: "newB",
            finding: "finding.rollback"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [first, second]
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.rollback"]
            ),
            RepairVerificationSnapshot(
                buildSucceeded: false,
                diagnostics: [
                    CompilerDiagnostic(message: "new error", severity: .error),
                ],
                offeredFindingIdentifiers: ["finding.rollback"]
            ),
        ])

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [first, second],
                projectRoot: directory.url,
                verifier: verifier
            )
        )
        XCTAssertEqual(try String(contentsOf: firstFile), "let oldA = 1\n")
        XCTAssertEqual(try String(contentsOf: secondFile), "let oldB = 2\n")
    }

    func testMissingPreRepairEvidenceRejectsAndRestoresSource() throws {
        let directory = try TestDirectory(name: "repair-missing-before-evidence")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            finding: "finding.not-observed"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: []
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: []
            ),
        ])

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [repair],
                projectRoot: directory.url,
                verifier: verifier
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "targeted structured repair evidence was not present"
                )
            )
        }
        XCTAssertEqual(try String(contentsOf: file), "let old = 1\n")
    }

    func testVerificationTracksTheEditedOccurrenceWhenSymbolAppearsTwice()
        throws
    {
        let directory = try TestDirectory(
            name: "repair-occurrence-verification"
        )
        defer { directory.remove() }
        let file = try directory.write(
            "A.swift",
            "let old = 1\nlet old = 2\n"
        )
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            identifier: "repair.first-occurrence",
            finding: "finding.shared-symbol"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )
        let first = RepairFindingOccurrence(
            findingIdentifier: "finding.shared-symbol",
            stableKey: "finding.shared-symbol|A.swift|1|5",
            filePath: file.path,
            line: 1,
            column: 5
        )
        let second = RepairFindingOccurrence(
            findingIdentifier: "finding.shared-symbol",
            stableKey: "finding.shared-symbol|A.swift|2|5",
            filePath: file.path,
            line: 2,
            column: 5
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.shared-symbol"],
                offeredFindingOccurrences: [first, second]
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.shared-symbol"],
                offeredFindingOccurrences: [second]
            ),
        ])

        _ = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: [repair],
            projectRoot: directory.url,
            verifier: verifier
        )

        XCTAssertEqual(
            try String(contentsOf: file),
            "let new = 1\nlet old = 2\n"
        )
    }

    func testFindingDisappearanceCausedByCoverageLossRollsBackSource() throws {
        let directory = try TestDirectory(name: "repair-coverage-rollback")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            finding: "finding.coverage"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )
        let before = ReferenceResolutionCoverage(
            sdkIdentifier: "macosx",
            toolchainRole: "candidate",
            scheme: "Synthetic",
            target: "Synthetic",
            configuration: "Debug",
            destination: "platform=macOS",
            architecture: "arm64",
            deploymentTarget: "13.0",
            filesRequested: 1,
            filesAnalyzed: 1,
            filesFailed: 0,
            stableIdentityReferences: 1,
            compilerExitStatus: 1,
            isComplete: false,
            sourceFiles: [
                SourceAnalysisRecord(
                    path: file.path,
                    disposition: .analyzedWithSDKReferences
                ),
            ]
        )
        let after = ReferenceResolutionCoverage(
            sdkIdentifier: "macosx",
            toolchainRole: "candidate",
            scheme: "Synthetic",
            target: "Synthetic",
            configuration: "Debug",
            destination: "platform=macOS",
            architecture: "arm64",
            deploymentTarget: "13.0",
            filesRequested: 1,
            filesAnalyzed: 0,
            filesFailed: 1,
            stableIdentityReferences: 0,
            compilerExitStatus: 1,
            isComplete: false,
            sourceFiles: [
                SourceAnalysisRecord(
                    path: file.path,
                    disposition: .missingCompilerOutput,
                    reason: "the analyzer produced no document"
                ),
            ]
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: false,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.coverage"],
                referenceResolutionCoverage: [before],
                buildContextIdentity: "candidate|Synthetic|Debug"
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: [],
                referenceResolutionCoverage: [after],
                buildContextIdentity: "candidate|Synthetic|Debug"
            ),
        ])

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [repair],
                projectRoot: directory.url,
                verifier: verifier
            )
        )
        XCTAssertEqual(try String(contentsOf: file), "let old = 1\n")
    }

    func testRepeatedExecutionIsStaleAndDoesNotDuplicateReplacement() throws {
        let directory = try TestDirectory(name: "repair-idempotent")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            finding: "finding.idempotent"
        )
        let transaction = try RepairTransaction().apply(
            repairs: [repair],
            projectRoot: directory.url
        )
        transaction.finish()

        XCTAssertThrowsError(
            try RepairTransaction().apply(
                repairs: [repair],
                projectRoot: directory.url
            )
        )
        XCTAssertEqual(try String(contentsOf: file), "let new = 1\n")
    }

    func testSelectionMustExactlyMatchCurrentPlanRepair() throws {
        let directory = try TestDirectory(name: "repair-plan-selection-integrity")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let planned = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            identifier: "repair.integrity",
            finding: "finding.integrity"
        )
        let forged = ProposedRepair(
            repairIdentifier: planned.repairIdentifier,
            relatedFindingIdentifier: planned.relatedFindingIdentifier,
            evidenceSource: planned.evidenceSource,
            language: planned.language,
            filePath: planned.filePath,
            sourceRange: planned.sourceRange,
            originalText: planned.originalText,
            replacementText: "different",
            fileFingerprint: planned.fileFingerprint,
            confidence: planned.confidence,
            safety: planned.safety,
            explanation: planned.explanation,
            verificationRequirement: planned.verificationRequirement
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [planned]
        )

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [forged],
                projectRoot: directory.url,
                verifier: SequenceRepairVerifier([])
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly match"))
        }
        XCTAssertEqual(try String(contentsOf: file), "let old = 1\n")
    }

    func testSelectingAnyTwoMembersOfMultiRepairConflictIsRejected() throws {
        let directory = try TestDirectory(name: "repair-partial-conflict")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repairs = try ["one", "two", "three"].enumerated().map {
            index, identifier in
            try makeRepair(
                document: document,
                original: "old",
                replacement: identifier,
                identifier: "repair.\(identifier)",
                finding: "finding.\(index)"
            )
        }
        let plan = RepairPlan(
            projectRoot: directory.url.path,
            repairs: repairs,
            conflicts: [
                RepairConflict(
                    kind: .contradictory,
                    repairIdentifiers: repairs.map(\.repairIdentifier),
                    explanation: "The edits contradict each other."
                ),
            ]
        )

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: Array(repairs.prefix(2)),
                projectRoot: directory.url,
                verifier: SequenceRepairVerifier([])
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("conflict"))
        }
        XCTAssertEqual(try String(contentsOf: file), "let old = 1\n")
    }
}
