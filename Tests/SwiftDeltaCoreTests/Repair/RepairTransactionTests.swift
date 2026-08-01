//===--- RepairTransactionTests.swift - SwiftDelta ------------------------------------------===//
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
import XCTest

final class RepairTransactionTests: XCTestCase {
    func testMultipleEditsPreserveUTF8LineEndingsFinalNewlineAndPermissions() throws {
        let directory = try TestDirectory(name: "repair-utf8")
        defer { directory.remove() }
        let file = directory.url.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("let café = \"🙂\"\r\nlet second = café".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o640],
            ofItemAtPath: file.path
        )
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let first = try makeRepair(
            document: document,
            original: "café",
            replacement: "bistro",
            occurrence: 0,
            identifier: "repair.first"
        )
        let second = try makeRepair(
            document: document,
            original: "café",
            replacement: "bistro",
            occurrence: 1,
            identifier: "repair.second"
        )

        let transaction = try RepairTransaction().apply(
            repairs: [first, second],
            projectRoot: directory.url
        )
        transaction.finish()

        let result = try Data(contentsOf: file)
        XCTAssertEqual(
            String(decoding: result, as: UTF8.self),
            "let bistro = \"🙂\"\r\nlet second = bistro"
        )
        XCTAssertFalse(result.last == 0x0A)
        let permissions = try FileManager.default.attributesOfItem(
            atPath: file.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o640)
    }

    func testStaleFingerprintRefusesWrite() throws {
        let directory = try TestDirectory(name: "repair-stale")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let old = 1\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let repair = try makeRepair(
            document: document,
            original: "old",
            replacement: "new"
        )
        try Data("let changed = 1\n".utf8).write(to: file)

        XCTAssertThrowsError(
            try RepairTransaction().apply(
                repairs: [repair],
                projectRoot: directory.url
            )
        ) {
            guard case RepairError.stalePlan = $0 else {
                return XCTFail("Expected stale plan, received \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: file), "let changed = 1\n")
    }

    func testRangeInsideUTF8ScalarIsRejected() throws {
        let directory = try TestDirectory(name: "repair-utf8-boundary")
        defer { directory.remove() }
        let file = try directory.write("A.swift", "let value = \"🙂\"\n")
        let document = try RepairSourceDocument(root: directory.url, file: file)
        let emojiStart = try XCTUnwrap(
            document.data.range(of: Data("🙂".utf8))
        ).lowerBound
        let invalid = RepairSourceRange(
            start: RepairSourcePosition(
                line: 1,
                column: 14,
                utf8Offset: emojiStart + 1
            ),
            end: RepairSourcePosition(
                line: 1,
                column: 14,
                utf8Offset: emojiStart + 1
            )
        )

        XCTAssertThrowsError(try document.text(in: invalid))
    }

    func testMultiFilePartialWriteFailureRollsBackEveryFile() throws {
        let directory = try TestDirectory(name: "repair-partial")
        defer { directory.remove() }
        let firstFile = try directory.write("A.swift", "let oldA = 1\n")
        let secondFile = try directory.write("B.swift", "let oldB = 2\n")
        let firstDocument = try RepairSourceDocument(
            root: directory.url,
            file: firstFile
        )
        let secondDocument = try RepairSourceDocument(
            root: directory.url,
            file: secondFile
        )
        let first = try makeRepair(
            document: firstDocument,
            original: "oldA",
            replacement: "newA"
        )
        let second = try makeRepair(
            document: secondDocument,
            original: "oldB",
            replacement: "newB"
        )

        XCTAssertThrowsError(
            try RepairTransaction(replacer: FailSecondReplacement()).apply(
                repairs: [first, second],
                projectRoot: directory.url
            )
        )
        XCTAssertEqual(try String(contentsOf: firstFile), "let oldA = 1\n")
        XCTAssertEqual(try String(contentsOf: secondFile), "let oldB = 2\n")
    }

    func testTransactionPreservesWriteAndRollbackFailures() throws {
        let directory = try TestDirectory(name: "repair-double-failure")
        defer { directory.remove() }
        let firstFile = try directory.write("A.swift", "let oldA = 1\n")
        let secondFile = try directory.write("B.swift", "let oldB = 2\n")
        let firstDocument = try RepairSourceDocument(
            root: directory.url,
            file: firstFile
        )
        let secondDocument = try RepairSourceDocument(
            root: directory.url,
            file: secondFile
        )
        let first = try makeRepair(
            document: firstDocument,
            original: "oldA",
            replacement: "newA"
        )
        let second = try makeRepair(
            document: secondDocument,
            original: "oldB",
            replacement: "newB"
        )

        XCTAssertThrowsError(
            try RepairTransaction(
                replacer: FailForwardAndRollbackReplacement()
            ).apply(
                repairs: [first, second],
                projectRoot: directory.url
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "synthetic forward write failure"
                )
            )
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "synthetic rollback failure"
                )
            )
        }
    }

    func testProtectedPackageDependencyRootEscapeAndGeneratedFilesAreRejected()
        throws
    {
        let directory = try TestDirectory(name: "repair-protected")
        defer { directory.remove() }
        let package = try directory.write("Package.swift", "// swift-tools-version: 6.0\n")
        let resolved = try directory.write("Package.resolved", "{}\n")
        let dependency = try directory.write(".build/checkouts/Dep/A.swift", "let x = 1\n")
        let generated = try directory.write(
            "Sources/Generated.swift",
            "// @generated\nlet x = 1\n"
        )
        let differentlyCasedPackage = try directory.write(
            "PACKAGE.SWIFT",
            "// protected on case-insensitive project volumes\n"
        )
        let differentlyCasedBuild = try directory.write(
            ".BUILD/Generated.swift",
            "let x = 1\n"
        )
        let differentlyCasedDerivedData = try directory.write(
            "derivedDATA/Generated.swift",
            "let x = 1\n"
        )
        for file in [
            package,
            resolved,
            dependency,
            generated,
            differentlyCasedPackage,
            differentlyCasedBuild,
            differentlyCasedDerivedData,
        ] {
            XCTAssertThrowsError(
                try RepairSourceDocument(root: directory.url, file: file)
            )
        }
        let outside = try TestDirectory(name: "outside")
        defer { outside.remove() }
        let outsideFile = try outside.write("Outside.swift", "let x = 1\n")
        XCTAssertThrowsError(
            try RepairSourceDocument(root: directory.url, file: outsideFile)
        )
    }

    func testSymlinkEscapeIsRejected() throws {
        let directory = try TestDirectory(name: "repair-symlink")
        defer { directory.remove() }
        let outside = try TestDirectory(name: "repair-symlink-outside")
        defer { outside.remove() }
        let target = try outside.write("Outside.swift", "let x = 1\n")
        let link = directory.url.appendingPathComponent("Linked.swift")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try RepairSourceDocument(root: directory.url, file: link)
        )
    }
}

private enum SyntheticReplacementFailure: LocalizedError {
    case forward
    case rollback

    var errorDescription: String? {
        switch self {
        case .forward:
            "synthetic forward write failure"
        case .rollback:
            "synthetic rollback failure"
        }
    }
}

private final class FailForwardAndRollbackReplacement:
    RepairFileReplacing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    func replace(destination: URL, with stagedFile: URL) throws {
        lock.lock()
        count += 1
        let invocation = count
        lock.unlock()
        if invocation == 2 {
            throw SyntheticReplacementFailure.forward
        }
        if invocation == 3 {
            throw SyntheticReplacementFailure.rollback
        }
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: stagedFile
        )
    }
}

private final class FailSecondReplacement: RepairFileReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func replace(destination: URL, with stagedFile: URL) throws {
        lock.lock()
        count += 1
        let shouldFail = count == 2
        lock.unlock()
        if shouldFail {
            throw CocoaError(.fileWriteUnknown)
        }
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: stagedFile
        )
    }
}
