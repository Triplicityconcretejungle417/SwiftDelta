//===--- SettingsStoreTests.swift - SwiftDelta ------------------------------------------===//
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
@testable import SwiftDelta
import XCTest

final class SettingsStoreTests: XCTestCase {
    func testSettingsCreateLoadAndAtomicallyReplace() throws {
        let directory = try TUITestDirectory()
        let root = directory.url.appendingPathComponent("Application Support")
        let store = TUISettingsStore(applicationSupportDirectory: root)
        var settings = TUISettings()
        settings.appearance.colorMode = .indexed256
        settings.workflow.timeout = 1_800

        try store.save(settings)
        settings.workflow.timeout = 42
        try store.save(settings)
        let loaded = store.loadSettings(safeMode: false)

        XCTAssertEqual(loaded.settings, settings)
        XCTAssertNil(loaded.warning)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".tmp") },
            []
        )
    }

    func testSafeModeIgnoresSettingsWithoutDeletingThem() throws {
        let directory = try TUITestDirectory()
        let store = TUISettingsStore(
            applicationSupportDirectory: directory.url
        )
        var settings = TUISettings()
        settings.workflow.timeout = 1_234
        try store.save(settings)

        let loaded = store.loadSettings(safeMode: true)

        XCTAssertEqual(loaded.settings, TUISettings())
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.settingsURL.path)
        )
    }

    func testCorruptTruncatedAndNewerSettingsRecoverWithoutMutation() throws {
        let directory = try TUITestDirectory()
        let store = TUISettingsStore(
            applicationSupportDirectory: directory.url
        )
        try FileManager.default.createDirectory(
            at: directory.url,
            withIntermediateDirectories: true
        )
        let truncated = Data(#"{"formatVersion":"#.utf8)
        try truncated.write(to: store.settingsURL)
        let corrupt = store.loadSettings(safeMode: false)
        XCTAssertEqual(corrupt.settings, TUISettings())
        XCTAssertNotNil(corrupt.warning)
        XCTAssertEqual(try Data(contentsOf: store.settingsURL), truncated)

        let newer = Data(#"{"formatVersion":999}"#.utf8)
        try newer.write(to: store.settingsURL, options: .atomic)
        let future = store.loadSettings(safeMode: false)
        XCTAssertEqual(future.settings, TUISettings())
        XCTAssertTrue(future.warning?.contains("newer") == true)
        XCTAssertEqual(try Data(contentsOf: store.settingsURL), newer)
    }

    func testOlderSettingsVersionLoadsAsMigration() throws {
        let directory = try TUITestDirectory()
        let store = TUISettingsStore(
            applicationSupportDirectory: directory.url
        )
        var settings = TUISettings()
        settings.formatVersion = 0
        settings.appearance.highContrast = true
        let data = try JSONEncoder().encode(settings)
        try data.write(to: store.settingsURL)

        let loaded = store.loadSettings(safeMode: false)

        XCTAssertTrue(loaded.settings.appearance.highContrast)
        XCTAssertNil(loaded.warning)
    }

    func testHistoryIsDisabledByDefaultAndContainsNoDiagnosticsOrSource()
        throws
    {
        let directory = try TUITestDirectory()
        let store = TUISettingsStore(
            applicationSupportDirectory: directory.url
        )
        let disabled = store.loadHistory(enabled: false, safeMode: false)
        XCTAssertEqual(disabled.history.entries, [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: store.historyURL.path)
        )

        let history = TUIHistory(entries: [
            TUIHistoryEntry(
                projectPath: "/tmp/Synthetic",
                openedAt: Date(timeIntervalSince1970: 10),
                lastOperation: "SDK analysis",
                outcome: "succeeded"
            ),
        ])
        try store.save(history)
        let data = try String(
            contentsOf: store.historyURL,
            encoding: .utf8
        )
        XCTAssertFalse(data.contains("diagnostic"))
        XCTAssertFalse(data.contains("sourceFragment"))
        XCTAssertEqual(
            store.loadHistory(enabled: true, safeMode: false).history,
            history
        )
    }
}
