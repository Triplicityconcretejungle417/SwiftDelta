//===--- BuildSettingsParser.swift - SwiftDelta ------------------------------------------===//
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

public struct BuildSettingDifference: Codable, Equatable, Sendable {
    public let target: String?
    public let configuration: String?
    public let name: String
    public let oldValue: String?
    public let newValue: String?

    public init(
        target: String?,
        configuration: String?,
        name: String,
        oldValue: String?,
        newValue: String?
    ) {
        self.target = target
        self.configuration = configuration
        self.name = name
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

public enum BuildSettingsParser {
    public static func parse(
        _ data: Data,
        fallbackConfiguration: String? = nil
    ) throws -> [BuildSettingsSnapshot] {
        if let json = try? JSONSerialization.jsonObject(with: data),
           let entries = json as? [[String: Any]]
        {
            return entries.compactMap { entry in
                guard let rawSettings = entry["buildSettings"] as? [String: Any] else {
                    return nil
                }
                let settings = rawSettings.reduce(into: [String: String]()) { result, pair in
                    if let string = pair.value as? String {
                        result[pair.key] = string
                    } else if pair.value is NSNull {
                        result[pair.key] = nil
                    } else {
                        result[pair.key] = String(describing: pair.value)
                    }
                }
                return BuildSettingsSnapshot(
                    target: entry["target"] as? String,
                    configuration: (entry["configuration"] as? String) ?? fallbackConfiguration,
                    settings: settings
                )
            }
        }

        return parseText(
            String(decoding: data, as: UTF8.self),
            fallbackConfiguration: fallbackConfiguration
        )
    }

    private static func parseText(
        _ text: String,
        fallbackConfiguration: String?
    ) -> [BuildSettingsSnapshot] {
        var snapshots: [BuildSettingsSnapshot] = []
        var target: String?
        var settings: [String: String] = [:]

        func finishCurrent() {
            guard target != nil || !settings.isEmpty else {
                return
            }
            snapshots.append(
                BuildSettingsSnapshot(
                    target: target,
                    configuration: fallbackConfiguration,
                    settings: settings
                )
            )
            settings = [:]
        }

        for line in text.split(whereSeparator: \.isNewline).map(String.init) {
            let prefix = "Build settings for action "
            if line.hasPrefix(prefix), let marker = line.range(of: " and target ") {
                finishCurrent()
                target = String(line[marker.upperBound...].dropLast(line.hasSuffix(":") ? 1 : 0))
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.range(of: " = ") else {
                continue
            }
            let key = String(trimmed[..<separator.lowerBound])
            let value = String(trimmed[separator.upperBound...])
            guard !key.isEmpty else {
                continue
            }
            settings[key] = value
        }
        finishCurrent()
        return snapshots
    }
}
