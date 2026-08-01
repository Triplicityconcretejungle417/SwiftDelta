//===--- RepairPlanningTests.swift - SwiftDelta ------------------------------------------===//
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

final class RepairPlanningTests: XCTestCase {
    func testPreviewDiffAndJSONNeverModifySource() throws {
        let directory = try TestDirectory(name: "repair-preview")
        defer { directory.remove() }
        let file = try directory.write("Sources/App.swift", "let value = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "value",
            replacement: "renamed",
            identifier: "repair.preview"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let diff = try RepairPlanRenderer.render(plan, format: .diff)
        let json = try RepairPlanRenderer.render(plan, format: .json)

        XCTAssertTrue(String(decoding: diff, as: UTF8.self).contains("-let value = 1"))
        XCTAssertTrue(String(decoding: diff, as: UTF8.self).contains("+let renamed = 1"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let value = 1\n")
        XCTAssertEqual(try RepairPlanJSON.decode(json).repairs.count, 1)
    }

    func testJSONPlanEncodingIsStableAndSeparatelyVersioned() throws {
        let directory = try TestDirectory(name: "repair-json")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new",
            identifier: "repair.stable"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair],
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )

        let first = try RepairPlanJSON.encode(plan)
        let second = try RepairPlanJSON.encode(plan)

        XCTAssertEqual(first, second)
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains(
            #""repairPlanFormatVersion" : "3.0""#
        ))
        XCTAssertFalse(String(decoding: first, as: UTF8.self).contains(
            "reportFormatVersion"
        ))
    }

    func testConflictDetectionCoversDuplicatesContradictionsAndOverlap() throws {
        let directory = try TestDirectory(name: "repair-conflicts")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let alpha = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let first = try makeRepair(
            document: document,
            original: "alpha",
            replacement: "beta",
            identifier: "repair.1",
            finding: "finding.1"
        )
        let duplicate = ProposedRepair(
            repairIdentifier: "repair.2",
            relatedFindingIdentifier: "finding.2",
            evidenceSource: first.evidenceSource,
            language: first.language,
            filePath: first.filePath,
            sourceRange: first.sourceRange,
            originalText: first.originalText,
            replacementText: first.replacementText,
            fileFingerprint: first.fileFingerprint,
            confidence: first.confidence,
            safety: first.safety,
            explanation: first.explanation,
            verificationRequirement: first.verificationRequirement
        )
        let contradictory = ProposedRepair(
            repairIdentifier: "repair.3",
            relatedFindingIdentifier: "finding.3",
            evidenceSource: first.evidenceSource,
            language: first.language,
            filePath: first.filePath,
            sourceRange: first.sourceRange,
            originalText: first.originalText,
            replacementText: "gamma",
            fileFingerprint: first.fileFingerprint,
            confidence: first.confidence,
            safety: first.safety,
            explanation: first.explanation,
            verificationRequirement: first.verificationRequirement
        )
        let overlapRange = RepairSourceRange(
            start: first.sourceRange.start,
            end: RepairSourcePosition(
                line: first.sourceRange.end.line,
                column: first.sourceRange.end.column + 2,
                utf8Offset: first.sourceRange.end.utf8Offset + 2
            )
        )
        let overlap = ProposedRepair(
            repairIdentifier: "repair.4",
            relatedFindingIdentifier: "finding.4",
            evidenceSource: first.evidenceSource,
            language: first.language,
            filePath: first.filePath,
            sourceRange: overlapRange,
            originalText: "alpha =",
            replacementText: "delta =",
            fileFingerprint: first.fileFingerprint,
            confidence: first.confidence,
            safety: first.safety,
            explanation: first.explanation,
            verificationRequirement: first.verificationRequirement
        )

        let conflicts = RepairPlanBuilder.conflicts(
            in: [first, duplicate, contradictory, overlap]
        )

        XCTAssertTrue(conflicts.contains { $0.kind == .multipleFindingsSameEdit })
        XCTAssertTrue(conflicts.contains { $0.kind == .contradictory })
        XCTAssertTrue(conflicts.contains { $0.kind == .overlapping })
    }

    func testCompilerFixItSafetyRejectsJudgmentAndAcceptsMechanicalTokens() {
        XCTAssertEqual(
            RepairSafetyClassifier.classify(original: "vlaue", replacement: "value"),
            .safe
        )
        XCTAssertEqual(
            RepairSafetyClassifier.classify(original: "", replacement: ";"),
            .safe
        )
        XCTAssertEqual(
            RepairSafetyClassifier.classify(original: "", replacement: "try "),
            .reviewRequired
        )
        XCTAssertEqual(
            RepairSafetyClassifier.classify(original: "old", replacement: "await"),
            .reviewRequired
        )
    }

    func testSDKRenameRequiresStableUnambiguousCompatibleSymbols() throws {
        let directory = try TestDirectory(name: "sdk-repair")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            "import FictionalSDK\nfunc run() { oldCall(value: 1) }\n"
        )
        let baselineIdentity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Baseline.app"
        )
        let candidateIdentity = makeSDKIdentity(
            xcode: "2", build: "2A", sdk: "2", path: "/Synthetic/Candidate.app"
        )
        let parameter = SDKFunctionParameter(
            name: "value",
            externalName: "value",
            type: "Swift.Int"
        )
        let old = SDKSymbol(
            id: "usr.old",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old",
            fullyQualifiedName: "FictionalSDK.oldCall(value:)",
            baseName: "oldCall",
            kind: "swift.func",
            declaration: "func oldCall(value: Int)",
            signature: "func oldCall(value: Int)",
            parameters: [parameter],
            returnType: "Swift.Void",
            renamedDestination: "FictionalSDK.newCall(value:)"
        )
        let new = SDKSymbol(
            id: "usr.new",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.new",
            fullyQualifiedName: "FictionalSDK.newCall(value:)",
            baseName: "newCall",
            kind: "swift.func",
            declaration: "func newCall(value: Int)",
            signature: "func newCall(value: Int)",
            parameters: [parameter],
            returnType: "Swift.Void"
        )
        let location = SourceLocation(path: file.path, line: 2, column: 14)
        let evidence = SDKFindingEvidence(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old",
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .renamed,
            observedChange: "Synthetic rename.",
            oldDeclaration: old.declaration,
            newDeclaration: new.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.renamed.usr.old",
            category: .sdk,
            title: "SDK API renamed",
            explanation: "Synthetic.",
            severity: .warning,
            confidence: .high,
            location: location,
            origin: .sdk,
            sdkEvidence: evidence
        )
        let repairs = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: baselineIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: candidateIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [new]
                ),
            ],
            projectRoot: directory.url
        ).0

        XCTAssertEqual(repairs.count, 1)
        XCTAssertEqual(repairs[0].originalText, "oldCall")
        XCTAssertEqual(repairs[0].replacementText, "newCall")
        XCTAssertEqual(repairs[0].evidenceSource, .sdkRename)
        XCTAssertEqual(repairs[0].symbols?.candidatePreciseIdentifier, "usr.new")
    }

    func testSDKRenameNormalizesQualifiedSymbolGraphBaseNames() throws {
        let directory = try TestDirectory(name: "qualified-sdk-repair")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            "import FictionalSDK\nlet mode: Widget.Mode = .legacy\n"
        )
        let baselineIdentity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Baseline.app"
        )
        let candidateIdentity = makeSDKIdentity(
            xcode: "2", build: "2A", sdk: "2", path: "/Synthetic/Candidate.app"
        )
        let old = SDKSymbol(
            id: "usr.mode.legacy",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.mode.legacy",
            fullyQualifiedName: "FictionalSDK.Widget.Mode.legacy",
            baseName: "Mode.legacy",
            kind: "swift.enum.case",
            declaration: "case legacy",
            signature: "case legacy",
            renamedDestination: "Widget.Mode.current"
        )
        let new = SDKSymbol(
            id: "usr.mode.current",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.mode.current",
            fullyQualifiedName: "FictionalSDK.Widget.Mode.current",
            baseName: "Mode.current",
            kind: "swift.enum.case",
            declaration: "case current",
            signature: "case current"
        )
        let location = SourceLocation(path: file.path, line: 2, column: 26)
        let evidence = SDKFindingEvidence(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: old.preciseIdentifier,
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .renamed,
            observedChange: "Synthetic enum case rename.",
            oldDeclaration: old.declaration,
            newDeclaration: new.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.renamed.qualified",
            category: .sdk,
            title: "SDK API renamed",
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
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: candidateIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [new]
                ),
            ],
            projectRoot: directory.url
        )

        XCTAssertEqual(result.0.count, 1)
        XCTAssertEqual(result.0[0].originalText, "legacy")
        XCTAssertEqual(result.0[0].replacementText, "current")
        XCTAssertTrue(result.1.isEmpty)
    }

    func testSDKRenameDoesNotTokenReplaceAcrossOwningDeclarations() throws {
        let directory = try TestDirectory(name: "moved-sdk-repair")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            "import FictionalSDK\nfunc inspect(_ value: Widget) { _ = value.oldValue }\n"
        )
        let identity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Xcode.app"
        )
        let old = SDKSymbol(
            id: "usr.old.property",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old.property",
            fullyQualifiedName: "FictionalSDK.Widget.oldValue",
            baseName: "Widget.oldValue",
            kind: "swift.property",
            declaration: "var oldValue: Bool { get }",
            signature: "var oldValue: Bool { get }",
            returnType: "Swift.Bool",
            renamedDestination: "Widget.configuration.newValue"
        )
        let new = SDKSymbol(
            id: "usr.new.property",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.new.property",
            fullyQualifiedName: "FictionalSDK.Widget.configuration.newValue",
            baseName: "configuration.newValue",
            kind: "swift.property",
            declaration: "var newValue: Bool { get }",
            signature: "var newValue: Bool { get }",
            returnType: "Swift.Bool"
        )
        let location = SourceLocation(path: file.path, line: 2, column: 44)
        let evidence = SDKFindingEvidence(
            baseline: identity,
            candidate: identity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: old.preciseIdentifier,
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .renamed,
            observedChange: "Synthetic moved property.",
            oldDeclaration: old.declaration,
            newDeclaration: new.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.renamed.moved",
            category: .sdk,
            title: "SDK API renamed",
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
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [new]
                ),
            ],
            projectRoot: directory.url
        )

        XCTAssertTrue(result.0.isEmpty)
        XCTAssertEqual(result.1.count, 1)
        XCTAssertTrue(
            result.1[0].message.contains("changes the owning declaration")
        )
    }

    func testSDKRenameBuildsReviewableOptionSetPropertyMigration() throws {
        let directory = try TestDirectory(name: "option-set-sdk-repair")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            """
            import FictionalSDK
            func configure(_ value: Widget) {
                value.showsVerticalIndicator = true
            }

            """
        )
        let identity = makeSDKIdentity(
            xcode: "2", build: "2A", sdk: "2", path: "/Synthetic/Xcode.app"
        )
        let old = SDKSymbol(
            id: "usr.old.vertical",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old.vertical",
            fullyQualifiedName: "FictionalSDK.Widget.showsVerticalIndicator",
            baseName: "showsVerticalIndicator",
            kind: "swift.property",
            declaration: "var showsVerticalIndicator: Bool { get set }",
            signature: "var showsVerticalIndicator: Bool",
            returnType: "Bool",
            renamedDestination: "configuration.visibleIndicators"
        )
        let replacement = SDKSymbol(
            id: "usr.new.visible",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.new.visible",
            fullyQualifiedName:
                "FictionalSDK.Widget.Configuration.visibleIndicators",
            baseName: "visibleIndicators",
            kind: "swift.property",
            declaration:
                "var visibleIndicators: Widget.Configuration.Axis { get set }",
            signature: "var visibleIndicators: Widget.Configuration.Axis",
            returnType: "Widget.Configuration.Axis"
        )
        let configuration = SDKSymbol(
            id: "usr.configuration",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.configuration",
            fullyQualifiedName: "FictionalSDK.Widget.configuration",
            baseName: "configuration",
            kind: "swift.property",
            declaration: "var configuration: Widget.Configuration { get }"
        )
        let axis = SDKSymbol(
            id: "usr.axis",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.axis",
            fullyQualifiedName: "FictionalSDK.Widget.Configuration.Axis",
            baseName: "Widget.Configuration.Axis",
            kind: "swift.struct",
            declaration: "struct Axis",
            relationships: [
                SDKSymbolRelationship(kind: "conformsTo", target: "s:s9OptionSetP"),
            ]
        )
        func axisMember(
            _ name: String,
            kind: String = "swift.method",
            declaration: String
        ) -> SDKSymbol {
            SDKSymbol(
                id: "usr.axis.\(name)",
                moduleName: "FictionalSDK",
                preciseIdentifier: "usr.axis.\(name)",
                fullyQualifiedName:
                    "FictionalSDK.Widget.Configuration.Axis.\(name)",
                baseName: name,
                kind: kind,
                declaration: declaration
            )
        }
        let candidateSymbols = [
            replacement,
            configuration,
            axis,
            axisMember(
                "vertical",
                kind: "swift.type.property",
                declaration: "static let vertical: Widget.Configuration.Axis"
            ),
            axisMember("contains", declaration: "func contains(_ member: Self) -> Bool"),
            axisMember("insert", declaration: "mutating func insert(_ member: Self)"),
            axisMember("remove", declaration: "mutating func remove(_ member: Self)"),
        ]
        let location = SourceLocation(path: file.path, line: 3, column: 5)
        let evidence = SDKFindingEvidence(
            baseline: identity,
            candidate: identity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: old.preciseIdentifier,
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .renamed,
            observedChange:
                "The candidate SDK renamed the property to configuration.visibleIndicators.",
            oldDeclaration: old.declaration,
            newDeclaration: replacement.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.renamed.option-set",
            category: .sdk,
            title: "SDK API renamed",
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
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: candidateSymbols
                ),
            ],
            projectRoot: directory.url
        )

        XCTAssertTrue(result.1.isEmpty)
        let repair = try XCTUnwrap(result.0.first)
        XCTAssertEqual(
            repair.originalText,
            "    value.showsVerticalIndicator = true"
        )
        XCTAssertEqual(
            repair.replacementText,
            "    value.configuration.visibleIndicators.insert(.vertical)"
        )
        XCTAssertEqual(repair.safety, .reviewRequired)
        XCTAssertEqual(repair.requiresReview, true)

        let unavailableReplacement = SDKSymbol(
            id: "usr.new.visible",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.new.visible",
            fullyQualifiedName:
                "FictionalSDK.Widget.Configuration.visibleIndicators",
            baseName: "visibleIndicators",
            kind: "swift.property",
            declaration:
                "var visibleIndicators: Widget.Configuration.Axis { get set }",
            signature: "var visibleIndicators: Widget.Configuration.Axis",
            returnType: "Widget.Configuration.Axis",
            availability: [
                SDKAvailability(domain: "SyntheticOS", introduced: "2.0"),
            ]
        )
        let unavailableResult = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [unavailableReplacement]
                        + Array(candidateSymbols.dropFirst())
                ),
            ],
            projectRoot: directory.url,
            targetBuildContexts: [
                TargetBuildContext(
                    toolchainRole: "candidate",
                    xcodeApplicationPath: identity.xcodeApplicationPath,
                    sdkIdentifier: identity.sdkIdentifier,
                    sdkPath: identity.sdkPath,
                    platform: "SyntheticOS",
                    target: "App",
                    moduleName: "App",
                    architecture: "arm64",
                    deploymentTarget: "1.0",
                    sourceFiles: [file.path],
                    compilerArguments: [],
                    evidenceSource: .exactCompilerInvocation,
                    isAuthoritative: true
                ),
            ]
        )
        XCTAssertTrue(unavailableResult.0.isEmpty)
        XCTAssertTrue(
            unavailableResult.1.contains {
                $0.message.contains("availability fallback")
            }
        )
    }

    func testSDKRenameIsNotOfferedForUnresolvedLowConfidenceOrOverloadedSymbol()
        throws
    {
        let directory = try TestDirectory(name: "sdk-repair-negative")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "func run() { oldCall() }\n")
        let identity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Xcode.app"
        )
        let old = SDKSymbol(
            id: "usr.old",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old",
            fullyQualifiedName: "FictionalSDK.oldCall()",
            baseName: "oldCall",
            kind: "swift.func",
            declaration: "func oldCall()",
            signature: "func oldCall()",
            renamedDestination: "FictionalSDK.newCall()"
        )
        let candidates = ["usr.new.1", "usr.new.2"].map {
            SDKSymbol(
                id: $0,
                moduleName: "FictionalSDK",
                preciseIdentifier: $0,
                fullyQualifiedName: "FictionalSDK.newCall()",
                baseName: "newCall",
                kind: "swift.func",
                declaration: "func newCall()",
                signature: "func newCall()"
            )
        }
        let evidence = SDKFindingEvidence(
            baseline: identity,
            candidate: identity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: nil,
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: SourceLocation(path: file.path, line: 1, column: 14),
            changeKind: .renamed,
            observedChange: "Synthetic.",
            oldDeclaration: old.declaration,
            newDeclaration: nil,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .uncertainText
        )
        let finding = Finding(
            findingID: "sdk.renamed.uncertain",
            category: .sdk,
            title: "SDK API renamed",
            explanation: "Synthetic.",
            severity: .warning,
            confidence: .low,
            location: evidence.sourceLocation,
            origin: .sdk,
            sdkEvidence: evidence
        )

        let repairs = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: candidates
                ),
            ],
            projectRoot: directory.url
        ).0

        XCTAssertTrue(repairs.isEmpty)
    }

    func testMechanicalParameterLabelChangeUsesOneExactResolvedCallSiteToken()
        throws
    {
        let directory = try TestDirectory(name: "label-repair")
        defer { directory.remove() }
        let file = try directory.write(
            "A.swift",
            "func run() { call(old: 1) }\n"
        )
        let baselineIdentity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Baseline.app"
        )
        let candidateIdentity = makeSDKIdentity(
            xcode: "2", build: "2A", sdk: "2", path: "/Synthetic/Candidate.app"
        )
        let old = SDKSymbol(
            id: "usr.call",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.call",
            fullyQualifiedName: "FictionalSDK.call(old:)",
            baseName: "call",
            kind: "swift.func",
            declaration: "func call(old value: Int)",
            signature: "func call(old value: Int)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "old",
                    type: "Swift.Int"
                ),
            ],
            returnType: "Swift.Void"
        )
        let new = SDKSymbol(
            id: "usr.call",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.call",
            fullyQualifiedName: "FictionalSDK.call(new:)",
            baseName: "call",
            kind: "swift.func",
            declaration: "func call(new value: Int)",
            signature: "func call(new value: Int)",
            parameters: [
                SDKFunctionParameter(
                    name: "value",
                    externalName: "new",
                    type: "Swift.Int"
                ),
            ],
            returnType: "Swift.Void"
        )
        let location = SourceLocation(path: file.path, line: 1, column: 14)
        let evidence = SDKFindingEvidence(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.call",
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: location,
            changeKind: .parameterLabelsChanged,
            observedChange: "Synthetic label change.",
            oldDeclaration: old.declaration,
            newDeclaration: new.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
        let finding = Finding(
            findingID: "sdk.parameterLabelsChanged.usr.call",
            category: .sdk,
            title: "SDK parameter label changed",
            explanation: "Synthetic.",
            severity: .warning,
            confidence: .high,
            location: location,
            origin: .sdk,
            sdkEvidence: evidence
        )

        let repairs = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: baselineIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: candidateIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [new]
                ),
            ],
            projectRoot: directory.url
        ).0

        XCTAssertEqual(repairs.count, 1)
        XCTAssertEqual(repairs[0].evidenceSource, .mechanicalSignatureChange)
        XCTAssertEqual(repairs[0].originalText, "old")
        XCTAssertEqual(repairs[0].replacementText, "new")
    }

    func testMissingRenameMetadataIncompatibleSignatureAndLocalShadowStayUnrepairable()
        throws
    {
        let directory = try TestDirectory(name: "rename-unrepairable")
        defer { directory.remove() }
        let file = try directory.write(
            "A.swift",
            "func oldCall() {}\nfunc run() { oldCall() }\n"
        )
        let identity = makeSDKIdentity(
            xcode: "1", build: "1A", sdk: "1", path: "/Synthetic/Xcode.app"
        )
        let old = SDKSymbol(
            id: "usr.old",
            moduleName: "FictionalSDK",
            preciseIdentifier: "usr.old",
            fullyQualifiedName: "FictionalSDK.oldCall()",
            baseName: "oldCall",
            kind: "swift.func",
            declaration: "func oldCall()",
            signature: "func oldCall()"
        )
        let evidence = SDKFindingEvidence(
            baseline: identity,
            candidate: identity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: nil,
            fullyQualifiedName: old.fullyQualifiedName,
            sourceLocation: SourceLocation(path: file.path, line: 2, column: 14),
            changeKind: .renamed,
            observedChange: "Synthetic.",
            oldDeclaration: old.declaration,
            newDeclaration: nil,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .uncertainText
        )
        let finding = Finding(
            findingID: "sdk.renamed.shadowed",
            category: .sdk,
            title: "SDK API renamed",
            explanation: "Synthetic.",
            severity: .warning,
            confidence: .low,
            location: evidence.sourceLocation,
            origin: .sdk,
            sdkEvidence: evidence
        )

        let repairs = SDKRepairEvidenceBuilder.build(
            findings: [finding],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: identity,
                    modules: ["FictionalSDK"],
                    symbols: [old]
                ),
            ],
            candidateSnapshots: [],
            projectRoot: directory.url
        ).0

        XCTAssertTrue(repairs.isEmpty)
    }
}
