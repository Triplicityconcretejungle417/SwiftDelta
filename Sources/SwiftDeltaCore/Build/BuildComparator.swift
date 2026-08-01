//===--- BuildComparator.swift - SwiftDelta ------------------------------------------===//
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

public struct BuildComparisonResult: Sendable {
    public let oldBuild: BuildOutcome
    public let newBuild: BuildOutcome
    public let introducedDiagnostics: [CompilerDiagnostic]
    public let buildSettingDifferences: [BuildSettingDifference]
    public let findings: [Finding]

    public init(
        oldBuild: BuildOutcome,
        newBuild: BuildOutcome,
        introducedDiagnostics: [CompilerDiagnostic],
        buildSettingDifferences: [BuildSettingDifference],
        findings: [Finding]
    ) {
        self.oldBuild = oldBuild
        self.newBuild = newBuild
        self.introducedDiagnostics = introducedDiagnostics
        self.buildSettingDifferences = buildSettingDifferences
        self.findings = findings
    }
}

public struct BuildComparator: Sendable {
    private let builder: any ProjectBuilding
    private let settingsAnalyzer: BuildSettingsAnalyzer
    private let progress: OperationProgress

    public init(
        builder: any ProjectBuilding = XcodeProjectBuilder(),
        settingsAnalyzer: BuildSettingsAnalyzer = BuildSettingsAnalyzer()
    ) {
        self.builder = builder
        self.settingsAnalyzer = settingsAnalyzer
        self.progress = .silent
    }

    public init(
        settingsAnalyzer: BuildSettingsAnalyzer = BuildSettingsAnalyzer(),
        progress: OperationProgress
    ) {
        self.builder = XcodeProjectBuilder(progress: progress)
        self.settingsAnalyzer = settingsAnalyzer
        self.progress = progress
    }

    public func compare(
        old oldInvocation: BuildInvocation,
        new newInvocation: BuildInvocation,
        staticFindings: [Finding] = [],
        targetVersion: String? = nil,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> BuildComparisonResult {
        _ = try XcodeInstallation.validate(applicationPath: oldInvocation.xcodePath)
        _ = try XcodeInstallation.validate(applicationPath: newInvocation.xcodePath)

        let oldBuild = try progress.phase(
            "Building baseline with \(oldInvocation.xcodePath)",
            completedMessage: "Finished baseline build"
        ) {
            progress.measure(
                completed: 0,
                total: 2,
                label: "Toolchain builds"
            )
            return try builder.build(
                oldInvocation,
                cancellation: cancellation
            )
        }
        progress.measure(
            completed: 1,
            total: 2,
            label: "Toolchain builds"
        )
        guard oldBuild.succeeded else {
            throw SwiftDeltaError.buildFailed(
                xcode: oldInvocation.xcodePath,
                status: oldBuild.exitStatus,
                diagnostics: oldBuild.diagnostics
            )
        }
        let newBuild = try progress.phase(
            "Building candidate with \(newInvocation.xcodePath)",
            completedMessage: "Finished candidate build"
        ) {
            progress.measure(
                completed: 1,
                total: 2,
                label: "Toolchain builds"
            )
            return try builder.build(
                newInvocation,
                cancellation: cancellation
            )
        }
        progress.measure(
            completed: 2,
            total: 2,
            label: "Toolchain builds"
        )
        if !newBuild.succeeded,
           newBuild.diagnostics.contains(where: BuildFailureClassifier.isEnvironmentFailure)
        {
            throw SwiftDeltaError.buildFailed(
                xcode: newInvocation.xcodePath,
                status: newBuild.exitStatus,
                diagnostics: newBuild.diagnostics
            )
        }
        let introduced = progress.phase(
            "Comparing compiler diagnostics",
            completedMessage: "Compared compiler diagnostics"
        ) {
            DiagnosticComparator.introduced(
                old: oldBuild.diagnostics,
                new: newBuild.diagnostics
            )
        }
        let differences = settingsAnalyzer.differences(
            old: oldBuild.buildSettings,
            new: newBuild.buildSettings,
            selectedSDKIdentifiers: Array(
                Set(oldInvocation.sdkIdentifiers + newInvocation.sdkIdentifiers)
            ).sorted()
        )
        let effectiveTargetVersion = targetVersion
            ?? URL(fileURLWithPath: newInvocation.xcodePath)
                .deletingPathExtension()
                .lastPathComponent
        let compilerFindings = CompilerFindingAdapter.findings(
            from: introduced,
            targetVersion: effectiveTargetVersion
        )
        let settingFindings = settingsAnalyzer.findings(
            for: differences,
            targetXcodeVersion: effectiveTargetVersion
        )

        return BuildComparisonResult(
            oldBuild: oldBuild,
            newBuild: newBuild,
            introducedDiagnostics: introduced,
            buildSettingDifferences: differences,
            findings: FindingMerger.merge(staticFindings + compilerFindings + settingFindings)
        )
    }
}
