//===--- ProjectDiscovery.swift - SwiftDelta ------------------------------------------===//
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

public struct ProjectDiscovery: Sendable {
    public static let defaultExcludedDirectoryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        "DerivedData",
        "Pods",
        "Generated",
        "GeneratedSources",
    ]

    public init() {}

    private static let normalizedExcludedDirectoryNames = Set(
        defaultExcludedDirectoryNames.map { $0.lowercased() }
    )

    public func discover(
        root: URL,
        excludedPaths: [String] = []
    ) throws -> DiscoveryResult {
        let fileManager = FileManager.default
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SwiftDeltaError.invalidRoot(root.path)
        }

        let exclusions = try canonicalExclusions(excludedPaths, root: canonicalRoot)
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw SwiftDeltaError.invalidRoot(root.path)
        }

        var containers = Set<ProjectContainer>()
        var swiftFiles = Set<String>()

        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            let values: URLResourceValues
            do {
                values = try standardized.resourceValues(forKeys: Set(keys))
            } catch {
                continue
            }

            if isExcluded(standardized, root: canonicalRoot, exclusions: exclusions) {
                if values.isDirectory == true {
                    enumerator.skipDescendants()
                }
                continue
            }

            if values.isSymbolicLink == true {
                let resolved = standardized.resolvingSymlinksInPath()
                guard resolved.isContained(in: canonicalRoot) else {
                    if values.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values.isDirectory == true {
                    // Avoid cycles and duplicate traversal. In-root linked files are still accepted.
                    enumerator.skipDescendants()
                    continue
                }
            }

            let name = values.name ?? standardized.lastPathComponent
            if values.isDirectory == true {
                if Self.normalizedExcludedDirectoryNames.contains(
                    name.lowercased()
                ) {
                    enumerator.skipDescendants()
                    continue
                }
                if name.hasSuffix(".xcodeproj") {
                    containers.insert(ProjectContainer(kind: .project, path: standardized.path))
                    enumerator.skipDescendants()
                    continue
                }
                if name.hasSuffix(".xcworkspace") {
                    containers.insert(ProjectContainer(kind: .workspace, path: standardized.path))
                    enumerator.skipDescendants()
                    continue
                }
            } else if values.isRegularFile == true || values.isSymbolicLink == true {
                if name == "Package.swift" {
                    containers.insert(ProjectContainer(kind: .package, path: standardized.path))
                }
                if name.hasSuffix(".swift"),
                   name != "Package.swift",
                   !isGeneratedSource(standardized)
                {
                    swiftFiles.insert(standardized.path)
                }
            }
        }

        return DiscoveryResult(
            root: canonicalRoot.path,
            containers: containers.sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.path < $1.path
            },
            swiftFiles: swiftFiles.sorted()
        )
    }

    public func selectXcodeContainer(
        from discovery: DiscoveryResult,
        project: String? = nil,
        workspace: String? = nil
    ) throws -> ProjectContainer {
        if project != nil, workspace != nil {
            throw SwiftDeltaError.invalidConfiguration(
                field: "project/workspace",
                reason: "select either a project or a workspace, not both"
            )
        }

        let root = URL(fileURLWithPath: discovery.root, isDirectory: true)
        if let project {
            return try explicitContainer(
                path: project,
                expectedKind: .project,
                root: root
            )
        }
        if let workspace {
            return try explicitContainer(
                path: workspace,
                expectedKind: .workspace,
                root: root
            )
        }

        let choices = discovery.containers.filter {
            $0.kind == .project || $0.kind == .workspace
        }
        guard !choices.isEmpty else {
            throw SwiftDeltaError.missingSelection(
                "no .xcodeproj or .xcworkspace was found under \(discovery.root)"
            )
        }
        guard choices.count == 1 else {
            throw SwiftDeltaError.ambiguousSelection(
                kind: "Xcode project/workspace",
                choices: choices.map(\.path)
            )
        }
        return choices[0]
    }

    public func selectBuildContainer(
        from discovery: DiscoveryResult,
        project: String? = nil,
        workspace: String? = nil
    ) throws -> ProjectContainer {
        if project != nil || workspace != nil {
            return try selectXcodeContainer(
                from: discovery,
                project: project,
                workspace: workspace
            )
        }
        let xcodeContainers = discovery.containers.filter {
            $0.kind == .project || $0.kind == .workspace
        }
        if xcodeContainers.count == 1 {
            return xcodeContainers[0]
        }
        if xcodeContainers.count > 1 {
            throw SwiftDeltaError.ambiguousSelection(
                kind: "Xcode project/workspace",
                choices: xcodeContainers.map(\.path)
            )
        }
        let packages = discovery.containers.filter { $0.kind == .package }
        guard !packages.isEmpty else {
            throw SwiftDeltaError.missingSelection(
                "no .xcodeproj, .xcworkspace, or Package.swift was found under \(discovery.root)"
            )
        }
        guard packages.count == 1 else {
            throw SwiftDeltaError.ambiguousSelection(
                kind: "Swift package",
                choices: packages.map(\.path)
            )
        }
        return packages[0]
    }

    private func explicitContainer(
        path: String,
        expectedKind: ProjectContainerKind,
        root: URL
    ) throws -> ProjectContainer {
        let candidate: URL
        if NSString(string: path).isAbsolutePath {
            candidate = URL(fileURLWithPath: path)
        } else {
            candidate = root.appendingPathComponent(path)
        }
        let canonical = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard canonical.isContained(in: root) else {
            throw SwiftDeltaError.unsafePath(candidate.path)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw SwiftDeltaError.missingSelection(canonical.path)
        }

        let expectedExtension = expectedKind == .project ? "xcodeproj" : "xcworkspace"
        guard canonical.pathExtension == expectedExtension else {
            throw SwiftDeltaError.invalidConfiguration(
                field: expectedKind.rawValue,
                reason: "expected a .\(expectedExtension) directory"
            )
        }
        return ProjectContainer(kind: expectedKind, path: canonical.path)
    }

    private func canonicalExclusions(_ paths: [String], root: URL) throws -> [URL] {
        try paths.map { path in
            let value = NSString(string: path).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : root.appendingPathComponent(path)
            let standardized = value.standardizedFileURL
            guard standardized.isContained(in: root) else {
                throw SwiftDeltaError.unsafePath(value.path)
            }
            return standardized
        }
    }

    private func isExcluded(_ url: URL, root: URL, exclusions: [URL]) -> Bool {
        if exclusions.contains(where: { url.isContained(in: $0) }) {
            return true
        }
        let relativeComponents = Array(url.pathComponents.dropFirst(root.pathComponents.count))
        return relativeComponents.contains {
            Self.normalizedExcludedDirectoryNames.contains($0.lowercased())
        }
    }

    private func isGeneratedSource(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".generated.swift") || name.hasPrefix("generated_") {
            return true
        }
        return url.pathComponents.contains {
            let component = $0.lowercased()
            return component == "generated" || component == "generatedsources"
        }
    }
}
