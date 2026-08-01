//===--- RepairSourceDiscovery.swift - SwiftDelta ------------------------------------------===//
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

struct RepairSourceDiscovery {
    func discover(
        root: URL,
        excludedPaths: [String],
        selectedPaths: [String]
    ) throws -> [URL] {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if !selectedPaths.isEmpty {
            return try selectedPaths.map { path in
                let candidate = NSString(string: path).isAbsolutePath
                    ? URL(fileURLWithPath: path)
                    : canonicalRoot.appendingPathComponent(path)
                _ = try RepairSourceDocument(root: canonicalRoot, file: candidate)
                return candidate.standardizedFileURL
            }.sorted { $0.path < $1.path }
        }

        let exclusions = try excludedPaths.map { path -> URL in
            let candidate = NSString(string: path).isAbsolutePath
                ? URL(fileURLWithPath: path)
                : canonicalRoot.appendingPathComponent(path)
            let standardized = candidate.standardizedFileURL
            guard standardized.isContained(in: canonicalRoot) else {
                throw SwiftDeltaError.unsafePath(candidate.path)
            }
            return standardized
        }
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .nameKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            throw SwiftDeltaError.invalidRoot(root.path)
        }
        var files: [URL] = []
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: keys)
            let name = values?.name ?? file.lastPathComponent
            if values?.isDirectory == true {
                if ProjectDiscovery.defaultExcludedDirectoryNames.contains(name)
                    || name.hasSuffix(".xcodeproj")
                    || name.hasSuffix(".xcworkspace")
                    || exclusions.contains(where: { file.isContained(in: $0) })
                {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  exclusions.allSatisfy({ !file.isContained(in: $0) }),
                  RepairPathPolicy.language(for: file) != nil
            else {
                continue
            }
            if (try? RepairSourceDocument(root: canonicalRoot, file: file)) != nil {
                files.append(file.standardizedFileURL)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}
