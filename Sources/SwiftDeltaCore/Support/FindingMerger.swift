//===--- FindingMerger.swift - SwiftDelta ------------------------------------------===//
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

public enum FindingMerger {
    public static func merge(_ findings: [Finding]) -> [Finding] {
        var selected: [String: Finding] = [:]

        for finding in findings {
            let key = semanticKey(for: finding)
            guard let existing = selected[key] else {
                selected[key] = finding
                continue
            }

            if preferred(finding, over: existing) {
                selected[key] = finding
            }
        }

        return selected.values.sorted(by: findingOrder)
    }

    private static func semanticKey(for finding: Finding) -> String {
        let title = finding.title
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let explanation = finding.origin == .compiler
            ? finding.explanation
                .lowercased()
                .replacingOccurrences(
                    of: #"\s+"#,
                    with: " ",
                    options: .regularExpression
                )
            : ""
        return [
            finding.location?.path ?? "",
            finding.location?.line.map(String.init) ?? "",
            finding.location?.column.map(String.init) ?? "",
            finding.target ?? "",
            finding.configuration ?? "",
            title,
            explanation,
        ].joined(separator: "|")
    }

    private static func preferred(_ candidate: Finding, over existing: Finding) -> Bool {
        if candidate.confidence.rank != existing.confidence.rank {
            return candidate.confidence.rank > existing.confidence.rank
        }
        if candidate.severity.rank != existing.severity.rank {
            if candidate.origin == .compiler, existing.origin == .compiler {
                return candidate.severity.rank < existing.severity.rank
            }
            return candidate.severity.rank > existing.severity.rank
        }
        if candidate.origin == .compiler, existing.origin != .compiler {
            return true
        }
        return candidate.findingID < existing.findingID
    }

    private static func findingOrder(_ lhs: Finding, _ rhs: Finding) -> Bool {
        if lhs.severity.rank != rhs.severity.rank {
            return lhs.severity.rank > rhs.severity.rank
        }
        let leftPath = lhs.location?.path ?? ""
        let rightPath = rhs.location?.path ?? ""
        if leftPath != rightPath {
            return leftPath < rightPath
        }
        if lhs.location?.line != rhs.location?.line {
            return (lhs.location?.line ?? 0) < (rhs.location?.line ?? 0)
        }
        return lhs.findingID < rhs.findingID
    }
}
