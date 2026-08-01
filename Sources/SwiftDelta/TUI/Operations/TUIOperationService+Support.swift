//===--- TUIOperationService+Support.swift - SwiftDelta ------------------------------------------===//
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

extension CoreTUIOperationService {
    func effectiveConfiguration(
        root: URL,
        workflow: TUIWorkflowSettings,
        forRepair: Bool = false
    ) throws -> SwiftDeltaConfiguration {
        let configURL = workflow.configurationPath.map {
            resolvePath($0, relativeTo: root)
        }
        let base = try ConfigurationLoader.load(
            projectRoot: root,
            explicitURL: configURL
        )
        return try base.applying(
            ConfigurationOverrides(
                workspace: workflow.workspacePath,
                project: workflow.projectPath,
                workspaceWasProvided: workflow.workspacePath != nil,
                projectWasProvided: workflow.projectPath != nil,
                scheme: workflow.scheme,
                baselineXcodePath: workflow.baselineXcodePath,
                candidateXcodePath: workflow.candidateXcodePath,
                sdkIdentifiers: workflow.sdkIdentifiers.isEmpty
                    ? nil : workflow.sdkIdentifiers,
                activeCompilationConditions:
                    workflow.activeCompilationConditions.isEmpty
                        ? nil : workflow.activeCompilationConditions,
                excludedPaths: workflow.excludedPaths.isEmpty
                    ? nil : workflow.excludedPaths,
                minimumSeverity: forRepair ? .notice : workflow.minimumSeverity,
                minimumConfidence: forRepair
                    ? .low
                    : (workflow.includeUncertain
                        ? .low : workflow.minimumConfidence),
                ciFailureLevel: workflow.failureLevel,
                outputFormat: workflow.reportFormat
            )
        )
    }

    func foundationModelOptions(
        _ workflow: TUIWorkflowSettings,
        status: OnDeviceFoundationModelStatus
    ) -> FoundationModelRepairOptions? {
        guard status.isAvailable else { return nil }
        return FoundationModelRepairOptions(
            reasoningLevel: status.reasoningLevel == "unsupported"
                ? nil : workflow.foundationModelReasoning,
            timeout: workflow.foundationModelTimeout,
            maximumCandidates:
                workflow.foundationModelCandidateLimit
                ?? FoundationModelRepairOptions.hardMaximumCandidates
        )
    }

    func validate(
        _ workflow: TUIWorkflowSettings,
        foundationModelStatus: OnDeviceFoundationModelStatus
    ) throws {
        guard workflow.timeout > 0 else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "timeout",
                reason: "the timeout must be greater than zero"
            )
        }
        guard workflow.doctorTimeout > 0 else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "doctor timeout",
                reason: "the timeout must be greater than zero"
            )
        }
        guard !foundationModelStatus.isAvailable
                || workflow.foundationModelTimeout > 0
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "Foundation Models timeout",
                reason: "the timeout must be greater than zero"
            )
        }
        if let limit = workflow.foundationModelCandidateLimit {
            guard (
                1...FoundationModelRepairOptions.hardMaximumCandidates
            ).contains(limit) else {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "Foundation Models candidate limit",
                    reason:
                        "the limit must be between 1 and "
                        + "\(FoundationModelRepairOptions.hardMaximumCandidates)"
                )
            }
        }
    }

    func canonicalRoot(_ path: String) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    func resolvePath(_ path: String, relativeTo root: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if NSString(string: expanded).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return root.appendingPathComponent(expanded).standardizedFileURL
    }

    func condensed(_ value: String?) -> String? {
        value?.split(whereSeparator: \.isNewline)
            .map(String.init)
            .joined(separator: " ")
    }
}

struct CancellableProcessRunner: ProcessRunning {
    let cancellation: @Sendable () -> Bool
    private let base = ProcessRunner()

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation nested: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        try base.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: { cancellation() || nested() }
        )
    }
}
