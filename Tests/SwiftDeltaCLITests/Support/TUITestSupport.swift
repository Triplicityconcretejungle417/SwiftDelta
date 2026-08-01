//===--- TUITestSupport.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import CryptoKit
import Foundation
@testable import SwiftDelta
import SwiftDeltaCore
import XCTest

final class TUITestDirectory {
    let url: URL

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swiftdelta-tui-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        url = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

final class FakeTUIOperationService:
    TUIOperationServing,
    @unchecked Sendable
{
    enum Behavior {
        case result(TUIOperationResult)
        case failure(String)
        case waitForCancellation
    }

    private let lock = NSLock()
    private var behavior: Behavior
    private(set) var requestedKinds: [TUIOperationKind] = []
    private var requestedValues: [TUIOperationRequest] = []

    init(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func setBehavior(_ behavior: Behavior) {
        lock.withLock {
            self.behavior = behavior
        }
    }

    func perform(
        _ kind: TUIOperationKind,
        request: TUIOperationRequest,
        cancellation: @escaping @Sendable () -> Bool,
        pauseRequested: @escaping @Sendable () -> Bool,
        progress: @escaping @Sendable (TUIOperationProgressUpdate) -> Void
    ) throws -> TUIOperationResult {
        let selected = lock.withLock {
            requestedKinds.append(kind)
            requestedValues.append(request)
            return behavior
        }
        progress(.message("[00:00] Starting synthetic operation\n"))
        progress(
            .measurement(
                OperationProgressMeasurement(
                    completed: 1,
                    total: 3,
                    label: "Synthetic stages"
                )
            )
        )
        switch selected {
        case let .result(result):
            _ = request
            return result
        case let .failure(message):
            throw LaunchError(message)
        case .waitForCancellation:
            while !cancellation() {
                _ = pauseRequested()
                Thread.sleep(forTimeInterval: 0.005)
            }
            throw LaunchError("cancelled")
        }
    }

    func kinds() -> [TUIOperationKind] {
        lock.withLock { requestedKinds }
    }

    func requests() -> [TUIOperationRequest] {
        lock.withLock { requestedValues }
    }
}

final class TUITestClock: @unchecked Sendable {
    // A controlled monotonic clock avoids timing-sensitive animation assertions.
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval = 0) {
        self.value = value
    }

    func now() -> TimeInterval {
        lock.withLock { value }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

func makeTUIController(
    screen: TUIScreen = .project,
    report: AnalysisReport? = nil,
    repairPlan: RepairPlan? = nil,
    service: FakeTUIOperationService,
    directory: TUITestDirectory,
    clock: TUITestClock? = nil,
    foundationModelStatusProvider:
        @escaping @Sendable () -> OnDeviceFoundationModelStatus = {
            .unavailable
        }
) -> TUIController {
    var settings = TUISettings()
    settings.workflow.projectRoot = directory.url.path
    settings.workflow.baselineXcodePath = "/Synthetic/Baseline.app"
    settings.workflow.candidateXcodePath = "/Synthetic/Candidate.app"
    var state = TUIState(
        settings: settings,
        history: TUIHistory(),
        safeMode: true
    )
    state.screen = screen
    state.projectWasExplicitlySelected = true
    state.selectedContainer = ProjectContainer(
        kind: .project,
        path: directory.url.appendingPathComponent(
            "Synthetic.xcodeproj"
        ).path
    )
    state.settings.workflow.scheme = "Synthetic"
    state.settings.workflow.buildConfiguration = "Debug"
    state.settings.workflow.sdkIdentifiers = ["macosx"]
    state.settings.workflow.destination = "platform=macOS"
    state.setupOrigins = [
        .baselineXcode: .saved,
        .candidateXcode: .saved,
        .sdk: .saved,
        .destination: .saved,
    ]
    state.report = report
    state.repairPlan = repairPlan
    let time: @Sendable () -> TimeInterval
    if let clock {
        time = { clock.now() }
    } else {
        time = { ProcessInfo.processInfo.systemUptime }
    }
    return TUIController(
        state: state,
        settingsStore: TUISettingsStore(
            applicationSupportDirectory:
                directory.url.appendingPathComponent("Application Support")
        ),
        coordinator: TUIOperationCoordinator(service: service),
        monotonicTime: time,
        foundationModelStatusProvider: foundationModelStatusProvider
    )
}

func waitForOperations(
    _ controller: TUIController,
    timeout: TimeInterval = 2
) {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        controller.consumeOperationEvents()
        if case .running = controller.state.operationStatus {
            Thread.sleep(forTimeInterval: 0.005)
        } else if case .idle = controller.state.operationStatus {
            Thread.sleep(forTimeInterval: 0.005)
        } else {
            return
        }
    } while Date() < deadline
}

func syntheticReport(
    findings: [Finding] = [],
    state: AnalysisResultState? = nil
) -> AnalysisReport {
    AnalysisReport(
        generatedAt: Date(timeIntervalSince1970: 1_000),
        projectRoot: "/tmp/SyntheticProject",
        analysisState: state,
        findings: findings
    )
}

func syntheticFinding(
    identifier: String,
    title: String,
    severity: Severity,
    path: String = "Sources/App.swift",
    module: String = "FictionalKit"
) -> Finding {
    let baseline = SDKInstallationIdentity(
        xcodeApplicationPath: "/Synthetic/Baseline.app",
        developerDirectory: "/Synthetic/Baseline.app/Contents/Developer",
        xcodeVersion: "1",
        xcodeBuild: "1A1",
        platform: "macOS",
        sdkIdentifier: "macosx",
        sdkVersion: "1",
        sdkPath: "/Synthetic/MacOSX1.sdk"
    )
    let candidate = SDKInstallationIdentity(
        xcodeApplicationPath: "/Synthetic/Candidate.app",
        developerDirectory: "/Synthetic/Candidate.app/Contents/Developer",
        xcodeVersion: "2",
        xcodeBuild: "2A1",
        platform: "macOS",
        sdkIdentifier: "macosx",
        sdkVersion: "2",
        sdkPath: "/Synthetic/MacOSX2.sdk"
    )
    let location = SourceLocation(path: path, line: 4, column: 8)
    return Finding(
        findingID: identifier,
        category: .sdk,
        title: title,
        explanation: "Synthetic evidence for \(title).",
        severity: severity,
        confidence: .high,
        location: location,
        origin: .sdk,
        automaticRemediationSupported: false,
        sdkEvidence: SDKFindingEvidence(
            baseline: baseline,
            candidate: candidate,
            platform: "macOS",
            moduleName: module,
            preciseIdentifier: "s:\(identifier)",
            fullyQualifiedName: "\(module).\(title)",
            sourceLocation: location,
            changeKind: .signatureChanged,
            observedChange: "Synthetic signature changed.",
            oldDeclaration: "func oldValue()",
            newDeclaration: "func newValue()",
            oldAvailability: [],
            newAvailability: [],
            migrationMessage: nil,
            resolutionMethod: .compilerUSR
        )
    )
}

func syntheticRepair(
    identifier: String? = nil,
    modelGenerated: Bool = false,
    replacementText: String = "new"
) -> ProposedRepair {
    let source = Data("old\n".utf8)
    let digest = SHA256.hash(data: source)
        .map { String(format: "%02x", $0) }
        .joined()
    return ProposedRepair(
        repairIdentifier: identifier
            ?? (modelGenerated ? "repair.model" : "repair.compiler"),
        relatedFindingIdentifier: "finding.one",
        evidenceSource: modelGenerated ? .foundationModels : .swiftCompilerFixIt,
        language: .swift,
        filePath: "Sources/App.swift",
        sourceRange: RepairSourceRange(
            start: RepairSourcePosition(line: 1, column: 1, utf8Offset: 0),
            end: RepairSourcePosition(line: 1, column: 4, utf8Offset: 3)
        ),
        originalText: "old",
        replacementText: replacementText,
        fileFingerprint: RepairFileFingerprint(
            digest: digest,
            byteCount: source.count
        ),
        confidence: .high,
        safety: modelGenerated ? .reviewRequired : .safe,
        explanation: "Exact synthetic replacement.",
        verificationRequirement: .candidateBuild,
        generatedBy: modelGenerated ? "Apple Foundation Models" : nil,
        provider: modelGenerated ? "on-device" : nil,
        execution: modelGenerated ? "On-device" : nil,
        hostModelGeneration: modelGenerated ? "macOS 27" : nil,
        reasoningLevel: modelGenerated ? "deep" : nil,
        modelGenerated: modelGenerated ? true : nil,
        requiresReview: modelGenerated ? true : nil
    )
}

func syntheticRepairDraft(
    source: Data = Data("old\n".utf8)
) -> RepairDraft {
    let digest = SHA256.hash(data: source)
        .map { String(format: "%02x", $0) }
        .joined()
    let identity = SDKInstallationIdentity(
        xcodeApplicationPath: "/Synthetic/Candidate.app",
        developerDirectory:
            "/Synthetic/Candidate.app/Contents/Developer",
        xcodeVersion: "27",
        xcodeBuild: "27A1",
        platform: "macOS",
        sdkIdentifier: "macosx",
        sdkVersion: "27",
        sdkPath: "/Synthetic/MacOSX27.sdk"
    )
    return RepairDraft(
        draftIdentifier: "draft.model.one",
        findingStableKey: "finding.one|Sources/App.swift|1",
        findingIdentifier: "finding.one",
        findingTitle: "Synthetic model draft",
        findingSeverity: .error,
        sourceFile: "Sources/App.swift",
        sourceLanguage: .swift,
        location: SourceLocation(
            path: "Sources/App.swift",
            line: 1,
            column: 1
        ),
        symbol: "usr.old",
        edits: [
            RepairDraftEdit(
                operation: .replace,
                sourceFileIdentity: "Sources/App.swift",
                originalAnchor: "ol",
                proposedSource: "new"
            ),
        ],
        explanation: "Replace the candidate-incompatible expression.",
        evidence: ["usr.old", "usr.new"],
        assumptions: [],
        risks: [],
        initialIssues: [
            RepairDraftIssue(
                stage: .sourceAnchor,
                message: "The original source anchor needs correction."
            ),
        ],
        sourceFragment: "old\n",
        enclosingDeclaration: "old\n",
        allowedEditingRange: RepairSourceRange(
            start: RepairSourcePosition(
                line: 1,
                column: 1,
                utf8Offset: 0
            ),
            end: RepairSourcePosition(
                line: 2,
                column: 1,
                utf8Offset: source.count
            )
        ),
        sourceFingerprint: RepairFileFingerprint(
            digest: digest,
            byteCount: source.count
        ),
        diagnostic: nil,
        diagnosticIdentifier: nil,
        evidenceLevelIsDiagnosticBacked: false,
        resolvedSymbolIdentity: "usr.old",
        candidateSymbolIdentity: "usr.new",
        baselineSDKDeclaration: "func old()",
        candidateSDKDeclaration: "func new()",
        sdkDifferences: ["The SDK declaration changed."],
        compilerFixItEvidence: [],
        deterministicRepairCandidates: [],
        toolchains: RepairToolchainEvidence(
            baseline: identity,
            candidate: identity
        ),
        symbols: RepairSymbolEvidence(
            baselinePreciseIdentifier: "usr.old",
            candidatePreciseIdentifier: "usr.new",
            moduleName: "FictionalSDK",
            baselineDeclaration: "func old()",
            candidateDeclaration: "func new()"
        ),
        compilerContext: RepairCompilerContextEvidence(
            compilerPath: "/Synthetic/swiftc",
            target: "Synthetic",
            moduleName: "Synthetic",
            sdkIdentifier: "macosx",
            sdkPath: identity.sdkPath,
            diagnosticIdentity: "sdk.finding.one",
            evidenceArtifact: "targetAwareSDKReference",
            isTargetAware: true
        ),
        modelIdentity: "Apple Foundation Models",
        hostModelGeneration: "macOS 27",
        reasoningLevel: "deep",
        confidence: .medium
    )
}
