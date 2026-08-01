//===--- RepairTestSupport.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDeltaCore

func makeRepair(
    document: RepairSourceDocument,
    original: String,
    replacement: String,
    occurrence: Int = 0,
    identifier: String = UUID().uuidString,
    finding: String = "finding.synthetic",
    source: RepairEvidenceSource = .swiftCompilerFixIt,
    safety: RepairSafetyClassification = .safe
) throws -> ProposedRepair {
    let sourceBytes = Array(document.data)
    let needle = Array(original.utf8)
    var matches: [Int] = []
    if needle.isEmpty {
        matches = [0]
    } else if sourceBytes.count >= needle.count {
        for index in 0...(sourceBytes.count - needle.count)
            where Array(sourceBytes[index..<(index + needle.count)]) == needle
        {
            matches.append(index)
        }
    }
    let start = matches[occurrence]
    let end = start + needle.count
    return ProposedRepair(
        repairIdentifier: identifier,
        relatedFindingIdentifier: finding,
        evidenceSource: source,
        language: document.language,
        filePath: document.relativePath,
        sourceRange: RepairSourceRange(
            start: sourcePosition(start, in: document.data),
            end: sourcePosition(end, in: document.data)
        ),
        originalText: original,
        replacementText: replacement,
        fileFingerprint: document.fingerprint,
        confidence: .high,
        safety: safety,
        explanation: "Synthetic exact source edit.",
        verificationRequirement: .candidateBuild
    )
}

func sourcePosition(_ offset: Int, in data: Data) -> RepairSourcePosition {
    let prefix = data.prefix(offset)
    let line = prefix.count(where: { $0 == 0x0A }) + 1
    let lineStart = prefix.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
    let column = String(decoding: prefix.dropFirst(lineStart), as: UTF8.self).count + 1
    return RepairSourcePosition(line: line, column: column, utf8Offset: offset)
}

final class SequenceRepairVerifier: RepairVerifying, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [RepairVerificationSnapshot]

    init(_ snapshots: [RepairVerificationSnapshot]) {
        self.snapshots = snapshots
    }

    func capture() throws -> RepairVerificationSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.removeFirst()
    }
}
