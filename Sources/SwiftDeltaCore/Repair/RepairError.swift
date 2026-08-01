//===--- RepairError.swift - SwiftDelta ------------------------------------------===//
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

public enum RepairError: LocalizedError, Sendable {
    case invalidPlan(String)
    case protectedPath(String, reason: String)
    case invalidRange(String, reason: String)
    case stalePlan(String)
    case conflict([String])
    case noSafeSelection
    case transactionFailed(String)
    case rollbackFailed(String)
    case verificationFailed(String)
    case evidenceUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPlan(reason):
            "Invalid repair plan: \(reason)"
        case let .protectedPath(path, reason):
            "Repair refused for \(path): \(reason)."
        case let .invalidRange(path, reason):
            "Invalid source range for \(path): \(reason)."
        case let .stalePlan(path):
            "Repair plan is stale because \(path) changed after preview."
        case let .conflict(identifiers):
            "Selected repairs conflict: \(identifiers.sorted().joined(separator: ", "))."
        case .noSafeSelection:
            "No safe, conflict-free repairs were selected."
        case let .transactionFailed(reason):
            "Repair transaction failed: \(reason)"
        case let .rollbackFailed(reason):
            "Repair rollback could not restore every source file: \(reason)"
        case let .verificationFailed(reason):
            "Repair verification failed and all source changes were rolled back: \(reason)"
        case let .evidenceUnavailable(reason):
            "Repair evidence is unavailable: \(reason)"
        }
    }
}
