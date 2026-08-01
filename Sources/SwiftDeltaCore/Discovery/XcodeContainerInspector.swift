//===--- XcodeContainerInspector.swift - SwiftDelta ------------------------------------------===//
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

public struct XcodeContainerInspector: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func inspect(
        _ container: ProjectContainer,
        developerDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> ProjectDetails {
        guard container.kind == .project || container.kind == .workspace else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "container",
                reason: "xcodebuild listing requires a project or workspace"
            )
        }

        var arguments = ["-list", "-json"]
        if container.kind == .project {
            arguments.append(contentsOf: ["-project", container.path])
        } else {
            arguments.append(contentsOf: ["-workspace", container.path])
        }
        let result = try runner.run(
            executable: "/usr/bin/xcodebuild",
            arguments: arguments,
            environment: developerDirectory.map { ["DEVELOPER_DIR": $0] } ?? [:],
            workingDirectory: URL(fileURLWithPath: container.path).deletingLastPathComponent(),
            timeout: timeout,
            cancellation: { false }
        )
        guard result.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: "xcodebuild",
                status: result.exitStatus,
                message: result.safeErrorSummary
            )
        }

        do {
            let payload = try JSONDecoder().decode(XcodeListPayload.self, from: result.standardOutput)
            guard let listing = payload.project ?? payload.workspace else {
                throw SwiftDeltaError.processFailed(
                    executable: "xcodebuild",
                    status: result.exitStatus,
                    message: "the JSON listing did not contain project or workspace details"
                )
            }
            return ProjectDetails(
                container: container,
                schemes: listing.schemes ?? [],
                targets: listing.targets ?? [],
                configurations: listing.configurations ?? []
            )
        } catch let error as SwiftDeltaError {
            throw error
        } catch {
            throw SwiftDeltaError.processFailed(
                executable: "xcodebuild",
                status: result.exitStatus,
                message: "could not decode -list -json output: \(error.localizedDescription)"
            )
        }
    }
}

private struct XcodeListPayload: Decodable {
    let project: XcodeListEntry?
    let workspace: XcodeListEntry?
}

private struct XcodeListEntry: Decodable {
    let configurations: [String]?
    let schemes: [String]?
    let targets: [String]?
}
