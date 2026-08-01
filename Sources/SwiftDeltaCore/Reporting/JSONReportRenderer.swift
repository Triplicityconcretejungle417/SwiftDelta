//===--- JSONReportRenderer.swift - SwiftDelta ------------------------------------------===//
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

public enum JSONReportRenderer {
    public static func render(_ report: AnalysisReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(report)
        let object = try JSONSerialization.jsonObject(with: encoded)
        let normalized = normalizePaths(
            object,
            projectRoot: report.projectRoot
        )
        return try JSONSerialization.data(
            withJSONObject: normalized,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func normalizePaths(
        _ value: Any,
        projectRoot: String
    ) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues {
                normalizePaths($0, projectRoot: projectRoot)
            }.reduce(into: [String: Any]()) { result, entry in
                if entry.key == "path", let path = entry.value as? String {
                    result[entry.key] = relativePath(
                        path,
                        projectRoot: projectRoot
                    )
                } else {
                    result[entry.key] = entry.value
                }
            }
        }
        if let array = value as? [Any] {
            return array.map {
                normalizePaths($0, projectRoot: projectRoot)
            }
        }
        return value
    }

    private static func relativePath(
        _ path: String,
        projectRoot: String
    ) -> String {
        guard NSString(string: path).isAbsolutePath else {
            return path
        }
        let root = URL(fileURLWithPath: projectRoot)
            .standardizedFileURL.pathComponents
        let file = URL(fileURLWithPath: path)
            .standardizedFileURL.pathComponents
        guard file.count >= root.count,
              Array(file.prefix(root.count)) == root
        else {
            return path
        }
        return file.dropFirst(root.count).joined(separator: "/")
    }
}
