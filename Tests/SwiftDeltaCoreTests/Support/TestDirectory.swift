//===--- TestDirectory.swift - SwiftDelta ------------------------------------------===//
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

final class TestDirectory: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var removed = false

    init(name: String = "fixture") throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftdelta-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        url = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    @discardableResult
    func write(_ relativePath: String, _ contents: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: file)
        return file
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    func remove() {
        // Explicit cleanup and deinit may race after cancellation tests.
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
