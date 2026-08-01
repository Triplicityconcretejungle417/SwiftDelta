//===--- SDKChangeModels.swift - SwiftDelta ------------------------------------------===//
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

public enum SDKChangeKind: String, Codable, CaseIterable, Sendable {
    case removed
    case newlyDeprecated
    case newlyUnavailable
    case renamed
    case signatureChanged
    case parameterLabelsChanged
    case parameterTypesChanged
    case returnTypeChanged
    case availabilityChanged
    case propertyAccessChanged
    case protocolRequirementChanged
    case inheritanceChanged
    case conformanceChanged
    case concurrencyChanged
}

public struct SDKSymbolChange: Codable, Hashable, Sendable {
    public let kind: SDKChangeKind
    public let baseline: SDKSymbol
    public let candidate: SDKSymbol?
    public let matchConfidence: Confidence
    public let observedChange: String

    public init(
        kind: SDKChangeKind,
        baseline: SDKSymbol,
        candidate: SDKSymbol?,
        matchConfidence: Confidence = .high,
        observedChange: String
    ) {
        self.kind = kind
        self.baseline = baseline
        self.candidate = candidate
        self.matchConfidence = matchConfidence
        self.observedChange = observedChange
    }
}
