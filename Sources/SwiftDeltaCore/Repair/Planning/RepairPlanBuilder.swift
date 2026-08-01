//===--- RepairPlanBuilder.swift - SwiftDelta ------------------------------------------===//
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

public enum RepairPlanBuilder {
    public static func build(
        projectRoot: URL,
        repairs: [ProposedRepair],
        planningFailures: [AnalysisFailure] = [],
        generatedAt: Date = Date()
    ) -> RepairPlan {
        // Stable ordering keeps plans and conflict reports byte-reproducible.
        let ordered = repairs.sorted(by: repairOrder)
        return RepairPlan(
            generatedAt: generatedAt,
            projectRoot: projectRoot.standardizedFileURL
                .resolvingSymlinksInPath().path,
            repairs: ordered,
            conflicts: conflicts(in: ordered),
            planningFailures: planningFailures
        )
    }

    public static func conflicts(
        in repairs: [ProposedRepair]
    ) -> [RepairConflict] {
        var conflicts: [RepairConflict] = []
        let grouped = Dictionary(grouping: repairs, by: \.filePath)

        for file in grouped.keys.sorted() {
            let fileRepairs = (grouped[file] ?? []).sorted(by: repairOrder)
            for repair in fileRepairs
                where repair.sourceRange.start.utf8Offset < 0
                    || repair.sourceRange.end.utf8Offset
                        < repair.sourceRange.start.utf8Offset
            {
                conflicts.append(
                    RepairConflict(
                        kind: .invalidRange,
                        repairIdentifiers: [repair.repairIdentifier],
                        explanation: "Repair \(repair.repairIdentifier) has an invalid UTF-8 range."
                    )
                )
            }
            for leftIndex in fileRepairs.indices {
                for rightIndex in fileRepairs.indices where rightIndex > leftIndex {
                    let left = fileRepairs[leftIndex]
                    let right = fileRepairs[rightIndex]
                    let sameRange = left.sourceRange == right.sourceRange
                    let sameReplacement = left.replacementText == right.replacementText
                        && left.originalText == right.originalText
                    if sameRange, sameReplacement {
                        conflicts.append(
                            RepairConflict(
                                kind: left.relatedFindingIdentifier
                                    == right.relatedFindingIdentifier
                                    ? .duplicate
                                    : .multipleFindingsSameEdit,
                                repairIdentifiers: [
                                    left.repairIdentifier,
                                    right.repairIdentifier,
                                ],
                                explanation: left.relatedFindingIdentifier
                                    == right.relatedFindingIdentifier
                                    ? "The same edit appears more than once."
                                    : "Multiple findings propose the same edit."
                            )
                        )
                    } else if sameRange {
                        conflicts.append(
                            RepairConflict(
                                kind: .contradictory,
                                repairIdentifiers: [
                                    left.repairIdentifier,
                                    right.repairIdentifier,
                                ],
                                explanation: "The same source range has contradictory replacements."
                            )
                        )
                    } else if overlaps(left.sourceRange, right.sourceRange) {
                        conflicts.append(
                            RepairConflict(
                                kind: .overlapping,
                                repairIdentifiers: [
                                    left.repairIdentifier,
                                    right.repairIdentifier,
                                ],
                                explanation: "The proposed source ranges overlap."
                            )
                        )
                    }
                }
            }
        }
        return conflicts.sorted {
            (
                $0.repairIdentifiers.first ?? "",
                $0.kind.rawValue,
                $0.explanation
            ) < (
                $1.repairIdentifiers.first ?? "",
                $1.kind.rawValue,
                $1.explanation
            )
        }
    }

    public static func selectedRepairs(
        from plan: RepairPlan,
        repairIdentifiers: Set<String>,
        findingIdentifiers: Set<String>,
        filePaths: Set<String>
    ) -> [ProposedRepair] {
        plan.repairs.filter { repair in
            let hasFilter = !repairIdentifiers.isEmpty
                || !findingIdentifiers.isEmpty
                || !filePaths.isEmpty
            guard hasFilter else {
                return true
            }
            return repairIdentifiers.contains(repair.repairIdentifier)
                || findingIdentifiers.contains(repair.relatedFindingIdentifier)
                || filePaths.contains(repair.filePath)
        }
    }

    private static func overlaps(
        _ lhs: RepairSourceRange,
        _ rhs: RepairSourceRange
    ) -> Bool {
        let lhsRange = lhs.start.utf8Offset..<lhs.end.utf8Offset
        let rhsRange = rhs.start.utf8Offset..<rhs.end.utf8Offset
        if lhsRange.isEmpty || rhsRange.isEmpty {
            return lhs.start.utf8Offset == rhs.start.utf8Offset
        }
        return lhsRange.overlaps(rhsRange)
    }

    private static func repairOrder(
        _ lhs: ProposedRepair,
        _ rhs: ProposedRepair
    ) -> Bool {
        (
            lhs.filePath,
            lhs.sourceRange.start.utf8Offset,
            lhs.sourceRange.end.utf8Offset,
            lhs.replacementText,
            lhs.repairIdentifier
        ) < (
            rhs.filePath,
            rhs.sourceRange.start.utf8Offset,
            rhs.sourceRange.end.utf8Offset,
            rhs.replacementText,
            rhs.repairIdentifier
        )
    }
}
