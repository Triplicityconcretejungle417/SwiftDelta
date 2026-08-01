//===--- RepairTransaction.swift - SwiftDelta ------------------------------------------===//
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

protocol RepairFileReplacing: Sendable {
    func replace(destination: URL, with stagedFile: URL) throws
}

struct AtomicRepairFileReplacer: RepairFileReplacing {
    func replace(destination: URL, with stagedFile: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: stagedFile,
            backupItemName: nil,
            options: []
        )
    }
}

struct RepairOriginalFile: Sendable {
    let url: URL
    let relativePath: String
    let data: Data
    let permissions: NSNumber
    let fingerprint: RepairFileFingerprint
}

final class AppliedRepairTransaction {
    private let originals: [RepairOriginalFile]
    private let replacer: any RepairFileReplacing
    private let stagingDirectory: TemporaryDirectory
    private(set) var isFinished = false

    init(
        originals: [RepairOriginalFile],
        replacer: any RepairFileReplacing,
        stagingDirectory: TemporaryDirectory
    ) {
        self.originals = originals
        self.replacer = replacer
        self.stagingDirectory = stagingDirectory
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        stagingDirectory.remove()
    }

    func rollback() throws {
        guard !isFinished else {
            return
        }
        var failures: [String] = []
        for (index, original) in originals.enumerated().reversed() {
            do {
                let staged = stagingDirectory.url.appendingPathComponent(
                    "rollback-\(index)"
                )
                try original.data.write(to: staged, options: [.atomic])
                try FileManager.default.setAttributes(
                    [.posixPermissions: original.permissions],
                    ofItemAtPath: staged.path
                )
                try replacer.replace(destination: original.url, with: staged)
                let restored = try Data(contentsOf: original.url)
                guard RepairFingerprint.file(restored) == original.fingerprint else {
                    throw RepairError.rollbackFailed(
                        "restored bytes do not match \(original.relativePath)"
                    )
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: original.permissions],
                    ofItemAtPath: original.url.path
                )
            } catch {
                failures.append("\(original.relativePath): \(error.localizedDescription)")
            }
        }
        isFinished = true
        stagingDirectory.remove()
        if !failures.isEmpty {
            throw RepairError.rollbackFailed(failures.joined(separator: "; "))
        }
    }

    deinit {
        if !isFinished {
            try? rollback()
        }
    }
}

struct RepairTransaction {
    private let replacer: any RepairFileReplacing

    init(replacer: any RepairFileReplacing = AtomicRepairFileReplacer()) {
        self.replacer = replacer
    }

    func apply(
        repairs: [ProposedRepair],
        projectRoot: URL
    ) throws -> AppliedRepairTransaction {
        guard !repairs.isEmpty else {
            throw RepairError.noSafeSelection
        }
        guard repairs.allSatisfy(\.isExplicitlyApplicable) else {
            throw RepairError.invalidPlan(
                "only deterministic safe repairs or explicitly reviewed "
                    + "Foundation Models repairs may be applied"
            )
        }
        let conflicts = RepairPlanBuilder.conflicts(in: repairs)
        guard conflicts.isEmpty else {
            throw RepairError.conflict(
                Array(Set(conflicts.flatMap(\.repairIdentifiers))).sorted()
            )
        }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let grouped = Dictionary(grouping: repairs, by: \.filePath)
        var documents: [String: RepairSourceDocument] = [:]
        var results: [String: Data] = [:]

        // Validate every file before the first write. Fingerprints and original
        // fragments are checked again immediately before replacement.
        for relativePath in grouped.keys.sorted() {
            try RepairPathPolicy.validate(relativePath: relativePath)
            let file = root.appendingPathComponent(relativePath)
            let document = try RepairSourceDocument(root: root, file: file)
            let fileRepairs = grouped[relativePath] ?? []
            try validate(fileRepairs, against: document)
            documents[relativePath] = document
            results[relativePath] = try applying(
                fileRepairs,
                to: document.data,
                path: relativePath
            )
        }

        let staging = try TemporaryDirectory(prefix: "swiftdelta-repair-transaction")
        var originals: [RepairOriginalFile] = []
        var replaced: [RepairOriginalFile] = []
        do {
            for (index, relativePath) in grouped.keys.sorted().enumerated() {
                guard let document = documents[relativePath],
                      let result = results[relativePath]
                else {
                    throw RepairError.transactionFailed(
                        "internal staging state is incomplete for \(relativePath)"
                    )
                }
                let current = try RepairSourceDocument(root: root, file: document.url)
                try validate(grouped[relativePath] ?? [], against: current)
                let original = RepairOriginalFile(
                    url: document.url,
                    relativePath: relativePath,
                    data: document.data,
                    permissions: document.permissions,
                    fingerprint: document.fingerprint
                )
                originals.append(original)
                let staged = staging.url.appendingPathComponent("staged-\(index)")
                try result.write(to: staged, options: [.atomic])
                guard String(data: result, encoding: .utf8) != nil else {
                    throw RepairError.transactionFailed(
                        "staged source for \(relativePath) is not valid UTF-8"
                    )
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: document.permissions],
                    ofItemAtPath: staged.path
                )
                try replacer.replace(destination: document.url, with: staged)
                replaced.append(original)
                let installed = try Data(contentsOf: document.url)
                guard installed == result else {
                    throw RepairError.transactionFailed(
                        "installed bytes do not match the staged source for \(relativePath)"
                    )
                }
                try FileManager.default.setAttributes(
                    [.posixPermissions: document.permissions],
                    ofItemAtPath: document.url.path
                )
            }
            return AppliedRepairTransaction(
                originals: originals,
                replacer: replacer,
                stagingDirectory: staging
            )
        } catch {
            let applicationError = error
            let transaction = AppliedRepairTransaction(
                originals: replaced,
                replacer: replacer,
                stagingDirectory: staging
            )
            do {
                try transaction.rollback()
            } catch {
                throw RepairError.transactionFailed(
                    "\(applicationError.localizedDescription); rollback also "
                        + "failed: \(error.localizedDescription)"
                )
            }
            throw RepairError.transactionFailed(
                applicationError.localizedDescription
            )
        }
    }

    private func validate(
        _ repairs: [ProposedRepair],
        against document: RepairSourceDocument
    ) throws {
        for repair in repairs {
            guard repair.filePath == document.relativePath else {
                throw RepairError.invalidPlan(
                    "repair \(repair.repairIdentifier) names a different source file"
                )
            }
            guard repair.fileFingerprint == document.fingerprint else {
                throw RepairError.stalePlan(document.relativePath)
            }
            let original = try document.text(in: repair.sourceRange)
            guard original == repair.originalText else {
                throw RepairError.stalePlan(document.relativePath)
            }
        }
    }

    private func applying(
        _ repairs: [ProposedRepair],
        to data: Data,
        path: String
    ) throws -> Data {
        var result = data
        for repair in repairs.sorted(by: {
            $0.sourceRange.start.utf8Offset > $1.sourceRange.start.utf8Offset
        }) {
            let lower = repair.sourceRange.start.utf8Offset
            let upper = repair.sourceRange.end.utf8Offset
            guard lower >= 0, upper >= lower, upper <= result.count else {
                throw RepairError.invalidRange(
                    path,
                    reason: "\(lower)..<\(upper) is outside the source file"
                )
            }
            result.replaceSubrange(lower..<upper, with: Data(repair.replacementText.utf8))
        }
        return result
    }
}
