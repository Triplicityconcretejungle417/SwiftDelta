//===--- TUISettingsStore.swift - SwiftDelta ------------------------------------------===//
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

struct TUISettingsLoadResult: Sendable {
    let settings: TUISettings
    let warning: String?
}

struct TUIHistoryLoadResult: Sendable {
    let history: TUIHistory
    let warning: String?
}

struct TUISettingsStore: Sendable {
    let applicationSupportDirectory: URL

    init(applicationSupportDirectory: URL? = nil) {
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.applicationSupportDirectory = base.appendingPathComponent(
                "SwiftDelta",
                isDirectory: true
            )
        }
    }

    var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    var historyURL: URL {
        applicationSupportDirectory.appendingPathComponent("history.json")
    }

    func loadSettings(safeMode: Bool) -> TUISettingsLoadResult {
        guard !safeMode else {
            return TUISettingsLoadResult(settings: TUISettings(), warning: nil)
        }
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return TUISettingsLoadResult(settings: TUISettings(), warning: nil)
        }
        do {
            let data = try Data(contentsOf: settingsURL, options: [.mappedIfSafe])
            let envelope = try JSONDecoder().decode(
                SettingsVersionEnvelope.self,
                from: data
            )
            guard envelope.formatVersion <= TUISettings.currentFormatVersion else {
                return TUISettingsLoadResult(
                    settings: TUISettings(),
                    warning:
                        "Stored settings use a newer format and were ignored."
                )
            }
            let settings = try JSONDecoder().decode(TUISettings.self, from: data)
            return TUISettingsLoadResult(settings: settings, warning: nil)
        } catch {
            return TUISettingsLoadResult(
                settings: TUISettings(),
                warning:
                    "Stored settings could not be read and were ignored: "
                    + error.localizedDescription
            )
        }
    }

    func save(_ settings: TUISettings) throws {
        var value = settings
        value.formatVersion = TUISettings.currentFormatVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(encoder.encode(value), to: settingsURL)
    }

    func loadHistory(enabled: Bool, safeMode: Bool) -> TUIHistoryLoadResult {
        guard enabled, !safeMode else {
            return TUIHistoryLoadResult(history: TUIHistory(), warning: nil)
        }
        guard FileManager.default.fileExists(atPath: historyURL.path) else {
            return TUIHistoryLoadResult(history: TUIHistory(), warning: nil)
        }
        do {
            let data = try Data(contentsOf: historyURL, options: [.mappedIfSafe])
            let history = try JSONDecoder().decode(TUIHistory.self, from: data)
            guard history.formatVersion <= TUIHistory.currentFormatVersion else {
                return TUIHistoryLoadResult(
                    history: TUIHistory(),
                    warning: "Stored history uses a newer format and was ignored."
                )
            }
            return TUIHistoryLoadResult(history: history, warning: nil)
        } catch {
            return TUIHistoryLoadResult(
                history: TUIHistory(),
                warning:
                    "Stored project history could not be read and was ignored: "
                    + error.localizedDescription
            )
        }
    }

    func save(_ history: TUIHistory) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomically(encoder.encode(history), to: historyURL)
    }

    func clearSettings() throws {
        try removeIfPresent(settingsURL)
    }

    func clearHistory() throws {
        try removeIfPresent(historyURL)
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: applicationSupportDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = applicationSupportDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            // A sibling temporary file keeps replacement atomic on one volume.
            try data.write(to: temporary, options: [.atomic])
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: temporary.path
            )
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

private struct SettingsVersionEnvelope: Decodable {
    let formatVersion: Int
}
