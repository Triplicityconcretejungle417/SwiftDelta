//===--- RepairPlanJSON.swift - SwiftDelta ------------------------------------------===//
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

public enum RepairPlanJSON {
    public static func encode(_ plan: RepairPlan) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(plan)
        data.append(0x0A)
        return data
    }

    public static func decode(_ data: Data) throws -> RepairPlan {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan: RepairPlan
        do {
            plan = try decoder.decode(RepairPlan.self, from: data)
        } catch {
            throw RepairError.invalidPlan(error.localizedDescription)
        }
        guard ["1.0", "2.0", RepairPlan.currentFormatVersion].contains(
            plan.repairPlanFormatVersion
        ) else {
            throw RepairError.invalidPlan(
                "unsupported format version '\(plan.repairPlanFormatVersion)'"
            )
        }
        return plan
    }
}
