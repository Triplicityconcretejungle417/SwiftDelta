//===--- SwiftPackageDependencyCacheSeeder.swift - SwiftDelta ------------------------------------------===//
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

package struct SwiftPackageDependencyAvailability: Sendable {
    package let resolvedFiles: [String]
    package let dependencyCount: Int
    package let missingDependencies: [String]
}

package enum SwiftPackageDependencyCacheInspector {
    package static func inspect(
        container: ProjectContainer
    ) throws -> SwiftPackageDependencyAvailability {
        let resolvedFiles = resolvedCandidates(for: container).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var identities = Set<String>()
        for resolved in resolvedFiles {
            identities.formUnion(try resolvedIdentities(at: resolved))
        }
        let cacheRoots = repositoryCacheRoots()
        var missing: [String] = []
        for identity in identities.sorted() {
            let prefix = identity.lowercased() + "-"
            let found = cacheRoots.contains { root in
                guard let entries = try? FileManager.default
                    .contentsOfDirectory(
                        at: root,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    )
                else { return false }
                return entries.contains {
                    $0.lastPathComponent.lowercased().hasPrefix(prefix)
                }
            }
            if !found {
                missing.append(identity)
            }
        }
        return SwiftPackageDependencyAvailability(
            resolvedFiles: resolvedFiles.map(\.path).sorted(),
            dependencyCount: identities.count,
            missingDependencies: missing
        )
    }

    fileprivate static func resolvedCandidates(
        for container: ProjectContainer
    ) -> [URL] {
        let url = URL(fileURLWithPath: container.path).canonicalFileURL
        return switch container.kind {
        case .project:
            [
                url.appendingPathComponent(
                    "project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
                ),
                url.appendingPathComponent(
                    "xcshareddata/swiftpm/Package.resolved"
                ),
            ]
        case .workspace:
            [url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")]
        case .package:
            [
                url.deletingLastPathComponent()
                    .appendingPathComponent("Package.resolved"),
            ]
        }
    }

    fileprivate static func resolvedIdentities(at url: URL) throws -> [String] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let object = try JSONSerialization.jsonObject(with: data)
            as? [String: Any]
        else {
            throw SwiftDeltaError.offlineDependencyUnavailable(
                "Package.resolved is malformed at \(url.path)."
            )
        }
        let pins = object["pins"] as? [[String: Any]]
            ?? (object["object"] as? [String: Any])?["pins"]
                as? [[String: Any]]
            ?? []
        return pins.compactMap {
            ($0["identity"] as? String) ?? ($0["package"] as? String)
        }
    }

    fileprivate static func repositoryCacheRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(
                "Library/Caches/org.swift.swiftpm/repositories",
                isDirectory: true
            ),
            home.appendingPathComponent(
                ".swiftpm/cache/repositories",
                isDirectory: true
            ),
        ]
    }
}

enum SwiftPackageDependencyCacheSeeder {
    static func seed(
        packageRoot: URL,
        isolatedCache: URL
    ) throws {
        let resolved = packageRoot.appendingPathComponent("Package.resolved")
        try seed(resolvedFile: resolved, isolatedCache: isolatedCache)
    }

    static func seed(
        xcodeContainer: ProjectContainer,
        isolatedCache: URL
    ) throws {
        for resolved in SwiftPackageDependencyCacheInspector
            .resolvedCandidates(for: xcodeContainer)
            where FileManager.default.fileExists(atPath: resolved.path)
        {
            try seed(
                resolvedFile: resolved,
                isolatedCache: isolatedCache
            )
        }
    }

    private static func seed(
        resolvedFile resolved: URL,
        isolatedCache: URL
    ) throws {
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return
        }
        let identities = try SwiftPackageDependencyCacheInspector
            .resolvedIdentities(at: resolved)
        guard !identities.isEmpty else {
            return
        }

        let candidates = SwiftPackageDependencyCacheInspector
            .repositoryCacheRoots()
        let destination = isolatedCache.appendingPathComponent(
            "repositories",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        for identity in identities {
            let normalizedIdentity = identity.lowercased()
            var copied = false
            for sourceRoot in candidates {
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: sourceRoot,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                for entry in entries
                    where entry.lastPathComponent.lowercased()
                        .hasPrefix("\(normalizedIdentity)-")
                {
                    let target = destination.appendingPathComponent(
                        entry.lastPathComponent
                    )
                    if !FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.copyItem(at: entry, to: target)
                    }
                    copied = true
                    break
                }
                if copied {
                    break
                }
            }
            if !copied {
                throw SwiftDeltaError.offlineDependencyUnavailable(
                    "No local SwiftPM repository cache was found for dependency "
                        + "'\(identity)' locked by \(resolved.path)."
                )
            }
        }
    }
}
