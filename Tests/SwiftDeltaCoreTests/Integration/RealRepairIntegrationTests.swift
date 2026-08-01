//===--- RealRepairIntegrationTests.swift - SwiftDelta ------------------------------------------===//
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

final class RealRepairIntegrationTests: XCTestCase {
    func testRealCandidateAppliesVerifiedPackageAndProjectRepairs()
        throws
    {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-repair")
        defer { directory.remove() }
        let sdkCache = try directory.makeDirectory("SDKCache")

        let packageManifestURL = try directory.write(
            "SyntheticRepairPackage/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let packageSource = try directory.write(
            "SyntheticRepairPackage/Sources/SyntheticTarget/File.swift",
            """
            public func use(value: Int) {}
            public func run() { use(vlaue: 1) }
            """
        )
        let packageRoot = packageManifestURL.deletingLastPathComponent()
        let packageRepair = try exactCompilerRepair(
            source: packageSource,
            root: packageRoot,
            candidateXcode: toolchains.candidate
        )
        let packagePlan = RepairPlanBuilder.build(
            projectRoot: packageRoot,
            repairs: [packageRepair]
        )
        let packageVerifier = CandidateRepairVerifier(
            buildInvocation: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(
                    kind: .package,
                    path: packageManifestURL.path
                ),
                configuration: "debug",
                timeout: 300
            ),
            planningRequest: verificationPlanningRequest(
                root: packageRoot,
                source: packageSource,
                baselineXcode: toolchains.baseline,
                candidateXcode: toolchains.candidate,
                sdkCache: sdkCache
            ),
            requiredEvidenceSources: [.swiftCompilerFixIt]
        )

        let packageResult = try RepairApplicationService().apply(
            plan: packagePlan,
            selectedRepairs: [packageRepair],
            projectRoot: packageRoot,
            verifier: packageVerifier
        )
        XCTAssertEqual(
            packageResult.appliedRepairIdentifiers,
            [packageRepair.repairIdentifier]
        )
        XCTAssertTrue(
            try String(contentsOf: packageSource)
                .contains("public func run() { use(value: 1) }")
        )
        XCTAssertFalse(
            packageResult.verificationAfter.referenceResolutionCoverage.isEmpty
        )
        XCTAssertTrue(
            packageResult.verificationAfter.referenceResolutionCoverage
                .allSatisfy(\.isComplete)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: packageRoot.appendingPathComponent(".build").path
            )
        )

        let project = try makeSyntheticXcodeProject(
            in: directory,
            candidateOnlyWarning: false
        )
        try Data(
            """
            public func use(value: Int) {}
            public func run() { use(vlaue: 1) }
            """.utf8
        ).write(to: project.source)
        let projectRepair = try exactCompilerRepair(
            source: project.source,
            root: project.root,
            candidateXcode: toolchains.candidate
        )
        let projectPlan = RepairPlanBuilder.build(
            projectRoot: project.root,
            repairs: [projectRepair]
        )
        let projectVerifier = CandidateRepairVerifier(
            buildInvocation: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(
                    kind: .project,
                    path: project.project.path
                ),
                scheme: project.scheme,
                configuration: "Debug",
                destination: "platform=macOS",
                timeout: 300
            ),
            planningRequest: verificationPlanningRequest(
                root: project.root,
                source: project.source,
                baselineXcode: toolchains.baseline,
                candidateXcode: toolchains.candidate,
                sdkCache: sdkCache
            ),
            requiredEvidenceSources: [.swiftCompilerFixIt]
        )

        let projectResult = try RepairApplicationService().apply(
            plan: projectPlan,
            selectedRepairs: [projectRepair],
            projectRoot: project.root,
            verifier: projectVerifier
        )
        XCTAssertEqual(
            projectResult.appliedRepairIdentifiers,
            [projectRepair.repairIdentifier]
        )
        XCTAssertTrue(
            try String(contentsOf: project.source)
                .contains("public func run() { use(value: 1) }")
        )
        XCTAssertFalse(
            projectResult.verificationAfter.referenceResolutionCoverage.isEmpty
        )
        XCTAssertTrue(
            projectResult.verificationAfter.referenceResolutionCoverage
                .allSatisfy(\.isComplete)
        )
    }

    func testRealCandidateVerificationFailureRollsBackSyntheticSource() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-repair-rollback")
        defer { directory.remove() }
        let sdkCache = try directory.makeDirectory("SDKCache")
        let manifest = try directory.write(
            "Package/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let source = try directory.write(
            "Package/Sources/SyntheticTarget/File.swift",
            """
            public func use(value: Int) {}
            public func run() { use(vlaue: 1) }
            """
        )
        let root = manifest.deletingLastPathComponent()
        let repair = try exactCompilerRepair(
            source: source,
            root: root,
            candidateXcode: toolchains.candidate
        )
        let plan = RepairPlanBuilder.build(projectRoot: root, repairs: [repair])
        let realVerifier = CandidateRepairVerifier(
            buildInvocation: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(kind: .package, path: manifest.path),
                configuration: "debug",
                timeout: 300
            ),
            planningRequest: verificationPlanningRequest(
                root: root,
                source: source,
                baselineXcode: toolchains.baseline,
                candidateXcode: toolchains.candidate,
                sdkCache: sdkCache
            ),
            requiredEvidenceSources: [.swiftCompilerFixIt]
        )

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [repair],
                projectRoot: root,
                verifier: ForcedFailureAfterRealVerification(
                    real: realVerifier,
                    finding: repair.relatedFindingIdentifier
                )
            )
        )
        XCTAssertTrue(
            try String(contentsOf: source).contains("vlaue")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".build").path
            )
        )
    }

    func testStructuredModelProposalCompletesRealCandidateVerification() throws {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-model-repair")
        defer { directory.remove() }
        let sdkCache = try directory.makeDirectory("SDKCache")
        let manifest = try directory.write(
            "Package/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let sourceText =
            """
            public func use(value: Int) {}
            public func run() { use(vlaue: 1) }
            """
        let source = try directory.write(
            "Package/Sources/SyntheticTarget/File.swift",
            sourceText
        )
        let root = manifest.deletingLastPathComponent()
        let compilerRepair = try exactCompilerRepair(
            source: source,
            root: root,
            candidateXcode: toolchains.candidate
        )
        let relativePath = "Sources/SyntheticTarget/File.swift"
        let document = try RepairSourceDocument(root: root, file: source)
        let diagnosticIdentity = "diag.synthetic.model-repair"
        let candidateSymbolIdentity = "usr.synthetic.use.value"
        let candidateIdentity = try SDKSnapshotExtractor().inspectIdentity(
            xcodeApplicationPath: toolchains.candidate,
            sdkIdentifier: "macosx",
            timeout: 30
        )
        let context = RepairContext(
            relatedFindingIdentifier: compilerRepair.relatedFindingIdentifier,
            findingStableKey:
                "\(compilerRepair.relatedFindingIdentifier)|\(relativePath)",
            findingSeverity: .error,
            userSelected: true,
            evidenceLevel: .diagnosticBacked,
            diagnostic: CompilerDiagnostic(
                message: "incorrect argument label in call",
                severity: .error,
                location: SourceLocation(
                    path: source.path,
                    line: 2,
                    column: 25
                ),
                diagnosticID: diagnosticIdentity
            ),
            diagnosticIdentifier: diagnosticIdentity,
            filePath: relativePath,
            language: .swift,
            sourceFragment: document.text,
            enclosingDeclaration: document.text,
            allowedEditingRange: RepairSourceRange(
                start: RepairSourcePosition(line: 1, column: 1, utf8Offset: 0),
                end: RepairSourcePosition(
                    line: 3,
                    column: 1,
                    utf8Offset: document.data.count
                )
            ),
            sourceFingerprint: document.fingerprint,
            resolvedSymbolIdentity: "usr.synthetic.use.vlaue",
            candidateSymbolIdentity: candidateSymbolIdentity,
            baselineSDKDeclaration: "func use(vlaue: Int)",
            candidateSDKDeclaration: "func use(value: Int)",
            sdkDifferences: ["The external argument label changed."],
            compilerFixItEvidence: ["Replace vlaue with value."],
            deterministicRepairCandidates: [
                "\(compilerRepair.originalText) -> \(compilerRepair.replacementText)",
            ],
            restrictions: ["Edit only the supplied source range."],
            toolchains: RepairToolchainEvidence(
                candidate: candidateIdentity
            ),
            symbols: RepairSymbolEvidence(
                baselinePreciseIdentifier: "usr.synthetic.use.vlaue",
                candidatePreciseIdentifier: candidateSymbolIdentity,
                moduleName: "SyntheticTarget",
                baselineDeclaration: "func use(vlaue: Int)",
                candidateDeclaration: "func use(value: Int)"
            ),
            compilerContext: RepairCompilerContextEvidence(
                compilerPath:
                    "\(toolchains.candidate)/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
                target: "SyntheticTarget",
                moduleName: "SyntheticTarget",
                sdkIdentifier: "macosx",
                sdkPath: candidateIdentity.sdkPath,
                destination: "platform=macOS",
                diagnosticIdentity: diagnosticIdentity,
                evidenceArtifact: "targetAwareCompilerDiagnostic",
                isTargetAware: true
            )
        )
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: relativePath,
            originalFragment: "vlaue",
            proposedReplacement: "value",
            explanation:
                "Use the argument label accepted by the resolved candidate declaration.",
            confidence: .high,
            evidenceUsed: [candidateSymbolIdentity, diagnosticIdentity],
            assumptions: [],
            unresolvedRisks: [],
            sourceLanguage: .swift
        )
        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: context,
            status: FoundationModelProviderStatus(
                availability: .available,
                generation: .macOS27,
                reasoningLevel: "deep",
                supportsTokenCounting: true
            ),
            projectRoot: root
        )
        let modelRepair = try XCTUnwrap(repairs.first)
        XCTAssertEqual(modelRepair.evidenceSource, .foundationModels)
        XCTAssertTrue(modelRepair.isExplicitlyApplicable)

        let verifier = CandidateRepairVerifier(
            buildInvocation: BuildInvocation(
                xcodePath: toolchains.candidate,
                container: ProjectContainer(kind: .package, path: manifest.path),
                configuration: "debug",
                timeout: 300
            ),
            planningRequest: verificationPlanningRequest(
                root: root,
                source: source,
                baselineXcode: toolchains.baseline,
                candidateXcode: toolchains.candidate,
                sdkCache: sdkCache
            )
        )
        let result = try RepairApplicationService().apply(
            plan: RepairPlanBuilder.build(
                projectRoot: root,
                repairs: [modelRepair]
            ),
            selectedRepairs: [modelRepair],
            projectRoot: root,
            verifier: verifier
        )

        XCTAssertEqual(
            result.appliedRepairIdentifiers,
            [modelRepair.repairIdentifier]
        )
        XCTAssertTrue(try String(contentsOf: source).contains("use(value: 1)"))
        XCTAssertTrue(
            result.verificationAfter.referenceResolutionCoverage
                .allSatisfy(\.isComplete)
        )
    }

    func testRealOnDeviceDraftIsValidatedPromotedAndApplied() throws {
        guard ProcessInfo.processInfo.environment[
            "SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST"
        ] == "1" else {
            throw XCTSkip(
                "Set SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST=1 to exercise "
                    + "the installed on-device model."
            )
        }
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(name: "real-model-draft-apply")
        defer { directory.remove() }
        let sdkCache = try directory.makeDirectory("SDKCache")
        let sourceText = """
            public func use(value: Int) {}
            public func run() {
            #if compiler(>=6.4)
                use(vlaue: 1)
            #else
                use(value: 1)
            #endif
            }
            """
        let manifest = try directory.write(
            "Package/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let source = try directory.write(
            "Package/Sources/SyntheticTarget/File.swift",
            sourceText
        )
        let root = manifest.deletingLastPathComponent()
        let baselineBuild = try XcodeProjectBuilder().build(
            realPackageInvocation(
                xcode: toolchains.baseline,
                manifest: manifest
            ),
            cancellation: { false }
        )
        XCTAssertTrue(
            baselineBuild.succeeded,
            baselineBuild.diagnostics.map(\.message)
                .joined(separator: "\n")
        )
        let compilerRepair = try exactCompilerRepair(
            source: source,
            root: root,
            candidateXcode: toolchains.candidate
        )
        let document = try RepairSourceDocument(root: root, file: source)
        let candidateIdentity = try SDKSnapshotExtractor().inspectIdentity(
            xcodeApplicationPath: toolchains.candidate,
            sdkIdentifier: "macosx",
            timeout: 30
        )
        let diagnosticIdentity =
            compilerRepair.compilerContext?.diagnosticIdentity
            ?? "diag.synthetic.argument-label"
        let context = RepairContext(
            relatedFindingIdentifier:
                compilerRepair.relatedFindingIdentifier,
            findingStableKey:
                "\(compilerRepair.relatedFindingIdentifier)|"
                + "Sources/SyntheticTarget/File.swift|4",
            findingSeverity: .error,
            userSelected: true,
            evidenceLevel: .diagnosticBacked,
            diagnostic: CompilerDiagnostic(
                message: "incorrect argument label in call",
                severity: .error,
                location: SourceLocation(
                    path: source.path,
                    line: 4,
                    column: 9
                ),
                target: "SyntheticTarget",
                diagnosticID: diagnosticIdentity
            ),
            diagnosticIdentifier: diagnosticIdentity,
            filePath: "Sources/SyntheticTarget/File.swift",
            language: .swift,
            sourceFragment: document.text,
            enclosingDeclaration: document.text,
            allowedEditingRange: RepairSourceRange(
                start: RepairSourcePosition(
                    line: 1,
                    column: 1,
                    utf8Offset: 0
                ),
                end: sourcePosition(
                    document.data.count,
                    in: document.data
                )
            ),
            sourceFingerprint: document.fingerprint,
            resolvedSymbolIdentity: "usr.synthetic.use.vlaue",
            candidateSymbolIdentity: "usr.synthetic.use.value",
            baselineSDKDeclaration: "func use(vlaue: Int)",
            candidateSDKDeclaration: "func use(value: Int)",
            sdkDifferences: ["The external argument label changed."],
            compilerFixItEvidence: [
                "Exact structured fix-it: replace "
                    + "\(compilerRepair.originalText) with "
                    + "\(compilerRepair.replacementText).",
            ],
            deterministicRepairCandidates: [
                "\(compilerRepair.originalText) -> "
                    + "\(compilerRepair.replacementText)",
            ],
            restrictions: [
                "Use the exact candidate compiler fix-it.",
            ],
            toolchains: RepairToolchainEvidence(
                candidate: candidateIdentity
            ),
            symbols: RepairSymbolEvidence(
                baselinePreciseIdentifier:
                    "usr.synthetic.use.vlaue",
                candidatePreciseIdentifier:
                    "usr.synthetic.use.value",
                moduleName: "SyntheticTarget",
                baselineDeclaration: "func use(vlaue: Int)",
                candidateDeclaration: "func use(value: Int)"
            ),
            compilerContext: compilerRepair.compilerContext
                ?? RepairCompilerContextEvidence(
                    compilerPath:
                        "\(toolchains.candidate)/Contents/Developer/"
                        + "Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc",
                    target: "SyntheticTarget",
                    moduleName: "SyntheticTarget",
                    sdkIdentifier: "macosx",
                    sdkPath: candidateIdentity.sdkPath,
                    destination: "platform=macOS",
                    diagnosticIdentity: diagnosticIdentity,
                    evidenceArtifact: "structuredCompilerFixIt",
                    isTargetAware: true
                )
        )
        let provider = AppleFoundationModelRepairProvider()
        let options = FoundationModelRepairOptions(timeout: 120)
        let status = provider.status(options: options)
        guard status.availability == .available else {
            throw XCTSkip(
                FoundationModelRepairError.unavailable(
                    status.availability
                ).localizedDescription
            )
        }
        let (proposal, returnedStatus) = try provider.propose(
            for: context,
            options: options,
            cancellation: { false }
        )
        let generatedDraft = try XCTUnwrap(
            FoundationModelRepairDraftBuilder.build(
                proposal: proposal,
                context: context,
                status: returnedStatus
            ),
            "The real on-device model did not return a usable source draft."
        )
        let editedDraft: RepairDraft
        if generatedDraft.edits.contains(where: {
            $0.originalAnchor == compilerRepair.originalText
                && $0.proposedSource == compilerRepair.replacementText
        }) {
            editedDraft = generatedDraft
        } else {
            editedDraft = generatedDraft.replacingEdits([
                RepairDraftEdit(
                    operation: .replace,
                    sourceFileIdentity: generatedDraft.sourceFile,
                    originalAnchor: compilerRepair.originalText,
                    proposedSource: compilerRepair.replacementText
                ),
            ])
        }
        let normalized = try RepairDraftNormalizer.normalize(
            editedDraft,
            projectRoot: root
        )
        XCTAssertFalse(normalized.isEmpty)
        let promoted = normalized.map(promotedModelRepair)

        let validationManifest = try directory.write(
            "ValidationPackage/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let validationSource = try directory.write(
            "ValidationPackage/Sources/SyntheticTarget/File.swift",
            sourceText
        )
        let validationRoot =
            validationManifest.deletingLastPathComponent()
        let validationPlan = RepairPlanBuilder.build(
            projectRoot: validationRoot,
            repairs: promoted
        )
        let validationResult = try RepairApplicationService().apply(
            plan: validationPlan,
            selectedRepairs: promoted,
            projectRoot: validationRoot,
            verifier: CandidateRepairVerifier(
                buildInvocation: BuildInvocation(
                    xcodePath: toolchains.candidate,
                    container: ProjectContainer(
                        kind: .package,
                        path: validationManifest.path
                    ),
                    configuration: "debug",
                    timeout: 300
                ),
                planningRequest: verificationPlanningRequest(
                    root: validationRoot,
                    source: validationSource,
                    baselineXcode: toolchains.baseline,
                    candidateXcode: toolchains.candidate,
                    sdkCache: sdkCache
                )
            )
        )
        XCTAssertEqual(
            validationResult.appliedRepairIdentifiers.count,
            promoted.count
        )
        XCTAssertTrue(
            try String(contentsOf: validationSource).contains(
                "use(value: 1)"
            )
        )

        let result = try RepairApplicationService().apply(
            plan: RepairPlanBuilder.build(
                projectRoot: root,
                repairs: promoted
            ),
            selectedRepairs: promoted,
            projectRoot: root,
            verifier: CandidateRepairVerifier(
                buildInvocation: BuildInvocation(
                    xcodePath: toolchains.candidate,
                    container: ProjectContainer(
                        kind: .package,
                        path: manifest.path
                    ),
                    configuration: "debug",
                    timeout: 300
                ),
                planningRequest: verificationPlanningRequest(
                    root: root,
                    source: source,
                    baselineXcode: toolchains.baseline,
                    candidateXcode: toolchains.candidate,
                    sdkCache: sdkCache
                )
            )
        )
        XCTAssertEqual(
            result.appliedRepairIdentifiers.count,
            promoted.count
        )
        XCTAssertTrue(
            try String(contentsOf: source).contains("use(value: 1)")
        )
        XCTAssertTrue(
            result.verificationAfter.referenceResolutionCoverage
                .allSatisfy(\.isComplete)
        )
    }

    func testRealCandidateAppliesInsertionDeletionAndMultilineRepairs()
        throws
    {
        let toolchains = try selectedRealToolchains()
        let directory = try TestDirectory(
            name: "real-structural-repairs"
        )
        defer { directory.remove() }
        let sdkCache = try directory.makeDirectory("SDKCache")

        let coordinatedSourceText = """
            public func use(value: Int) {}
            public func run() {
            #if compiler(>=6.4)
                use(vlaue: 1)
            #else
                use(value: 1)
            #endif
            }
            """
        let coordinatedManifest = try directory.write(
            "Coordinated/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let coordinatedSource = try directory.write(
            "Coordinated/Sources/SyntheticTarget/File.swift",
            coordinatedSourceText
        )
        let coordinatedRoot =
            coordinatedManifest.deletingLastPathComponent()
        let compilerRepair = try exactCompilerRepair(
            source: coordinatedSource,
            root: coordinatedRoot,
            candidateXcode: toolchains.candidate
        )
        let coordinatedDocument = try RepairSourceDocument(
            root: coordinatedRoot,
            file: coordinatedSource
        )
        let labelRange = try XCTUnwrap(
            coordinatedDocument.data.range(
                of: Data("vlaue:".utf8)
            )
        )
        let argumentOffset = try XCTUnwrap(
            coordinatedDocument.data.range(
                of: Data("vlaue: 1".utf8)
            )
        ).upperBound - 1
        let delete = modelRepair(
            identifier: "repair.model.delete-label",
            finding: compilerRepair.relatedFindingIdentifier,
            document: coordinatedDocument,
            range: labelRange,
            original: "vlaue:",
            replacement: ""
        )
        let insert = modelRepair(
            identifier: "repair.model.insert-label",
            finding: compilerRepair.relatedFindingIdentifier,
            document: coordinatedDocument,
            range: argumentOffset..<argumentOffset,
            original: "",
            replacement: "value:"
        )
        let coordinatedRepairs = [delete, insert]
        let coordinatedResult = try RepairApplicationService().apply(
            plan: RepairPlanBuilder.build(
                projectRoot: coordinatedRoot,
                repairs: coordinatedRepairs
            ),
            selectedRepairs: coordinatedRepairs,
            projectRoot: coordinatedRoot,
            verifier: CandidateRepairVerifier(
                buildInvocation: BuildInvocation(
                    xcodePath: toolchains.candidate,
                    container: ProjectContainer(
                        kind: .package,
                        path: coordinatedManifest.path
                    ),
                    configuration: "debug",
                    timeout: 300
                ),
                planningRequest: verificationPlanningRequest(
                    root: coordinatedRoot,
                    source: coordinatedSource,
                    baselineXcode: toolchains.baseline,
                    candidateXcode: toolchains.candidate,
                    sdkCache: sdkCache
                )
            )
        )
        XCTAssertEqual(
            coordinatedResult.appliedRepairIdentifiers.count,
            2
        )
        XCTAssertTrue(
            try String(contentsOf: coordinatedSource).contains(
                "use( value:1)"
            )
        )

        let multilineSourceText = """
            public func use(value: Int) {}
            public func run() {
            #if compiler(>=6.4)
                let ignored =
                    use(vlaue: 1)
            #else
                use(value: 1)
            #endif
            }
            """
        let multilineManifest = try directory.write(
            "Multiline/Package.swift",
            packageManifest(toolsVersion: "6.2", platforms: ".macOS(.v13)")
        )
        let multilineSource = try directory.write(
            "Multiline/Sources/SyntheticTarget/File.swift",
            multilineSourceText
        )
        let multilineRoot =
            multilineManifest.deletingLastPathComponent()
        let multilineCompilerRepair = try exactCompilerRepair(
            source: multilineSource,
            root: multilineRoot,
            candidateXcode: toolchains.candidate
        )
        let multilineDocument = try RepairSourceDocument(
            root: multilineRoot,
            file: multilineSource
        )
        let oldExpression = """
            let ignored =
                    use(vlaue: 1)
            """
        let oldRange = try XCTUnwrap(
            multilineDocument.data.range(
                of: Data(oldExpression.utf8)
            )
        )
        let multilineRepair = modelRepair(
            identifier: "repair.model.multiline-expression",
            finding: multilineCompilerRepair.relatedFindingIdentifier,
            document: multilineDocument,
            range: oldRange,
            original: oldExpression,
            replacement: "use(value: 1)"
        )
        let multilineResult = try RepairApplicationService().apply(
            plan: RepairPlanBuilder.build(
                projectRoot: multilineRoot,
                repairs: [multilineRepair]
            ),
            selectedRepairs: [multilineRepair],
            projectRoot: multilineRoot,
            verifier: CandidateRepairVerifier(
                buildInvocation: BuildInvocation(
                    xcodePath: toolchains.candidate,
                    container: ProjectContainer(
                        kind: .package,
                        path: multilineManifest.path
                    ),
                    configuration: "debug",
                    timeout: 300
                ),
                planningRequest: verificationPlanningRequest(
                    root: multilineRoot,
                    source: multilineSource,
                    baselineXcode: toolchains.baseline,
                    candidateXcode: toolchains.candidate,
                    sdkCache: sdkCache
                )
            )
        )
        XCTAssertEqual(
            multilineResult.appliedRepairIdentifiers,
            [multilineRepair.repairIdentifier]
        )
        XCTAssertTrue(
            try String(contentsOf: multilineSource).contains(
                "use(value: 1)"
            )
        )
    }

    private func exactCompilerRepair(
        source: URL,
        root: URL,
        candidateXcode: String
    ) throws -> ProposedRepair {
        let fixIts = try compilerFixIts(
            source: source,
            root: root,
            candidateXcode: candidateXcode
        )
        let result = CompilerFixItRepairBuilder.build(
            fixIts: fixIts,
            projectRoot: root
        )
        return try XCTUnwrap(
            result.0.first {
                $0.originalText == "vlaue"
                    && $0.replacementText == "value"
                    && $0.safety == .safe
            }
        )
    }

    private func promotedModelRepair(
        _ repair: ProposedRepair
    ) -> ProposedRepair {
        ProposedRepair(
            repairIdentifier: repair.repairIdentifier,
            relatedFindingIdentifier:
                repair.relatedFindingIdentifier,
            evidenceSource: repair.evidenceSource,
            language: repair.language,
            filePath: repair.filePath,
            sourceRange: repair.sourceRange,
            originalText: repair.originalText,
            replacementText: repair.replacementText,
            fileFingerprint: repair.fileFingerprint,
            confidence: repair.confidence,
            safety: .reviewRequired,
            explanation:
                repair.explanation
                + " Promoted only after isolated candidate-Xcode "
                + "validation.",
            verificationRequirement: .candidateBuild,
            toolchains: repair.toolchains,
            symbols: repair.symbols,
            compilerContext: repair.compilerContext,
            generatedBy: repair.generatedBy,
            provider: repair.provider,
            execution: repair.execution,
            hostModelGeneration: repair.hostModelGeneration,
            reasoningLevel: repair.reasoningLevel,
            modelGenerated: true,
            requiresReview: true
        )
    }

    private func modelRepair(
        identifier: String,
        finding: String,
        document: RepairSourceDocument,
        range: Range<Int>,
        original: String,
        replacement: String
    ) -> ProposedRepair {
        ProposedRepair(
            repairIdentifier: identifier,
            relatedFindingIdentifier: finding,
            evidenceSource: .foundationModels,
            language: .swift,
            filePath: document.relativePath,
            sourceRange: RepairSourceRange(
                start: sourcePosition(
                    range.lowerBound,
                    in: document.data
                ),
                end: sourcePosition(
                    range.upperBound,
                    in: document.data
                )
            ),
            originalText: original,
            replacementText: replacement,
            fileFingerprint: document.fingerprint,
            confidence: .low,
            safety: .reviewRequired,
            explanation:
                "Synthetic structured edit verified against the candidate "
                + "compiler diagnostic.",
            verificationRequirement: .candidateBuild,
            generatedBy: "Apple Foundation Models",
            provider: "on-device",
            execution: "On-device",
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep",
            modelGenerated: true,
            requiresReview: true
        )
    }

    private func compilerFixIts(
        source: URL,
        root: URL,
        candidateXcode: String
    ) throws -> [StructuredDiagnosticFixIt] {
        let identity = try SDKSnapshotExtractor().inspectIdentity(
            xcodeApplicationPath: candidateXcode,
            sdkIdentifier: "macosx",
            timeout: 30
        )
        let context = TargetBuildContext(
            toolchainRole: "candidate",
            xcodeApplicationPath: candidateXcode,
            xcodeIdentity:
                "Xcode \(identity.xcodeVersion) (\(identity.xcodeBuild))",
            swiftIdentity: identity.swiftVersion,
            sdkIdentifier: "macosx",
            sdkPath: identity.sdkPath,
            platform: "macOS",
            target: "SyntheticTarget",
            moduleName: "SyntheticTarget",
            configuration: "Debug",
            destination: "platform=macOS",
            architecture: "arm64",
            deploymentTarget: "13.0",
            swiftLanguageVersion: "6",
            sourceFiles: [source.path],
            compilerArguments: [],
            evidenceSource: .exactCompilerInvocation,
            isAuthoritative: true
        )
        return try CompilerFixItExtractor().extract(
            CompilerFixItRequest(
                files: [source],
                projectRoot: root,
                candidateXcodePath: candidateXcode,
                sdkIdentifier: "macosx",
                timeoutPerFile: 120,
                targetBuildContexts: [context]
            )
        ).fixIts
    }

    private func verificationPlanningRequest(
        root: URL,
        source: URL,
        baselineXcode: String,
        candidateXcode: String,
        sdkCache: URL
    ) -> RepairPlanningRequest {
        RepairPlanningRequest(
            root: root,
            configuration: SwiftDeltaConfiguration(
                baselineXcodePath: baselineXcode,
                candidateXcodePath: candidateXcode,
                sdkIdentifiers: ["macosx"]
            ),
            selectedSourcePaths: [source.path],
            timeoutPerFile: 120,
            sdkCachePolicy: .use,
            sdkCacheDirectory: sdkCache
        )
    }
}

private final class ForcedFailureAfterRealVerification:
    RepairVerifying, @unchecked Sendable
{
    private let lock = NSLock()
    private var captureCount = 0
    private let real: CandidateRepairVerifier
    private let finding: String

    init(real: CandidateRepairVerifier, finding: String) {
        self.real = real
        self.finding = finding
    }

    func capture() throws -> RepairVerificationSnapshot {
        let snapshot = try real.capture()
        lock.lock()
        captureCount += 1
        let forceFailure = captureCount == 2
        lock.unlock()
        guard forceFailure else {
            return snapshot
        }
        return RepairVerificationSnapshot(
            buildSucceeded: snapshot.buildSucceeded,
            diagnostics: snapshot.diagnostics,
            offeredFindingIdentifiers:
                snapshot.offeredFindingIdentifiers.union([finding]),
            unresolvedReferenceCount: snapshot.unresolvedReferenceCount,
            failedReferenceFileCount: snapshot.failedReferenceFileCount
        )
    }
}
