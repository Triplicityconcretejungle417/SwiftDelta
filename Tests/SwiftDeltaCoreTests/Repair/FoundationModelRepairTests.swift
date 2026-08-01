//===--- FoundationModelRepairTests.swift - SwiftDelta ------------------------------------------===//
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

final class FoundationModelRepairTests: XCTestCase {
    func testRealOnDeviceProviderWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment[
            "SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST"
        ] == "1" else {
            throw XCTSkip(
                "Set SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST=1 to exercise the "
                    + "locally installed on-device model."
            )
        }
        let fixture = try ModelRepairFixture(name: "real-on-device-model")
        defer { fixture.directory.remove() }
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

        let proposal: ModelRepairProposal
        let returnedStatus: FoundationModelProviderStatus
        do {
            (proposal, returnedStatus) = try provider.propose(
                for: fixture.context,
                options: options,
                cancellation: { false }
            )
        } catch let error as FoundationModelRepairError {
            if case .generationFailed = error {
                throw XCTSkip(error.localizedDescription)
            }
            throw error
        }

        XCTAssertEqual(returnedStatus.availability, .available)
        XCTAssertFalse(proposal.conciseRationale.contains("```"))
        XCTAssertTrue(proposal.requiresReview)
        XCTAssertFalse(
            proposal.edits.isEmpty,
            "The focused synthetic incompatibility must produce a source draft."
        )
        let draft = try FoundationModelRepairDraftBuilder.build(
            proposal: proposal,
            context: fixture.context,
            status: returnedStatus
        )
        XCTAssertNotNil(draft)
    }

    func testRealOnDeviceProviderProducesStructuralSDKRenameWhenExplicitlyEnabled()
        throws
    {
        guard ProcessInfo.processInfo.environment[
            "SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST"
        ] == "1" else {
            throw XCTSkip(
                "Set SWIFTDELTA_RUN_ON_DEVICE_MODEL_TEST=1 to exercise the "
                    + "locally installed on-device model."
            )
        }
        let source = """
        @MainActor
        func configure(_ controller: FictionalController) {
            controller.showsVerticalIndicator = true
            controller.showsHorizontalIndicator = true
        }
        """
        let fixture = try ModelRepairFixture(
            name: "real-on-device-structural-rename",
            source: source + "\n"
        )
        defer { fixture.directory.remove() }
        let identity = fixture.context.toolchains.candidate
        let context = RepairContext(
            relatedFindingIdentifier: "finding.structural",
            findingStableKey: "finding.structural|Sources/App.swift|3|5",
            findingSeverity: .warning,
            userSelected: true,
            evidenceLevel: .sdkRisk,
            diagnostic: nil,
            diagnosticIdentifier: nil,
            filePath: fixture.context.filePath,
            language: .swift,
            sourceFragment: source,
            enclosingDeclaration: source,
            allowedEditingRange: fixture.context.allowedEditingRange,
            sourceFingerprint: fixture.context.sourceFingerprint,
            resolvedSymbolIdentity: "usr.fictional.vertical",
            candidateSymbolIdentity: "usr.fictional.visible",
            baselineSDKDeclaration:
                "var showsVerticalIndicator: Bool { get set }",
            candidateSDKDeclaration:
                "var visibleIndicators: FictionalController.Configuration.Axis { get set }",
            sdkDifferences: [
                "SDK API renamed to configuration.visibleIndicators.",
                "Related exact SDK rename in the same source declaration: FictionalKit.FictionalController.showsHorizontalIndicator — var showsHorizontalIndicator: Bool { get set } renamed to configuration.visibleIndicators; candidate declaration: var visibleIndicators: FictionalController.Configuration.Axis { get set }",
                "Candidate destination path declaration: FictionalController.configuration — var configuration: FictionalController.Configuration { get }",
                "Related candidate SDK declaration: FictionalController.Configuration.Axis.both — static let both: FictionalController.Configuration.Axis",
                "Related candidate SDK declaration: FictionalController.Configuration.Axis.vertical — static let vertical: FictionalController.Configuration.Axis",
                "Related candidate SDK declaration: FictionalController.Configuration.Axis.horizontal — static let horizontal: FictionalController.Configuration.Axis",
            ],
            compilerFixItEvidence: [],
            deterministicRepairCandidates: [],
            restrictions: [
                "Edit only the supplied range.",
                "The exact source token showsVerticalIndicator is the migration target. Any concrete revised source must remove that token at the supplied occurrence and access the SDK rename destination configuration.visibleIndicators. Return notRepairable instead of preserving the old token or merely reformatting the declaration.",
                "The renamed value type changed from Bool to FictionalController.Configuration.Axis. Do not assign or return the old value type at the new destination. Use only the related candidate value or member declarations supplied by the SDK evidence.",
            ],
            toolchains: RepairToolchainEvidence(
                baseline: identity,
                candidate: identity
            ),
            symbols: RepairSymbolEvidence(
                baselinePreciseIdentifier: "usr.fictional.vertical",
                candidatePreciseIdentifier: "usr.fictional.visible",
                moduleName: "FictionalKit",
                baselineDeclaration:
                    "var showsVerticalIndicator: Bool { get set }",
                candidateDeclaration:
                    "var visibleIndicators: FictionalController.Configuration.Axis { get set }"
            ),
            compilerContext: fixture.context.compilerContext
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
        let proposal = try provider.propose(
            for: context,
            options: options,
            cancellation: { false }
        ).0
        print(
            "STRUCTURAL_MODEL disposition=\(proposal.disposition.rawValue) "
                + "explanation=\(proposal.explanation) edits="
                + proposal.edits.map {
                    "\($0.operation.rawValue):\($0.originalAnchor)->\($0.source)"
                }.joined(separator: " | ")
        )
        XCTAssertFalse(proposal.edits.isEmpty)
        let replacement = proposal.edits.map(\.source).joined(separator: "\n")
        XCTAssertTrue(replacement.contains("configuration.visibleIndicators"))
        XCTAssertFalse(replacement.contains("showsVerticalIndicator"))
        XCTAssertTrue(replacement.contains(".both"))
        XCTAssertFalse(replacement.contains("visibleIndicators = true"))
    }

    func testPromptSelectionUsesSeparateHostGenerations() throws {
        XCTAssertEqual(
            FoundationModelPromptDefinition.select(
                for: OperatingSystemVersion(
                    majorVersion: 26,
                    minorVersion: 3,
                    patchVersion: 0
                )
            )?.generation,
            .macOS26_0To26_3
        )
        XCTAssertEqual(
            FoundationModelPromptDefinition.select(
                for: OperatingSystemVersion(
                    majorVersion: 26,
                    minorVersion: 4,
                    patchVersion: 0
                )
            )?.generation,
            .macOS26_4
        )
        XCTAssertEqual(
            FoundationModelPromptDefinition.select(
                for: OperatingSystemVersion(
                    majorVersion: 27,
                    minorVersion: 0,
                    patchVersion: 0
                )
            )?.generation,
            .macOS27
        )
    }

    func testProviderFailureIsNotDescribedAsStructuredOutput() {
        let message = FoundationModelRepairError.generationFailed(
            "the local model service is not ready"
        ).localizedDescription

        XCTAssertTrue(message.contains("could not generate"))
        XCTAssertTrue(message.contains("finding remains unchanged"))
        XCTAssertFalse(message.contains("structured output"))
    }

    func testReasoningDefaultsToDeepOnlyForCapableMacOS27Model() throws {
        XCTAssertEqual(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS27,
                supportsReasoning: true,
                requested: nil
            ),
            "deep"
        )
        XCTAssertEqual(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS27,
                supportsReasoning: true,
                requested: .moderate
            ),
            "moderate"
        )
        XCTAssertEqual(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS27,
                supportsReasoning: true,
                requested: .light
            ),
            "light"
        )
        XCTAssertEqual(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS26_4,
                supportsReasoning: false,
                requested: nil
            ),
            "unsupported"
        )
        XCTAssertThrowsError(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS27,
                supportsReasoning: false,
                requested: .deep
            )
        )
        XCTAssertThrowsError(
            try FoundationModelReasoningResolver.resolve(
                generation: .macOS26_0To26_3,
                supportsReasoning: false,
                requested: .light
            )
        )
    }

    func testUnavailableModelLeavesSourceAndDeterministicPlanUntouched() throws {
        let fixture = try ModelRepairFixture(name: "model-unavailable")
        defer { fixture.directory.remove() }
        let provider = FakeFoundationModelProvider(
            status: FoundationModelProviderStatus(
                availability: .appleIntelligenceDisabled,
                generation: .macOS27,
                reasoningLevel: "unsupported",
                supportsTokenCounting: false
            ),
            proposal: .success(fixture.proposal)
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertTrue(result.0.isEmpty)
        XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: fixture.file, encoding: .utf8),
            fixture.source
        )
    }

    func testEveryAvailabilityFailureLeavesTheFindingUnchanged() throws {
        let fixture = try ModelRepairFixture(name: "model-availability")
        defer { fixture.directory.remove() }
        let states: [FoundationModelAvailabilityState] = [
            .unsupportedOperatingSystem,
            .unsupportedHardware,
            .appleIntelligenceDisabled,
            .modelNotReady,
            .unsupportedLanguageOrLocale,
            .unsupportedCapability("guided generation"),
        ]

        for state in states {
            let provider = FakeFoundationModelProvider(
                status: FoundationModelProviderStatus(
                    availability: state,
                    generation: .macOS27,
                    reasoningLevel: "unsupported",
                    supportsTokenCounting: false
                ),
                proposal: .success(fixture.proposal)
            )
            let result = FoundationModelRepairPlanner(
                provider: provider,
                progress: .silent
            ).proposeRepairs(
                contexts: [fixture.context],
                options: FoundationModelRepairOptions(),
                projectRoot: fixture.directory.url,
                cancellation: { false }
            )
            XCTAssertTrue(result.0.isEmpty)
            XCTAssertTrue(result.1.isEmpty)
        }
        XCTAssertEqual(
            try String(contentsOf: fixture.file, encoding: .utf8),
            fixture.source
        )
    }

    func testValidOnDeviceProposalHasVisibleTerminalAndJSONProvenance() throws {
        let fixture = try ModelRepairFixture(name: "model-provenance")
        defer { fixture.directory.remove() }
        let repair = try fixture.validatedRepair()
        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: [repair],
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let terminal = String(
            decoding: try RepairPlanRenderer.render(plan, format: .diff),
            as: UTF8.self
        )
        XCTAssertTrue(terminal.contains("Repair source: Apple Foundation Models"))
        XCTAssertTrue(terminal.contains("Execution: On-device"))
        XCTAssertTrue(terminal.contains("Host model generation: macOS 27"))
        XCTAssertTrue(terminal.contains("Reasoning level: deep"))
        XCTAssertTrue(terminal.contains("Review required: yes"))
        XCTAssertTrue(terminal.contains(
            "Generated by Apple Foundation Models. Review and build verification are required."
        ))
        XCTAssertTrue(terminal.contains("+func run() { newCall() }"))

        let json = String(
            decoding: try RepairPlanJSON.encode(plan),
            as: UTF8.self
        )
        XCTAssertTrue(json.contains(#""generatedBy" : "Apple Foundation Models""#))
        XCTAssertTrue(json.contains(#""provider" : "on-device""#))
        XCTAssertTrue(json.contains(#""modelGenerated" : true"#))
        XCTAssertTrue(json.contains(#""requiresReview" : true"#))
        XCTAssertTrue(json.contains(#""repairPlanFormatVersion" : "3.0""#))
    }

    func testFoundationModelsProvenanceIsAlwaysLocalOnDevice() throws {
        let fixture = try ModelRepairFixture(name: "model-local-only")
        defer { fixture.directory.remove() }
        let status = FoundationModelProviderStatus(
            availability: .available,
            generation: .macOS27,
            reasoningLevel: "moderate",
            supportsTokenCounting: false
        )
        let repair = try XCTUnwrap(
            FoundationModelProposalValidator.validate(
                fixture.proposal,
                context: fixture.context,
                status: status,
                projectRoot: fixture.directory.url
            ).first
        )

        XCTAssertEqual(repair.provider, "on-device")
        XCTAssertEqual(repair.execution, "On-device")
        XCTAssertEqual(repair.reasoningLevel, "moderate")
    }

    func testDeterministicRepairIsNotLabeledAsFoundationModelsOutput() throws {
        let directory = try TestDirectory(name: "deterministic-label")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let oldName = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "oldName",
            replacement: "newName",
            identifier: "repair.deterministic"
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: [repair]
        )
        let output = String(
            decoding: try RepairPlanRenderer.render(plan, format: .diff),
            as: UTF8.self
        )

        XCTAssertNil(repair.modelGenerated)
        XCTAssertFalse(output.contains("Apple Foundation Models"))
    }

    func testCanRepairFalseProducesNoRepair() throws {
        let fixture = try ModelRepairFixture(name: "model-reject")
        defer { fixture.directory.remove() }
        let provider = FakeFoundationModelProvider(
            status: fixture.status,
            proposal: .success(
                ModelRepairProposal(
                    disposition: .notRepairable,
                    sourceFileIdentity: fixture.context.filePath,
                    originalFragment: "",
                    proposedReplacement: "",
                    explanation: "Evidence is insufficient.",
                    confidence: .low,
                    evidenceUsed: [],
                    assumptions: [],
                    unresolvedRisks: ["No exact replacement identity."]
                )
            )
        )
        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertTrue(result.0.isEmpty)
        XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(
            result.notRepairableReasons[fixture.context.findingStableKey],
            "Evidence is insufficient."
        )
    }

    func testCandidateBudgetDeduplicatesPrioritizesAndReportsEveryOutcome()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-candidate-budget")
        defer { fixture.directory.remove() }
        let provider = RecordingFoundationModelProvider(
            status: fixture.status
        )
        let ordinary = fixture.planningContext(
            identifier: "ordinary",
            severity: .notice,
            userSelected: false,
            evidenceLevel: .sdkRisk,
            offset: 0
        )
        let preferredDuplicate = fixture.planningContext(
            identifier: "preferred",
            severity: .error,
            userSelected: true,
            evidenceLevel: .diagnosticBacked,
            offset: 0
        )
        let error = fixture.planningContext(
            identifier: "error",
            severity: .error,
            userSelected: false,
            evidenceLevel: .diagnosticBacked,
            offset: 2
        )
        let warning = fixture.planningContext(
            identifier: "warning",
            severity: .warning,
            userSelected: false,
            evidenceLevel: .diagnosticBacked,
            offset: 3
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [ordinary, warning, error, preferredDuplicate],
            options: FoundationModelRepairOptions(maximumCandidates: 2),
            projectRoot: fixture.directory.url,
            findingsConsidered: 5,
            initiallySkipped: 1,
            cancellation: { false }
        )

        XCTAssertEqual(provider.relatedFindingIdentifiers, [
            "preferred", "error",
        ])
        XCTAssertEqual(result.summary.findingsConsidered, 5)
        XCTAssertEqual(result.summary.processed, 2)
        XCTAssertEqual(result.summary.skipped, 1)
        XCTAssertEqual(result.summary.deduplicated, 1)
        XCTAssertEqual(result.summary.deferredByLimit, 1)
        XCTAssertEqual(result.summary.rejected, 2)
        XCTAssertEqual(result.summary.convertedIntoRepairs, 0)
        XCTAssertEqual(result.summary.timedOut, 0)
        XCTAssertEqual(result.summary.cancelled, 0)
    }

    func testCandidateLimitDefaultsToTwentyFiveAndNeverExceedsOneHundred() {
        XCTAssertEqual(
            FoundationModelRepairOptions().maximumCandidates,
            25
        )
        XCTAssertEqual(
            FoundationModelRepairOptions(
                maximumCandidates: 1_000
            ).maximumCandidates,
            100
        )
        XCTAssertEqual(
            FoundationModelRepairOptions(
                maximumCandidates: 0
            ).maximumCandidates,
            1
        )
    }

    func testSDKOnlyEligibilityRejectsUnresolvedAndUnusedButAcceptsExactLine()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-sdk-eligibility")
        defer { fixture.directory.remove() }

        let unresolved = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(
                includeCandidateDiagnostic: false,
                resolutionMethod: .uncertainText
            ),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )
        XCTAssertTrue(unresolved.contexts.isEmpty)
        XCTAssertEqual(unresolved.skipped, 1)

        let unanchored = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(
                includeCandidateDiagnostic: false,
                locationColumn: nil
            ),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )
        XCTAssertEqual(unanchored.contexts.count, 1)
        XCTAssertEqual(unanchored.skipped, 0)
        XCTAssertEqual(
            unanchored.contexts.first?.evidenceLevel,
            .sdkRisk
        )

        let output = fixture.sdkOutput(includeCandidateDiagnostic: false)
        let unused = SDKAnalysisOutput(
            findings: [],
            failures: output.failures,
            baselineSnapshots: output.baselineSnapshots,
            candidateSnapshots: output.candidateSnapshots,
            baselineIdentities: output.baselineIdentities,
            candidateIdentities: output.candidateIdentities,
            references: output.references,
            referenceResolutionCoverage:
                output.referenceResolutionCoverage,
            baselineBuildContexts: output.baselineBuildContexts,
            candidateBuildContexts: output.candidateBuildContexts,
            candidateDiagnostics: output.candidateDiagnostics,
            moduleSelections: output.moduleSelections,
            isComplete: output.isComplete
        )
        let unusedResult =
            FoundationModelRepairContextBuilder.buildWithFailures(
                sdkOutput: unused,
                deterministicRepairs: [],
                compilerFixIts: [],
                projectRoot: fixture.directory.url
            )
        XCTAssertTrue(unusedResult.contexts.isEmpty)
        XCTAssertEqual(unusedResult.findingsConsidered, 0)
    }

    func testGeneratedAndDependencySourcesAreNotSentToTheModel() throws {
        for (index, path) in [
            ".build/Generated.swift",
            "SourcePackages/checkouts/Fictional/Sources/App.swift",
        ].enumerated() {
            let fixture = try ModelRepairFixture(
                name: "model-protected-source-\(index)"
            )
            defer { fixture.directory.remove() }
            let protectedFile = try fixture.directory.write(
                path,
                fixture.source
            )
            let result =
                FoundationModelRepairContextBuilder.buildWithFailures(
                    sdkOutput: fixture.sdkOutput(
                        includeCandidateDiagnostic: false,
                        sourceFileOverride: protectedFile
                    ),
                    deterministicRepairs: [],
                    compilerFixIts: [],
                    projectRoot: fixture.directory.url
                )
            XCTAssertTrue(result.contexts.isEmpty, path)
            XCTAssertEqual(result.skipped, 1, path)
        }
    }

    func testRepairContextReportsUnreadableSourceInsteadOfSilentSkip() throws {
        let fixture = try ModelRepairFixture(name: "model-missing-source")
        defer { fixture.directory.remove() }
        let output = fixture.sdkOutput(includeCandidateDiagnostic: false)
        try FileManager.default.removeItem(at: fixture.file)

        let result = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: output,
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )

        XCTAssertTrue(result.contexts.isEmpty)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures[0].kind, .fileRead)
        XCTAssertEqual(result.failures[0].location?.path, fixture.file.path)
        XCTAssertTrue(result.failures[0].message.contains("could not read"))
    }

    func testContextAllowsExactSDKEvidenceAndPrefersCandidateDiagnostic()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-context-evidence")
        defer { fixture.directory.remove() }

        let withoutDiagnostic = FoundationModelRepairContextBuilder.build(
            sdkOutput: fixture.sdkOutput(includeCandidateDiagnostic: false),
            deterministicRepairs: [],
            projectRoot: fixture.directory.url
        )
        XCTAssertEqual(withoutDiagnostic.count, 1)
        XCTAssertNil(withoutDiagnostic[0].diagnostic)
        XCTAssertNil(withoutDiagnostic[0].diagnosticIdentifier)
        XCTAssertEqual(withoutDiagnostic[0].evidenceLevel, .sdkRisk)

        let withDiagnosticResult =
            FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(includeCandidateDiagnostic: true),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url,
            selectedFindingIdentifiers: ["finding.synthetic"]
        )
        let withDiagnostic = withDiagnosticResult.contexts
        XCTAssertEqual(withDiagnostic.count, 1)
        XCTAssertEqual(withDiagnostic[0].diagnosticIdentifier, "diag.synthetic")
        XCTAssertEqual(
            withDiagnostic[0].evidenceLevel,
            .diagnosticBacked
        )
        XCTAssertTrue(withDiagnostic[0].userSelected)

        let deterministic = try makeRepair(
            document: fixture.document,
            original: "oldCall",
            replacement: "newCall",
            identifier: "repair.compiler"
        )
        let afterDeterministicRepair = FoundationModelRepairContextBuilder.build(
            sdkOutput: fixture.sdkOutput(includeCandidateDiagnostic: true),
            deterministicRepairs: [deterministic],
            projectRoot: fixture.directory.url
        )
        XCTAssertTrue(afterDeterministicRepair.isEmpty)
    }

    func testInformationalMetadataWithoutCompilerEvidenceNeedsNoModelEdit()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-informational-metadata"
        )
        defer { fixture.directory.remove() }
        let result = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(
                includeCandidateDiagnostic: false,
                changeKind: .concurrencyChanged,
                severity: .notice
            ),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )

        XCTAssertTrue(result.contexts.isEmpty)
        XCTAssertEqual(result.skipped, 1)
        XCTAssertTrue(
            result.skipReasons.values.first?.contains(
                "No source change is required"
            ) == true
        )
    }

    func testSDKRiskProposalRequiresReviewAndTargetedVerification() throws {
        let fixture = try ModelRepairFixture(name: "model-sdk-risk")
        defer { fixture.directory.remove() }
        let context = try XCTUnwrap(
            FoundationModelRepairContextBuilder.build(
                sdkOutput: fixture.sdkOutput(
                    includeCandidateDiagnostic: false
                ),
                deterministicRepairs: [],
                projectRoot: fixture.directory.url
            ).first
        )
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: context.filePath,
            originalFragment: "oldCall",
            proposedReplacement: "newCall",
            explanation: "The exact candidate SDK identity supplies this name.",
            confidence: .high,
            evidenceUsed: [context.candidateSymbolIdentity],
            assumptions: [],
            unresolvedRisks: []
        )
        let repair = try XCTUnwrap(
            FoundationModelProposalValidator.validate(
                proposal,
                context: context,
                status: fixture.status,
                projectRoot: fixture.directory.url
            ).first
        )

        XCTAssertEqual(repair.safety, .reviewRequired)
        XCTAssertTrue(repair.isExplicitlyApplicable)
        XCTAssertTrue(
            repair.explanation.contains(
                "No unique candidate compiler diagnostic"
            )
        )

        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: [repair]
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: [
                    context.relatedFindingIdentifier,
                ],
                buildContextIdentity: "candidate"
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: [],
                buildContextIdentity: "candidate"
            ),
        ])
        _ = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: [repair],
            projectRoot: fixture.directory.url,
            verifier: verifier
        )
        XCTAssertTrue(
            try String(contentsOf: fixture.file, encoding: .utf8)
                .contains("newCall")
        )
    }

    func testContextDoesNotBindAmbiguousDiagnosticAndCarriesRepairEvidence()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-context-identity")
        defer { fixture.directory.remove() }
        let ambiguousOutput = fixture.sdkOutput(
            includeCandidateDiagnostic: true,
            additionalDiagnostics: [
                CompilerDiagnostic(
                    message: "a second diagnostic at the same expression",
                    severity: .warning,
                    location: fixture.context.diagnostic?.location,
                    target: "SyntheticTarget",
                    diagnosticID: "diag.second"
                ),
            ]
        )
        let ambiguous = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: ambiguousOutput,
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )
        XCTAssertEqual(ambiguous.contexts.count, 1)
        XCTAssertNil(ambiguous.contexts[0].diagnostic)
        XCTAssertEqual(ambiguous.contexts[0].evidenceLevel, .sdkRisk)
        XCTAssertTrue(ambiguous.failures.isEmpty)

        let candidate = try makeRepair(
            document: fixture.document,
            original: "oldCall",
            replacement: "newCall",
            identifier: "repair.review",
            safety: .reviewRequired
        )
        let fixIt = StructuredDiagnosticFixIt(
            filePath: fixture.file.path,
            sourceRange: candidate.sourceRange,
            replacementText: "newCall",
            diagnosticText: "synthetic candidate diagnostic",
            diagnosticSeverity: .error,
            diagnosticIndex: 0,
            fixItIndex: 0,
            compilerContext: nil
        )
        let populated = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(includeCandidateDiagnostic: true),
            deterministicRepairs: [candidate],
            compilerFixIts: [fixIt],
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(populated.contexts.count, 1)
        XCTAssertFalse(
            populated.contexts[0].compilerFixItEvidence.isEmpty
        )
        XCTAssertFalse(
            populated.contexts[0].deterministicRepairCandidates.isEmpty
        )
        XCTAssertEqual(
            populated.contexts[0].sourceFragment,
            "func run() { oldCall() }"
        )
    }

    func testContextAcceptsUniqueQualifiedSDKReferenceWithoutCompilerUSR()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-qualified-context"
        )
        defer { fixture.directory.remove() }
        let result = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(
                includeCandidateDiagnostic: false,
                resolutionMethod: .compilerQualifiedDeclaration,
                preciseIdentifier: nil
            ),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(result.contexts.count, 1)
        XCTAssertEqual(result.skipped, 0)
        XCTAssertEqual(
            result.contexts.first?.resolvedSymbolIdentity,
            "usr.old"
        )
        XCTAssertEqual(
            result.contexts.first?.evidenceLevel,
            .sdkRisk
        )
    }

    func testRenameContextUsesSDKDestinationInsteadOfDeprecatedDeclaration()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-rename-destination")
        defer { fixture.directory.remove() }
        let result = FoundationModelRepairContextBuilder.buildWithFailures(
            sdkOutput: fixture.sdkOutput(
                includeCandidateDiagnostic: false,
                changeKind: .renamed,
                renameDestination: "Container.newCall()"
            ),
            deterministicRepairs: [],
            compilerFixIts: [],
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(result.contexts.count, 1)
        XCTAssertEqual(
            result.contexts.first?.candidateSymbolIdentity,
            "usr.new"
        )
        XCTAssertEqual(
            result.contexts.first?.candidateSDKDeclaration,
            "func newCall()"
        )
    }

    func testStructuredProposalRoundTrip() throws {
        let fixture = try ModelRepairFixture(name: "model-structured")
        defer { fixture.directory.remove() }
        let data = try JSONEncoder().encode(fixture.proposal)
        let decoded = try JSONDecoder().decode(
            ModelRepairProposal.self,
            from: data
        )
        XCTAssertEqual(decoded, fixture.proposal)
    }

    func testIncompleteStructuredProposalCannotDecode() throws {
        let data = Data(
            """
            {
              "disposition": "repairable",
              "sourceFileIdentity": "Sources/App.swift",
              "originalFragment": "oldCall"
            }
            """.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ModelRepairProposal.self, from: data)
        )
    }

    func testRecoverableGenerationFailureRetriesOnce() throws {
        let fixture = try ModelRepairFixture(name: "model-retry")
        defer { fixture.directory.remove() }
        let provider = SequencedFoundationModelProvider(
            status: fixture.status,
            results: [
                .failure(
                    .invalidStructuredOutput("incomplete guided response")
                ),
                .success(fixture.proposal),
            ]
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertEqual(provider.attemptCount, 2)
        XCTAssertEqual(result.0.count, 1)
        XCTAssertTrue(result.1.isEmpty)
    }

    func testNoEditResponseReceivesOneFocusedCorrectiveRetry() throws {
        let fixture = try ModelRepairFixture(name: "model-missing-edit-retry")
        defer { fixture.directory.remove() }
        let incomplete = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [],
            explanation: "The SDK evidence requires a migration.",
            confidence: .medium,
            evidenceUsed: [],
            assumptions: [],
            unresolvedRisks: ["The exact edit still needs to be supplied."]
        )
        let provider = SequencedFoundationModelProvider(
            status: fixture.status,
            results: [
                .success(incomplete),
                .success(fixture.proposal),
            ]
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertEqual(provider.attemptCount, 2)
        XCTAssertEqual(result.repairs.count, 1)
        XCTAssertEqual(result.candidateAttempts.count, 1)
        XCTAssertEqual(result.candidateAttempts[0].status, .noProposal)
        XCTAssertEqual(
            result.candidateAttempts[0].validationStage,
            RepairDraftIssueStage.incompleteDraft.rawValue
        )
    }

    func testInvalidSourceAnchorReceivesOneFocusedCorrectiveRetry() throws {
        let fixture = try ModelRepairFixture(name: "model-anchor-retry")
        defer { fixture.directory.remove() }
        let invalid = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "func oldCall()",
                    source: "func newCall()"
                ),
            ],
            explanation: "The candidate declaration supplies the new name.",
            confidence: .medium,
            evidenceUsed: [],
            assumptions: [],
            unresolvedRisks: []
        )
        let provider = SequencedFoundationModelProvider(
            status: fixture.status,
            results: [
                .success(invalid),
                .success(fixture.proposal),
            ]
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertEqual(provider.attemptCount, 2)
        XCTAssertEqual(result.repairs.count, 1)
        XCTAssertEqual(result.drafts.count, 2)
        XCTAssertTrue(
            result.candidateAttempts.contains {
                $0.risks.contains {
                    $0.contains("source anchor does not match")
                }
            }
        )
    }

    func testGenerationRetriesAtMostTwice() throws {
        let fixture = try ModelRepairFixture(name: "model-retry-bound")
        defer { fixture.directory.remove() }
        let provider = SequencedFoundationModelProvider(
            status: fixture.status,
            results: [
                .failure(.generationFailed("first")),
                .failure(.generationFailed("second")),
                .failure(.generationFailed("third")),
                .success(fixture.proposal),
            ]
        )

        let result = FoundationModelRepairPlanner(
            provider: provider,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertEqual(provider.attemptCount, 3)
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertEqual(result.1.count, 1)
        XCTAssertTrue(result.1[0].message.contains("could not generate"))
    }

    func testReturnedSourceFileIdentityMustMatchContext() throws {
        let fixture = try ModelRepairFixture(name: "model-file-identity")
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: "Sources/Other.swift",
            originalFragment: fixture.proposal.originalFragment,
            proposedReplacement: fixture.proposal.proposedReplacement,
            explanation: fixture.proposal.explanation,
            confidence: .high,
            evidenceUsed: fixture.proposal.evidenceUsed,
            assumptions: [],
            unresolvedRisks: []
        )

        XCTAssertThrowsError(try fixture.validate(proposal: proposal)) {
            XCTAssertTrue(
                $0.localizedDescription.contains("source file identity")
            )
        }
    }

    func testReviewRequiredProposalRemainsViewableButNotApplicable() throws {
        let fixture = try ModelRepairFixture(name: "model-review-only")
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            originalFragment: fixture.proposal.originalFragment,
            proposedReplacement: fixture.proposal.proposedReplacement,
            explanation: fixture.proposal.explanation,
            confidence: .medium,
            evidenceUsed: fixture.proposal.evidenceUsed,
            assumptions: ["The call site may depend on overload selection."],
            unresolvedRisks: ["Overload behavior requires human review."]
        )
        let repair = try XCTUnwrap(
            fixture.validate(proposal: proposal)
        )

        XCTAssertEqual(repair.safety, .suggestionOnly)
        XCTAssertFalse(repair.isExplicitlyApplicable)
        XCTAssertTrue(repair.explanation.contains("Unresolved risks"))
    }

    func testInvalidAmbiguousOutOfRangeAndInventedEditsAreRejected() throws {
        let fixture = try ModelRepairFixture(
            name: "model-invalid",
            source: "func run() { oldCall(); oldCall() }\n"
        )
        defer { fixture.directory.remove() }
        XCTAssertThrowsError(
            try fixture.validate(
                proposal: fixture.proposal
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("ambiguous"))
        }

        let missing = fixture.proposal(
            original: "missingCall",
            replacement: "newCall"
        )
        XCTAssertThrowsError(try fixture.validate(proposal: missing))

        let uniqueFixture = try ModelRepairFixture(name: "model-invented")
        defer { uniqueFixture.directory.remove() }
        let invented = uniqueFixture.proposal(
            original: "oldCall",
            replacement: "inventedCall"
        )
        XCTAssertThrowsError(
            try uniqueFixture.validate(proposal: invented)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains(
                "absent from the supplied source, compiler, and candidate SDK evidence"
            ))
        }

        let invalidContext = fixture.context(
            allowedRange: RepairSourceRange(
                start: RepairSourcePosition(
                    line: 1,
                    column: 1,
                    utf8Offset: 500
                ),
                end: RepairSourcePosition(
                    line: 1,
                    column: 2,
                    utf8Offset: 501
                )
            )
        )
        XCTAssertThrowsError(
            try FoundationModelProposalValidator.validate(
                fixture.proposal,
                context: invalidContext,
                status: fixture.status,
                projectRoot: fixture.directory.url
            )
        )
    }

    func testStructuredValidatorAcceptsMultilineAndExpressionShapeReplacement() throws {
        let fixture = try ModelRepairFixture(
            name: "model-multiline",
            source: "func run() {\n    oldCall()\n}\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall()",
                    source: "if true {\n        newCall()\n    }"
                ),
            ],
            explanation: "Use the candidate declaration in a bounded statement.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: []
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 1)
        XCTAssertTrue(repairs[0].replacementText.contains("\n"))
        XCTAssertEqual(repairs[0].safety, .reviewRequired)
    }

    func testStructuredValidatorIgnoresIdentifiersInsideSwiftLiterals()
        throws
    {
        let fixture = try ModelRepairFixture(name: "model-string-literal")
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall()",
                    source: #"newCall("fresh migration note")"#
                ),
            ],
            explanation: "Use the candidate declaration with a literal value.",
            confidence: .medium,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: ["Candidate build verification is required."]
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 1)
        XCTAssertTrue(repairs[0].replacementText.contains("fresh migration note"))
    }

    func testStructuredValidatorAcceptsInsertionDeletionAndCoordinatedEdits() throws {
        let fixture = try ModelRepairFixture(
            name: "model-coordinated",
            source: "func run() { oldCall(label: 1) }\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .insertBefore,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "{",
                    source: "async "
                ),
                ModelRepairEdit(
                    operation: .delete,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "label: 1",
                    source: ""
                ),
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall",
                    source: "newCall"
                ),
            ],
            explanation: "Apply the coordinated signature migration.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: []
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 3)
        XCTAssertEqual(repairs.filter { $0.originalText.isEmpty }.count, 1)
        XCTAssertEqual(repairs.filter { $0.replacementText.isEmpty }.count, 1)
        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: repairs
        )
        XCTAssertTrue(plan.conflicts.isEmpty)
    }

    func testCoordinatedModelEditsApplyOnlyAfterSuccessfulVerification() throws {
        let fixture = try ModelRepairFixture(
            name: "model-coordinated-apply",
            source: "func run() { oldCall(label: 1) }\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .delete,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "label: 1",
                    source: ""
                ),
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall",
                    source: "newCall"
                ),
            ],
            explanation: "Apply the candidate signature migration.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: []
        )
        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )
        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: repairs
        )
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: ["finding.synthetic"],
                buildContextIdentity: "candidate"
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: [],
                buildContextIdentity: "candidate"
            ),
        ])

        let result = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: repairs,
            projectRoot: fixture.directory.url,
            verifier: verifier
        )

        XCTAssertEqual(result.appliedRepairIdentifiers.count, 2)
        XCTAssertEqual(
            try String(contentsOf: fixture.file, encoding: .utf8),
            "func run() { newCall() }\n"
        )
    }

    func testPlannerRetainsExactFindingAssociationForEveryCoordinatedEdit()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-coordinated-association",
            source: "func run() { oldCall(label: 1) }\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .delete,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "label: 1",
                    source: ""
                ),
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall",
                    source: "newCall"
                ),
            ],
            explanation: "Apply the candidate signature migration.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: []
        )
        let result = FoundationModelRepairPlanner(
            provider: FakeFoundationModelProvider(
                status: fixture.status,
                proposal: .success(proposal)
            ),
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertEqual(result.repairs.count, 2)
        XCTAssertEqual(result.repairFindingStableKeys.count, 2)
        XCTAssertTrue(result.repairs.allSatisfy {
            result.repairFindingStableKeys[$0.repairIdentifier]
                == fixture.context.findingStableKey
        })
    }

    func testStructuredValidatorAcceptsAvailabilityAndConcurrencySyntax() throws {
        let fixture = try ModelRepairFixture(
            name: "model-availability",
            source: "func run() {\n    oldCall()\n}\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall()",
                    source:
                        "if #available(iOS 27, *) {\n"
                        + "        await newCall()\n"
                        + "    }"
                ),
            ],
            explanation: "Review the availability and asynchronous migration.",
            confidence: .medium,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: ["The enclosing task permits suspension."],
            unresolvedRisks: ["The fallback behavior requires review."]
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 1)
        XCTAssertEqual(repairs[0].safety, .suggestionOnly)
        XCTAssertTrue(repairs[0].requiresReview == true)
    }

    func testStructuredValidatorKeepsNativeEditsBoundedForCandidateCompiler()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-native",
            source: "void run(void) { oldCall(1); }\n",
            relativePath: "Sources/App.c"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .c,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall",
                    source: "newCall"
                ),
                ModelRepairEdit(
                    operation: .delete,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "1",
                    source: ""
                ),
            ],
            explanation:
                "The native edit remains subject to the target-aware Clang build.",
            confidence: .medium,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: ["The candidate declaration accepts no argument."],
            unresolvedRisks: ["Native semantic verification is required."]
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 2)
        XCTAssertTrue(repairs.allSatisfy { $0.language == .c })
        XCTAssertTrue(repairs.allSatisfy {
            $0.verificationRequirement == .candidateBuild
        })
    }

    func testNativeStructuralValidationIgnoresCommentDelimitersAndWords()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-native-comments",
            source: "void run(void) { oldCall(); }\n",
            relativePath: "Sources/App.c"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .c,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall()",
                    source: "newCall() /* unmatched } migration note */"
                ),
            ],
            explanation: "Use the candidate native declaration.",
            confidence: .medium,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: ["Candidate Clang verification is required."]
        )

        let repairs = try FoundationModelProposalValidator.validate(
            proposal,
            context: fixture.context,
            status: fixture.status,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(repairs.count, 1)
    }

    func testStructuredValidatorRejectsOverlappingOperations() throws {
        let fixture = try ModelRepairFixture(name: "model-edit-overlap")
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall",
                    source: "newCall"
                ),
                ModelRepairEdit(
                    operation: .delete,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall()",
                    source: ""
                ),
            ],
            explanation: "Invalid overlapping proposal.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: []
        )

        XCTAssertThrowsError(
            try FoundationModelProposalValidator.validate(
                proposal,
                context: fixture.context,
                status: fixture.status,
                projectRoot: fixture.directory.url
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("overlapping"))
        }
    }

    func testStaleFingerprintIsRejected() throws {
        let fixture = try ModelRepairFixture(name: "model-stale")
        defer { fixture.directory.remove() }
        try Data((fixture.source + "\n").utf8).write(to: fixture.file)

        XCTAssertThrowsError(
            try fixture.validate(proposal: fixture.proposal)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("stale"))
        }
    }

    func testContextSizeTimeoutAndCancellationRemainNonRepairingFailures() throws {
        let fixture = try ModelRepairFixture(name: "model-operational")
        defer { fixture.directory.remove() }
        let oversized = FakeFoundationModelProvider(
            status: FoundationModelProviderStatus(
                availability: .available,
                generation: .macOS26_4,
                reasoningLevel: "unsupported",
                supportsTokenCounting: true
            ),
            budget: FoundationModelContextBudget(
                tokenCount: 4_096,
                contextSize: 4_096
            ),
            proposal: .success(fixture.proposal)
        )
        let oversizedResult = FoundationModelRepairPlanner(
            provider: oversized,
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )
        XCTAssertTrue(oversizedResult.0.isEmpty)
        XCTAssertTrue(oversizedResult.1[0].message.contains("exceeds"))
        XCTAssertEqual(oversizedResult.summary.rejected, 1)

        for (error, timedOut, cancelled) in [
            (FoundationModelRepairError.timedOut(2), 1, 0),
            (FoundationModelRepairError.cancelled, 0, 1),
        ] {
            let provider = FakeFoundationModelProvider(
                status: fixture.status,
                proposal: .failure(error)
            )
            let result = FoundationModelRepairPlanner(
                provider: provider,
                progress: .silent
            ).proposeRepairs(
                contexts: [fixture.context],
                options: FoundationModelRepairOptions(),
                projectRoot: fixture.directory.url,
                cancellation: { false }
            )
            XCTAssertTrue(result.0.isEmpty)
            XCTAssertEqual(result.1.count, 1)
            XCTAssertEqual(result.summary.timedOut, timedOut)
            XCTAssertEqual(result.summary.cancelled, cancelled)
        }

        let deadlineResult = FoundationModelRepairPlanner(
            provider: FakeFoundationModelProvider(
                status: fixture.status,
                proposal: .success(fixture.proposal)
            ),
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(timeout: 0),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )
        XCTAssertEqual(deadlineResult.summary.processed, 0)
        XCTAssertEqual(deadlineResult.summary.timedOut, 1)
        XCTAssertTrue(
            deadlineResult.failures[0].message.contains("timeout")
        )
    }

    func testOverlappingGeneratedRepairsAreNotAccepted() throws {
        let fixture = try ModelRepairFixture(name: "model-overlap")
        defer { fixture.directory.remove() }
        let repair = try fixture.validatedRepair()
        let duplicate = ProposedRepair(
            repairIdentifier: "repair.model.duplicate",
            relatedFindingIdentifier: "finding.other",
            evidenceSource: .foundationModels,
            language: repair.language,
            filePath: repair.filePath,
            sourceRange: repair.sourceRange,
            originalText: repair.originalText,
            replacementText: "newCall",
            fileFingerprint: repair.fileFingerprint,
            confidence: .low,
            safety: .reviewRequired,
            explanation: repair.explanation,
            verificationRequirement: .candidateBuild,
            generatedBy: "Apple Foundation Models",
            provider: "on-device",
            execution: "On-device",
            hostModelGeneration: "macOS 27",
            reasoningLevel: "deep",
            modelGenerated: true,
            requiresReview: true
        )
        XCTAssertFalse(
            RepairPlanBuilder.conflicts(in: [repair, duplicate]).isEmpty
        )
    }

    func testPreviewDoesNotModifyAndExplicitVerifiedApplySucceeds() throws {
        let fixture = try ModelRepairFixture(name: "model-apply")
        defer { fixture.directory.remove() }
        let repair = try fixture.validatedRepair()
        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: [repair]
        )
        _ = try RepairPlanRenderer.render(plan, format: .diff)
        XCTAssertEqual(
            try String(contentsOf: fixture.file, encoding: .utf8),
            fixture.source
        )

        let diagnostic = try XCTUnwrap(fixture.context.diagnostic)
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [diagnostic],
                offeredFindingIdentifiers: [
                    fixture.context.relatedFindingIdentifier,
                ],
                buildContextIdentity: "candidate"
            ),
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [],
                offeredFindingIdentifiers: [],
                buildContextIdentity: "candidate"
            ),
        ])
        _ = try RepairApplicationService().apply(
            plan: plan,
            selectedRepairs: [repair],
            projectRoot: fixture.directory.url,
            verifier: verifier
        )
        XCTAssertTrue(
            try String(contentsOf: fixture.file, encoding: .utf8)
                .contains("newCall")
        )
    }

    func testVerificationFailureRollsBackGeneratedRepair() throws {
        let fixture = try ModelRepairFixture(name: "model-rollback")
        defer { fixture.directory.remove() }
        let repair = try fixture.validatedRepair()
        let plan = RepairPlanBuilder.build(
            projectRoot: fixture.directory.url,
            repairs: [repair]
        )
        let diagnostic = try XCTUnwrap(fixture.context.diagnostic)
        let verifier = SequenceRepairVerifier([
            RepairVerificationSnapshot(
                buildSucceeded: true,
                diagnostics: [diagnostic],
                offeredFindingIdentifiers: [
                    fixture.context.relatedFindingIdentifier,
                ],
                buildContextIdentity: "candidate"
            ),
            RepairVerificationSnapshot(
                buildSucceeded: false,
                diagnostics: [
                    CompilerDiagnostic(
                        message: "synthetic new error",
                        severity: .error
                    ),
                ],
                offeredFindingIdentifiers: [],
                buildContextIdentity: "candidate"
            ),
        ])

        XCTAssertThrowsError(
            try RepairApplicationService().apply(
                plan: plan,
                selectedRepairs: [repair],
                projectRoot: fixture.directory.url,
                verifier: verifier
            )
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.file, encoding: .utf8),
            fixture.source
        )
    }

    func testRejectedStructuredProposalRemainsInspectable() throws {
        let fixture = try ModelRepairFixture(
            name: "model-retained-rejection",
            source: "func run() { oldCall(); oldCall() }\n"
        )
        defer { fixture.directory.remove() }
        let result = FoundationModelRepairPlanner(
            provider: FakeFoundationModelProvider(
                status: fixture.status,
                proposal: .success(fixture.proposal)
            ),
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )

        XCTAssertTrue(result.repairs.isEmpty)
        XCTAssertEqual(result.candidateAttempts.count, 1)
        let candidate = try XCTUnwrap(result.candidateAttempts.first)
        XCTAssertEqual(candidate.status, .needsValidation)
        XCTAssertNotNil(candidate.draftIdentifier)
        XCTAssertEqual(result.drafts.count, 1)
        XCTAssertEqual(candidate.repairSource, "Apple Foundation Models")
        XCTAssertEqual(candidate.edits.count, 1)
        XCTAssertEqual(candidate.edits[0].originalText, "oldCall")
        XCTAssertTrue(
            candidate.verificationMessage?.contains("ambiguous") == true
        )
    }

    func testRetainedDraftCanBeEditedAndNormalizedIntoExactRepairs() throws {
        let fixture = try ModelRepairFixture(
            name: "model-editable-draft",
            source: "func run() { oldCall(); oldCall() }\n"
        )
        defer { fixture.directory.remove() }
        let result = FoundationModelRepairPlanner(
            provider: FakeFoundationModelProvider(
                status: fixture.status,
                proposal: .success(fixture.proposal)
            ),
            progress: .silent
        ).proposeRepairs(
            contexts: [fixture.context],
            options: FoundationModelRepairOptions(),
            projectRoot: fixture.directory.url,
            cancellation: { false }
        )
        let draft = try XCTUnwrap(result.drafts.first)
        let edited = draft.replacingEdits([
            RepairDraftEdit(
                operation: .replace,
                sourceFileIdentity: draft.sourceFile,
                originalAnchor: "oldCall(); oldCall()",
                proposedSource: "newCall(); oldCall()"
            ),
        ])

        let normalized = try RepairDraftNormalizer.normalize(
            edited,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].originalText, "oldCall(); oldCall()")
        XCTAssertEqual(normalized[0].replacementText, "newCall(); oldCall()")
        XCTAssertEqual(normalized[0].safety, .suggestionOnly)
        XCTAssertFalse(normalized[0].isExplicitlyApplicable)
        XCTAssertEqual(
            normalized[0].evidenceSource,
            .foundationModels
        )
    }

    func testDraftNormalizerReanchorsUniqueWhitespaceAndTokenEquivalentSource()
        throws
    {
        let fixture = try ModelRepairFixture(
            name: "model-token-reanchoring",
            source:
                """
                func run() {
                    oldCall(value: 1)
                }
                """
                + "\n"
        )
        defer { fixture.directory.remove() }
        let proposal = ModelRepairProposal(
            disposition: .reviewRequired,
            sourceFileIdentity: fixture.context.filePath,
            sourceLanguage: .swift,
            edits: [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: fixture.context.filePath,
                    originalAnchor: "oldCall( value: 1 )",
                    source: "newCall(value: 1)"
                ),
            ],
            explanation: "Use the candidate declaration.",
            confidence: .medium,
            evidenceUsed: [],
            assumptions: [],
            unresolvedRisks: []
        )
        let draft = try XCTUnwrap(
            FoundationModelRepairDraftBuilder.build(
                proposal: proposal,
                context: fixture.context,
                status: fixture.status
            )
        )

        let normalized = try RepairDraftNormalizer.normalize(
            draft,
            projectRoot: fixture.directory.url
        )

        XCTAssertEqual(normalized.count, 1)
        XCTAssertEqual(normalized[0].originalText, "oldCall(value: 1)")
        XCTAssertEqual(normalized[0].replacementText, "newCall(value: 1)")
    }
}

private struct FakeFoundationModelProvider: FoundationModelRepairProviding {
    let modelStatus: FoundationModelProviderStatus
    let budget: FoundationModelContextBudget?
    let proposalResult:
        Result<ModelRepairProposal, FoundationModelRepairError>

    init(
        status: FoundationModelProviderStatus,
        budget: FoundationModelContextBudget? = nil,
        proposal: Result<
            ModelRepairProposal,
            FoundationModelRepairError
        >
    ) {
        modelStatus = status
        self.budget = budget
        proposalResult = proposal
    }

    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus {
        modelStatus
    }

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget? {
        budget
    }

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        (try proposalResult.get(), modelStatus)
    }
}

private final class SequencedFoundationModelProvider:
    FoundationModelRepairProviding,
    @unchecked Sendable
{
    private let modelStatus: FoundationModelProviderStatus
    private let lock = NSLock()
    private var results:
        [Result<ModelRepairProposal, FoundationModelRepairError>]
    private var attempts = 0

    init(
        status: FoundationModelProviderStatus,
        results: [Result<
            ModelRepairProposal,
            FoundationModelRepairError
        >]
    ) {
        modelStatus = status
        self.results = results
    }

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus {
        modelStatus
    }

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget? {
        nil
    }

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        let result: Result<
            ModelRepairProposal,
            FoundationModelRepairError
        >
        lock.lock()
        attempts += 1
        result = results.isEmpty
            ? .failure(.generationFailed("no queued response"))
            : results.removeFirst()
        lock.unlock()
        return (try result.get(), modelStatus)
    }
}

private final class RecordingFoundationModelProvider:
    FoundationModelRepairProviding,
    @unchecked Sendable
{
    private let modelStatus: FoundationModelProviderStatus
    private let lock = NSLock()
    private var identifiers: [String] = []

    init(status: FoundationModelProviderStatus) {
        modelStatus = status
    }

    var relatedFindingIdentifiers: [String] {
        lock.lock()
        defer { lock.unlock() }
        return identifiers
    }

    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus {
        modelStatus
    }

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget? {
        nil
    }

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        lock.lock()
        identifiers.append(context.relatedFindingIdentifier)
        lock.unlock()
        return (
            ModelRepairProposal(
                disposition: .notRepairable,
                sourceFileIdentity: context.filePath,
                originalFragment: "",
                proposedReplacement: "",
                explanation: "No exact edit was established.",
                confidence: .low,
                evidenceUsed: [],
                assumptions: [],
                unresolvedRisks: ["Review is required."]
            ),
            modelStatus
        )
    }
}

private struct ModelRepairFixture {
    let directory: TestDirectory
    let file: URL
    let source: String
    let document: RepairSourceDocument
    let context: RepairContext
    let proposal: ModelRepairProposal
    let status: FoundationModelProviderStatus

    init(
        name: String,
        source: String = "func run() { oldCall() }\n",
        relativePath: String = "Sources/App.swift"
    ) throws {
        directory = try TestDirectory(name: name)
        self.source = source
        file = try directory.write(relativePath, source)
        document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        let range = RepairSourceRange(
            start: sourcePosition(0, in: document.data),
            end: sourcePosition(
                source.utf8.count - (source.hasSuffix("\n") ? 1 : 0),
                in: document.data
            )
        )
        let diagnostic = CompilerDiagnostic(
            message: "synthetic candidate diagnostic",
            severity: .error,
            location: SourceLocation(
                path: file.path,
                line: 1,
                column: 14
            ),
            diagnosticID: "diag.synthetic"
        )
        let identity = makeSDKIdentity(
            xcode: "27",
            build: "27A",
            sdk: "27",
            path: "/Synthetic/Xcode.app"
        )
        context = RepairContext(
            relatedFindingIdentifier: "finding.synthetic",
            findingStableKey:
                "finding.synthetic|\(relativePath)|1|14|SyntheticTarget|",
            findingSeverity: .error,
            userSelected: false,
            evidenceLevel: .diagnosticBacked,
            diagnostic: diagnostic,
            diagnosticIdentifier: "diag.synthetic",
            filePath: relativePath,
            language: document.language,
            sourceFragment: String(source.dropLast()),
            enclosingDeclaration: String(source.dropLast()),
            allowedEditingRange: range,
            sourceFingerprint: document.fingerprint,
            resolvedSymbolIdentity: "usr.old",
            candidateSymbolIdentity: "usr.new",
            baselineSDKDeclaration: "func oldCall()",
            candidateSDKDeclaration: "func newCall()",
            sdkDifferences: ["The declaration changed."],
            compilerFixItEvidence: [
                "Exact structured fix-it: replace oldCall with newCall.",
            ],
            deterministicRepairCandidates: [
                "compiler fix-it safe: oldCall -> newCall",
            ],
            restrictions: ["Edit only the supplied range."],
            toolchains: RepairToolchainEvidence(
                baseline: identity,
                candidate: identity
            ),
            symbols: RepairSymbolEvidence(
                baselinePreciseIdentifier: "usr.old",
                candidatePreciseIdentifier: "usr.new",
                moduleName: "FictionalSDK",
                baselineDeclaration: "func oldCall()",
                candidateDeclaration: "func newCall()"
            ),
            compilerContext: RepairCompilerContextEvidence(
                compilerPath: "/Synthetic/swiftc",
                target: "SyntheticTarget",
                moduleName: "SyntheticTarget",
                sdkIdentifier: "macosx",
                sdkPath: "/Synthetic/SDK",
                diagnosticIdentity: "diag.synthetic",
                evidenceArtifact: "targetAwareCompilerDiagnostic",
                isTargetAware: true
            )
        )
        proposal = ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: context.filePath,
            originalFragment: "oldCall",
            proposedReplacement: "newCall",
            explanation:
                "The candidate declaration supplies the resolved replacement.",
            confidence: .high,
            evidenceUsed: ["usr.new", "diag.synthetic"],
            assumptions: [],
            unresolvedRisks: [],
            sourceLanguage: document.language
        )
        status = FoundationModelProviderStatus(
            availability: .available,
            generation: .macOS27,
            reasoningLevel: "deep",
            supportsTokenCounting: true
        )
    }

    func proposal(
        original: String,
        replacement: String
    ) -> ModelRepairProposal {
        ModelRepairProposal(
            disposition: .repairable,
            sourceFileIdentity: context.filePath,
            originalFragment: original,
            proposedReplacement: replacement,
            explanation: proposal.conciseRationale,
            confidence: .high,
            evidenceUsed: proposal.evidenceReferences,
            assumptions: [],
            unresolvedRisks: []
        )
    }

    func context(
        allowedRange: RepairSourceRange
    ) -> RepairContext {
        RepairContext(
            relatedFindingIdentifier: context.relatedFindingIdentifier,
            findingStableKey: context.findingStableKey,
            findingSeverity: context.findingSeverity,
            userSelected: context.userSelected,
            evidenceLevel: context.evidenceLevel,
            diagnostic: context.diagnostic,
            diagnosticIdentifier: context.diagnosticIdentifier,
            filePath: context.filePath,
            language: context.language,
            sourceFragment: context.sourceFragment,
            enclosingDeclaration: context.enclosingDeclaration,
            allowedEditingRange: allowedRange,
            sourceFingerprint: context.sourceFingerprint,
            resolvedSymbolIdentity: context.resolvedSymbolIdentity,
            candidateSymbolIdentity: context.candidateSymbolIdentity,
            baselineSDKDeclaration: context.baselineSDKDeclaration,
            candidateSDKDeclaration: context.candidateSDKDeclaration,
            sdkDifferences: context.sdkDifferences,
            compilerFixItEvidence: context.compilerFixItEvidence,
            deterministicRepairCandidates:
                context.deterministicRepairCandidates,
            restrictions: context.restrictions,
            toolchains: context.toolchains,
            symbols: context.symbols,
            compilerContext: context.compilerContext
        )
    }

    func planningContext(
        identifier: String,
        severity: Severity,
        userSelected: Bool,
        evidenceLevel: FoundationModelRepairEvidenceLevel,
        offset: Int
    ) -> RepairContext {
        let position = RepairSourcePosition(
            line: 1,
            column: offset + 1,
            utf8Offset: offset
        )
        return RepairContext(
            relatedFindingIdentifier: identifier,
            findingStableKey: "\(identifier)|\(context.filePath)|1|\(offset)",
            findingSeverity: severity,
            userSelected: userSelected,
            evidenceLevel: evidenceLevel,
            diagnostic: evidenceLevel == .diagnosticBacked
                ? context.diagnostic : nil,
            diagnosticIdentifier: evidenceLevel == .diagnosticBacked
                ? context.diagnosticIdentifier : nil,
            filePath: context.filePath,
            language: context.language,
            sourceFragment: context.sourceFragment,
            enclosingDeclaration: context.enclosingDeclaration,
            allowedEditingRange: RepairSourceRange(
                start: position,
                end: RepairSourcePosition(
                    line: 1,
                    column: offset + 2,
                    utf8Offset: offset + 1
                )
            ),
            sourceFingerprint: context.sourceFingerprint,
            resolvedSymbolIdentity: context.resolvedSymbolIdentity,
            candidateSymbolIdentity: context.candidateSymbolIdentity,
            baselineSDKDeclaration: context.baselineSDKDeclaration,
            candidateSDKDeclaration: context.candidateSDKDeclaration,
            sdkDifferences: context.sdkDifferences,
            compilerFixItEvidence: context.compilerFixItEvidence,
            deterministicRepairCandidates:
                context.deterministicRepairCandidates,
            restrictions: context.restrictions,
            toolchains: context.toolchains,
            symbols: context.symbols,
            compilerContext: context.compilerContext
        )
    }

    func validate(
        proposal: ModelRepairProposal
    ) throws -> ProposedRepair? {
        try FoundationModelProposalValidator.validate(
            proposal,
            context: context,
            status: status,
            projectRoot: directory.url
        ).first
    }

    func validatedRepair() throws -> ProposedRepair {
        try XCTUnwrap(validate(proposal: proposal))
    }

    func sdkOutput(
        includeCandidateDiagnostic: Bool,
        additionalDiagnostics: [CompilerDiagnostic] = [],
        resolutionMethod: SymbolResolutionMethod = .compilerUSR,
        preciseIdentifier: String? = "usr.old",
        locationColumn: Int? = 14,
        sourceFileOverride: URL? = nil,
        changeKind: SDKChangeKind = .signatureChanged,
        severity: Severity = .error,
        renameDestination: String? = nil
    ) -> SDKAnalysisOutput {
        let baselineIdentity = makeSDKIdentity(
            xcode: "26",
            build: "26A",
            sdk: "26",
            path: "/Synthetic/Baseline.app"
        )
        let candidateIdentity = makeSDKIdentity(
            xcode: "27",
            build: "27A",
            sdk: "27",
            path: "/Synthetic/Candidate.app"
        )
        let baselineSymbol = makeSDKSymbol(
            "usr.old",
            "Container.oldCall()",
            declaration: "func oldCall()",
            renamedDestination: renameDestination
        )
        let candidateSymbol = makeSDKSymbol(
            "usr.new",
            "Container.newCall()",
            declaration: "func newCall()"
        )
        let location = SourceLocation(
            path: (sourceFileOverride ?? file).path,
            line: 1,
            column: locationColumn
        )
        let evidence = SDKFindingEvidence(
            baseline: baselineIdentity,
            candidate: candidateIdentity,
            platform: "SyntheticOS",
            moduleName: "FictionalSDK",
            preciseIdentifier: preciseIdentifier,
            fullyQualifiedName: baselineSymbol.fullyQualifiedName,
            sourceLocation: location,
            changeKind: changeKind,
            observedChange: "The declaration changed.",
            oldDeclaration: baselineSymbol.declaration,
            newDeclaration: candidateSymbol.declaration,
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: resolutionMethod
        )
        let finding = Finding(
            findingID: "finding.synthetic",
            category: .sdk,
            title: "Synthetic SDK change",
            explanation: evidence.observedChange,
            severity: severity,
            confidence: .high,
            location: location,
            origin: .sdk,
            target: "SyntheticTarget",
            sdkEvidence: evidence
        )
        let context = TargetBuildContext(
            toolchainRole: "candidate",
            xcodeApplicationPath: candidateIdentity.xcodeApplicationPath,
            sdkIdentifier: candidateIdentity.sdkIdentifier,
            sdkPath: candidateIdentity.sdkPath,
            platform: candidateIdentity.platform,
            target: "SyntheticTarget",
            moduleName: "SyntheticTarget",
            architecture: "arm64",
            deploymentTarget: "1.0",
            sourceFiles: [(sourceFileOverride ?? file).path],
            compilerArguments: [],
            evidenceSource: .exactCompilerInvocation,
            isAuthoritative: true
        )
        let diagnostics: [CompilerDiagnostic] = (includeCandidateDiagnostic
            ? [
                CompilerDiagnostic(
                    message: "synthetic candidate diagnostic",
                    severity: .error,
                    location: location,
                    target: "SyntheticTarget",
                    diagnosticID: "diag.synthetic"
                ),
            ]
            : []) + additionalDiagnostics
        return SDKAnalysisOutput(
            findings: [finding],
            failures: [],
            baselineSnapshots: [
                SDKSnapshot(
                    identity: baselineIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [baselineSymbol]
                ),
            ],
            candidateSnapshots: [
                SDKSnapshot(
                    identity: candidateIdentity,
                    modules: ["FictionalSDK"],
                    symbols: [candidateSymbol]
                ),
            ],
            referenceResolutionCoverage: [],
            candidateBuildContexts: [context],
            candidateDiagnostics: diagnostics
        )
    }
}
