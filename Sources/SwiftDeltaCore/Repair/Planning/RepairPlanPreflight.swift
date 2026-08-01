//===--- RepairPlanPreflight.swift - SwiftDelta ------------------------------------------===//
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

/// Validates a loaded plan before it is presented as selectable.
public enum RepairPlanPreflight {
    public static func validate(
        _ plan: RepairPlan,
        projectRoot: URL
    ) throws {
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let plannedRoot = URL(fileURLWithPath: plan.projectRoot)
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path == plannedRoot.path else {
            throw RepairError.invalidPlan(
                "project root \(plannedRoot.path) does not match "
                    + root.path
            )
        }
        for repair in plan.repairs {
            let document = try RepairSourceDocument(
                root: root,
                file: root.appendingPathComponent(repair.filePath)
            )
            guard document.fingerprint == repair.fileFingerprint else {
                throw RepairError.stalePlan(repair.filePath)
            }
            let range = try document.normalizedByteRange(
                repair.sourceRange
            )
            guard String(
                data: document.data.subdata(in: range),
                encoding: .utf8
            ) == repair.originalText else {
                throw RepairError.stalePlan(repair.filePath)
            }
        }
    }
}
