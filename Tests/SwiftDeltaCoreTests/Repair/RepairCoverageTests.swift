//===--- RepairCoverageTests.swift - SwiftDelta ------------------------------------------===//
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

final class RepairCoverageTests: XCTestCase {
    func testEveryAnalysisFindingReceivesAnExplicitDisposition() throws {
        let directory = try TestDirectory(name: "repair-dispositions")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/Feature.swift",
            "oldCall()\nreviewCall()\n"
        )
        let document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        let mechanicalFinding = compilerFinding(
            id: "compiler.mechanical",
            path: file.path,
            line: 1,
            message: "candidate compiler supplied an edit"
        )
        let reviewFinding = compilerFinding(
            id: "compiler.review",
            path: file.path,
            line: 2,
            message: "candidate compiler supplied no edit"
        )
        let settingFinding = Finding(
            findingID: "build-setting.changed.SYNTHETIC_TARGET",
            category: .buildSetting,
            title: "Effective build setting changed",
            explanation: "Synthetic setting evidence.",
            severity: .notice,
            confidence: .high,
            origin: .buildSettings
        )
        let repair = try makeRepair(
            document: document,
            original: "oldCall",
            replacement: "newCall",
            identifier: "repair.mechanical",
            finding: mechanicalFinding.findingID
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )

        let result = RepairFindingDispositionBuilder.build(
            findings: [
                mechanicalFinding,
                reviewFinding,
                settingFinding,
            ],
            plan: plan,
            projectRoot: directory.url,
            modelAssistanceRequested: false
        )

        XCTAssertEqual(result.dispositions.count, 3)
        XCTAssertEqual(result.summary.findingsReceived, 3)
        XCTAssertEqual(result.summary.mechanicallyRepairable, 1)
        XCTAssertEqual(result.summary.reviewOnly, 1)
        XCTAssertEqual(result.summary.unsupported, 1)
        XCTAssertEqual(
            result.dispositions.first {
                $0.findingIdentifier == reviewFinding.findingID
            }?.kind,
            .manualReviewRequired
        )
        XCTAssertTrue(
            result.dispositions.first {
                $0.findingIdentifier == settingFinding.findingID
            }?.reason.contains("project metadata remains protected") == true
        )
    }

    func testConflictsAndLocalModelProposalsRemainDistinctCoverage() throws {
        let directory = try TestDirectory(name: "repair-coverage-kinds")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/Feature.swift",
            "oldCall()\nmodelCall()\n"
        )
        let document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        let conflictFinding = compilerFinding(
            id: "compiler.conflict",
            path: file.path,
            line: 1,
            message: "conflicting exact edits"
        )
        let modelFinding = compilerFinding(
            id: "compiler.model",
            path: file.path,
            line: 2,
            message: "local model proposal"
        )
        let left = try makeRepair(
            document: document,
            original: "oldCall",
            replacement: "firstCall",
            identifier: "repair.left",
            finding: conflictFinding.findingID
        )
        let right = try makeRepair(
            document: document,
            original: "oldCall",
            replacement: "secondCall",
            identifier: "repair.right",
            finding: conflictFinding.findingID
        )
        let base = try makeRepair(
            document: document,
            original: "modelCall",
            replacement: "candidateCall",
            identifier: "repair.model",
            finding: modelFinding.findingID,
            source: .foundationModels,
            safety: .reviewRequired
        )
        let model = ProposedRepair(
            repairIdentifier: base.repairIdentifier,
            relatedFindingIdentifier: base.relatedFindingIdentifier,
            evidenceSource: base.evidenceSource,
            language: base.language,
            filePath: base.filePath,
            sourceRange: base.sourceRange,
            originalText: base.originalText,
            replacementText: base.replacementText,
            fileFingerprint: base.fileFingerprint,
            confidence: .low,
            safety: .reviewRequired,
            explanation: "Synthetic local model proposal.",
            verificationRequirement: .candidateBuild,
            generatedBy: "Apple Foundation Models",
            provider: "on-device",
            execution: "On-device",
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep",
            modelGenerated: true,
            requiresReview: true
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [left, right, model]
        )

        let result = RepairFindingDispositionBuilder.build(
            findings: [conflictFinding, modelFinding],
            plan: plan,
            projectRoot: directory.url,
            modelAssistanceRequested: true
        )

        XCTAssertEqual(result.summary.findingsReceived, 2)
        XCTAssertEqual(result.summary.conflicting, 1)
        XCTAssertEqual(result.summary.modelProposed, 1)
        XCTAssertEqual(
            result.dispositions.first {
                $0.findingIdentifier == modelFinding.findingID
            }?.kind,
            .foundationModelsProposal
        )
        XCTAssertEqual(
            result.dispositions.first {
                $0.findingIdentifier == conflictFinding.findingID
            }?.hasConflict,
            true
        )
    }

    func testModelNotRepairableReasonBecomesVisibleFindingDisposition() throws {
        let directory = try TestDirectory(name: "repair-model-disposition")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            "func run() { oldCall() }\n"
        )
        let finding = compilerFinding(
            id: "compiler.model-reviewed",
            path: file.path,
            line: 1,
            message: "candidate compiler supplied no exact edit"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: []
        )

        let result = RepairFindingDispositionBuilder.build(
            findings: [finding],
            plan: plan,
            projectRoot: directory.url,
            modelAssistanceRequested: true,
            modelNotRepairableReasons: [
                finding.stableKey:
                    "The evidence does not establish a bounded source change.",
            ]
        )

        XCTAssertEqual(result.dispositions.count, 1)
        XCTAssertEqual(result.dispositions[0].kind, .notRepairable)
        XCTAssertTrue(
            result.dispositions[0].reason.contains(
                "does not establish a bounded source change"
            )
        )
    }

    func testCompilerFixItKeepsTheAnalysisFindingIdentity() throws {
        let directory = try TestDirectory(name: "repair-fixit-identity")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/Feature.swift",
            "let value = oldCall()\n"
        )
        let document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        let range = try makeRepair(
            document: document,
            original: "oldCall",
            replacement: "newCall"
        ).sourceRange
        let finding = compilerFinding(
            id: "compiler.compiler",
            path: file.path,
            line: 1,
            message: "replace the obsolete spelling"
        )
        let fixIt = StructuredDiagnosticFixIt(
            filePath: file.path,
            sourceRange: range,
            replacementText: "newCall",
            diagnosticText: "replace the obsolete spelling",
            diagnosticSeverity: .warning,
            diagnosticIndex: 0,
            fixItIndex: 0,
            compilerContext: RepairCompilerContextEvidence(
                compilerPath: "/Synthetic/swift-frontend",
                target: "Feature",
                moduleName: "Feature",
                sdkIdentifier: "syntheticos",
                sdkPath: "/Synthetic/SDK",
                diagnosticIdentity: "diagnostic.synthetic",
                evidenceArtifact: "serializedDiagnostics",
                isTargetAware: true
            )
        )

        let result = CompilerFixItRepairBuilder.build(
            fixIts: [fixIt],
            projectRoot: directory.url,
            analysisFindings: [finding]
        )

        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(
            result.0[0].relatedFindingIdentifier,
            finding.findingID
        )
        XCTAssertEqual(result.0[0].safety, .safe)
    }

    func testParameterLabelRepairAllowsAddedDefaultedParameters() throws {
        let directory = try TestDirectory(name: "repair-defaulted-parameters")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/Feature.swift",
            "func run() { perform(old: 1) }\n"
        )
        let baselineIdentity = makeSDKIdentity(
            xcode: "1",
            build: "1A",
            sdk: "1",
            path: "/Synthetic/Baseline.app"
        )
        let candidateIdentity = makeSDKIdentity(
            xcode: "2",
            build: "2A",
            sdk: "2",
            path: "/Synthetic/Candidate.app"
        )
        let baseline = SDKSymbol(
            id: "usr.perform.old",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.perform.old",
            fullyQualifiedName: "FictionalSDK.perform(old:)",
            baseName: "perform",
            kind: "swift.func",
            declaration: "func perform(old value: Int)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "old",
                    type: "Int"
                ),
            ],
            returnType: "Void"
        )
        let candidate = SDKSymbol(
            id: "usr.perform.new",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.perform.new",
            fullyQualifiedName: "FictionalSDK.perform(prefix:new:suffix:)",
            baseName: "perform",
            kind: "swift.func",
            declaration:
                "func perform(prefix: Bool = false, new value: Int, "
                + "suffix: String = \"\")",
            parameters: [
                SDKFunctionParameter(
                    name: "prefix",
                    externalName: "prefix",
                    type: "Bool",
                    hasDefaultValue: true
                ),
                SDKFunctionParameter(
                    name: "value",
                    externalName: "new",
                    type: "Int"
                ),
                SDKFunctionParameter(
                    name: "suffix",
                    externalName: "suffix",
                    type: "String",
                    hasDefaultValue: true
                ),
            ],
            returnType: "Void"
        )
        let location = SourceLocation(
            path: file.path,
            line: 1,
            column: 14
        )
        let evidence = SDKFindingEvidence(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: baseline.preciseIdentifier,
            fullyQualifiedName: baseline.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .signatureChanged,
            observedChange: "One label changed and added parameters are defaulted.",
            oldDeclaration: baseline.declaration,
            newDeclaration: candidate.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.signatureChanged.usr.perform.old",
            category: .sdk,
            title: "SDK API signature changed",
            explanation: evidence.observedChange,
            severity: .warning,
            confidence: .high,
            location: location,
            origin: .sdk,
            sdkEvidence: evidence
        )

        let result = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: baselineIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [baseline]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: candidateIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [candidate]
                ),
            ],
            projectRoot: directory.url
        )

        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(result.0[0].originalText, "old")
        XCTAssertEqual(result.0[0].replacementText, "new")
        XCTAssertEqual(
            result.0[0].evidenceSource,
            .mechanicalSignatureChange
        )
    }

    private func compilerFinding(
        id: String,
        path: String,
        line: Int,
        message: String
    ) -> Finding {
        Finding(
            findingID: id,
            category: .compiler,
            title: "New compiler diagnostic",
            explanation: message,
            severity: .warning,
            confidence: .high,
            location: SourceLocation(path: path, line: line, column: 1),
            origin: .compiler,
            target: "Feature"
        )
    }
}
