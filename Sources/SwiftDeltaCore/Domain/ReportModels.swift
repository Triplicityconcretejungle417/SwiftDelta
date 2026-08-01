//===--- ReportModels.swift - SwiftDelta ------------------------------------------===//
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

public enum ReportFormat: String, Codable, CaseIterable, Sendable {
    case terminal
    case json
    case sarif
}

public struct VersionNumber: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    init(components: [Int]) {
        self.components = components
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        components = parts.compactMap { Int($0) }
    }

    public static func < (lhs: VersionNumber, rhs: VersionNumber) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }
}
