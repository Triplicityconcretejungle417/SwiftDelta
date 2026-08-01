//===--- TemporaryDirectory.swift - SwiftDelta ------------------------------------------===//
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

/// Owns a private temporary directory and removes it explicitly or on deinit.
///
/// Removal is idempotent because callers commonly clean up with both `defer`
/// and lifetime-based fallback cleanup.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var removed = false

    public init(prefix: String) throws {
        let safePrefix = prefix.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safePrefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        url = directory
    }

    public func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else {
            return
        }
        try? FileManager.default.removeItem(at: url)
        removed = true
    }

    deinit {
        remove()
    }
}
