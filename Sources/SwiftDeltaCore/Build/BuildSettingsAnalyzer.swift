//===--- BuildSettingsAnalyzer.swift - SwiftDelta ------------------------------------------===//
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

public struct BuildSettingsAnalyzer: Sendable {
    public static let exactRelevantSettings: Set<String> = [
        "ARCHS",
        "BUILD_LIBRARY_FOR_DISTRIBUTION",
        "CLANG_ENABLE_MODULES",
        "DEFINES_MODULE",
        "ENABLE_TESTABILITY",
        "ENABLE_USER_SCRIPT_SANDBOXING",
        "EXCLUDED_ARCHS",
        "GCC_TREAT_WARNINGS_AS_ERRORS",
        "IPHONEOS_DEPLOYMENT_TARGET",
        "MACOSX_DEPLOYMENT_TARGET",
        "ONLY_ACTIVE_ARCH",
        "SUPPORTED_PLATFORMS",
        "SWIFT_STRICT_CONCURRENCY",
        "SWIFT_TREAT_WARNINGS_AS_ERRORS",
        "SWIFT_VERSION",
        "TVOS_DEPLOYMENT_TARGET",
        "VALID_ARCHS",
        "VISIONOS_DEPLOYMENT_TARGET",
        "WATCHOS_DEPLOYMENT_TARGET",
    ]

    public init() {}

    public func differences(
        old: [BuildSettingsSnapshot],
        new: [BuildSettingsSnapshot],
        selectedSDKIdentifiers: [String] = []
    ) -> [BuildSettingDifference] {
        let oldMap = old.reduce(into: [String: BuildSettingsSnapshot]()) {
            $0[snapshotKey($1)] = $1
        }
        let newMap = new.reduce(into: [String: BuildSettingsSnapshot]()) {
            $0[snapshotKey($1)] = $1
        }
        let sharedKeys = Set(oldMap.keys).intersection(newMap.keys)
        var differences: [BuildSettingDifference] = []

        for key in sharedKeys.sorted() {
            guard let oldSnapshot = oldMap[key], let newSnapshot = newMap[key] else {
                continue
            }
            let settingNames = Set(oldSnapshot.settings.keys)
                .union(newSnapshot.settings.keys)
                .filter {
                    Self.isMigrationRelevant($0)
                        && Self.isRelevant(
                            $0,
                            selectedSDKIdentifiers: selectedSDKIdentifiers
                        )
                }
            for name in settingNames.sorted() {
                let oldValue = oldSnapshot.settings[name]
                let newValue = newSnapshot.settings[name]
                guard oldValue != newValue else {
                    continue
                }
                differences.append(
                    BuildSettingDifference(
                        target: newSnapshot.target ?? oldSnapshot.target,
                        configuration: newSnapshot.configuration ?? oldSnapshot.configuration,
                        name: name,
                        oldValue: oldValue,
                        newValue: newValue
                    )
                )
            }
        }
        return differences
    }

    public func findings(
        for differences: [BuildSettingDifference],
        targetXcodeVersion: String?
    ) -> [Finding] {
        let findings = differences.map { difference in
            let state = difference.newValue == nil ? "removed" : "changed"
            return Finding(
                findingID: "build-setting.\(state).\(difference.name)",
                category: .buildSetting,
                title: "Effective build setting \(state): \(difference.name)",
                explanation: "\(difference.name) changed from '\(difference.oldValue ?? "<absent>")' to '\(difference.newValue ?? "<absent>")' between the selected Xcode builds.",
                severity: .notice,
                confidence: .high,
                targetVersion: targetXcodeVersion,
                origin: .buildSettings,
                target: difference.target,
                configuration: difference.configuration
            )
        }
        return FindingMerger.merge(findings)
    }

    public func supportedPlatforms(
        in snapshots: [BuildSettingsSnapshot]
    ) -> [String] {
        var platforms = Set<String>()
        for snapshot in snapshots {
            let sdkNames = (snapshot.settings["SUPPORTED_PLATFORMS"] ?? "")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            for sdkName in sdkNames {
                if let platform = Self.platformName(forSDKName: sdkName) {
                    platforms.insert(platform)
                }
            }
            if let sdkRoot = snapshot.settings["SDKROOT"],
               let platform = Self.platformName(forSDKName: sdkRoot)
            {
                platforms.insert(platform)
            }
            let deploymentSettings = [
                "IPHONEOS_DEPLOYMENT_TARGET": "iOS",
                "MACOSX_DEPLOYMENT_TARGET": "macOS",
                "TVOS_DEPLOYMENT_TARGET": "tvOS",
                "WATCHOS_DEPLOYMENT_TARGET": "watchOS",
                "VISIONOS_DEPLOYMENT_TARGET": "visionOS",
            ]
            for (setting, platform) in deploymentSettings
                where snapshot.settings[setting] != nil
            {
                platforms.insert(platform)
            }
        }
        return platforms.sorted()
    }

    public func sdkIdentifiers(
        in snapshots: [BuildSettingsSnapshot]
    ) -> [String] {
        var identifiers = Set<String>()
        for snapshot in snapshots {
            let values = (snapshot.settings["SUPPORTED_PLATFORMS"] ?? "")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            for value in values {
                if let identifier = Self.sdkIdentifier(for: value) {
                    identifiers.insert(identifier)
                }
            }
            if let sdkRoot = snapshot.settings["SDKROOT"],
               let identifier = Self.sdkIdentifier(for: sdkRoot)
            {
                identifiers.insert(identifier)
            }
        }
        return identifiers.sorted()
    }

    private func snapshotKey(_ snapshot: BuildSettingsSnapshot) -> String {
        "\(snapshot.target ?? "")|\(snapshot.configuration ?? "")"
    }

    private static func isMigrationRelevant(_ name: String) -> Bool {
        exactRelevantSettings.contains(name)
            || name.hasPrefix("CLANG_WARN_")
            || name.hasPrefix("SWIFT_WARN_")
            || name.hasPrefix("GCC_WARN_")
    }

    private static func isRelevant(
        _ name: String,
        selectedSDKIdentifiers: [String]
    ) -> Bool {
        guard !selectedSDKIdentifiers.isEmpty else {
            return true
        }
        let selectedPlatforms = Set(
            selectedSDKIdentifiers.compactMap(platformName(forSDKName:))
        )
        let deploymentPlatform: [String: String] = [
            "IPHONEOS_DEPLOYMENT_TARGET": "iOS",
            "MACOSX_DEPLOYMENT_TARGET": "macOS",
            "TVOS_DEPLOYMENT_TARGET": "tvOS",
            "WATCHOS_DEPLOYMENT_TARGET": "watchOS",
            "VISIONOS_DEPLOYMENT_TARGET": "visionOS",
        ]
        guard let platform = deploymentPlatform[name] else {
            return true
        }
        return selectedPlatforms.contains(platform)
    }

    private static func platformName(forSDKName value: String) -> String? {
        let name = value.lowercased()
        if name.hasPrefix("iphone") {
            return "iOS"
        }
        if name.hasPrefix("macos") {
            return "macOS"
        }
        if name.hasPrefix("watch") {
            return "watchOS"
        }
        if name.hasPrefix("appletv") {
            return "tvOS"
        }
        if name.hasPrefix("xros") || name.hasPrefix("xrsimulator") {
            return "visionOS"
        }
        return nil
    }

    private static func sdkIdentifier(for value: String) -> String? {
        let leaf = URL(fileURLWithPath: value).lastPathComponent
            .lowercased()
            .replacingOccurrences(of: ".sdk", with: "")
        let known = [
            "iphonesimulator",
            "iphoneos",
            "appletvsimulator",
            "appletvos",
            "watchsimulator",
            "watchos",
            "xrsimulator",
            "xros",
            "macosx",
        ]
        return known.first { leaf.hasPrefix($0) }
    }
}
