//===--- XcodeInstallation.swift - SwiftDelta ------------------------------------------===//
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

package enum XcodeTrustState: String, Codable, Hashable, Sendable {
    case trusted
    case appleSignedTrustUnavailable
    case invalid
}

package struct XcodeTrustInspection: Codable, Hashable, Sendable {
    package let state: XcodeTrustState
    package let bundleIdentifier: String
    package let teamIdentifier: String?
    package let detail: String

    package init(
        state: XcodeTrustState,
        bundleIdentifier: String,
        teamIdentifier: String?,
        detail: String
    ) {
        self.state = state
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.detail = detail
    }
}

public enum XcodeInstallation {
    public static func validate(applicationPath: String) throws -> String {
        let application = URL(fileURLWithPath: applicationPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let developerDirectory = application
            .appendingPathComponent("Contents/Developer", isDirectory: true)
        let xcodebuild = developerDirectory
            .appendingPathComponent("usr/bin/xcodebuild")
        let info = application.appendingPathComponent("Contents/Info.plist")
        let bundleIdentifier = bundleValue(
            "CFBundleIdentifier",
            from: info
        )
        var isDirectory: ObjCBool = false
        guard application.pathExtension == "app",
              bundleIdentifier == "com.apple.dt.Xcode",
              FileManager.default.fileExists(
                  atPath: developerDirectory.path,
                  isDirectory: &isDirectory
              ),
              isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: xcodebuild.path)
        else {
            throw SwiftDeltaError.invalidXcodePath(applicationPath)
        }
        return developerDirectory.path
    }

    /// Verifies the selected bundle's Apple identity before Doctor permits
    /// tool execution. A valid Apple signature whose certificate chain cannot
    /// be evaluated locally is reported distinctly instead of being mistaken
    /// for an unsigned or substituted application.
    package static func inspectTrust(
        applicationPath: String,
        runner: any ProcessRunning = ProcessRunner(),
        timeout: TimeInterval = 30
    ) throws -> XcodeTrustInspection {
        _ = try validate(applicationPath: applicationPath)
        let application = URL(fileURLWithPath: applicationPath).canonicalFileURL
        let display = try runner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "--verbose=4", application.path],
            timeout: timeout
        )
        let requirement = try runner.run(
            executable: "/usr/bin/codesign",
            arguments: ["-d", "-r-", application.path],
            timeout: timeout
        )
        let verification = try runner.run(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", application.path],
            timeout: timeout
        )
        let displayText = display.standardOutputString
            + "\n" + display.standardErrorString
        let requirementText = requirement.standardOutputString
            + "\n" + requirement.standardErrorString
        let identifier = signatureValue("Identifier", in: displayText)
        let team = signatureValue("TeamIdentifier", in: displayText)
        let hasAppleRequirement = requirementText.contains(
            "identifier \"com.apple.dt.Xcode\""
        ) && requirementText.contains("anchor apple")
        let identityMatches = identifier == "com.apple.dt.Xcode"
            && team == "59GAB85EFG"
            && hasAppleRequirement
            && display.exitStatus == 0
            && requirement.exitStatus == 0
        if identityMatches, verification.exitStatus == 0 {
            return XcodeTrustInspection(
                state: .trusted,
                bundleIdentifier: identifier ?? "com.apple.dt.Xcode",
                teamIdentifier: team,
                detail: "Apple signature identity and integrity verified."
            )
        }
        let verificationText = verification.standardOutputString
            + "\n" + verification.standardErrorString
        if identityMatches,
           verificationText.contains("CSSMERR_TP_NOT_TRUSTED")
        {
            return XcodeTrustInspection(
                state: .appleSignedTrustUnavailable,
                bundleIdentifier: identifier ?? "com.apple.dt.Xcode",
                teamIdentifier: team,
                detail:
                    "The bundle has Apple's Xcode identifier, team, and "
                    + "designated requirement, but this Mac could not establish "
                    + "the current certificate trust chain."
            )
        }
        return XcodeTrustInspection(
            state: .invalid,
            bundleIdentifier: identifier ?? "<unavailable>",
            teamIdentifier: team,
            detail:
                "The application did not pass Xcode signature identity and "
                + "integrity validation."
        )
    }

    public static func discoverApplications(
        runner: any ProcessRunning = ProcessRunner()
    ) -> [String] {
        var candidates = Set<String>()
        let conventionalRoots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop", isDirectory: true),
            URL(
                fileURLWithPath: "/Developer/Applications",
                isDirectory: true
            ),
        ]
        for root in conventionalRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "app" {
                if (try? validate(applicationPath: entry.path)) != nil {
                    candidates.insert(
                        entry.standardizedFileURL
                            .resolvingSymlinksInPath().path
                    )
                }
            }
        }
        if let result = try? runner.run(
            executable: "/usr/bin/mdfind",
            arguments: [
                "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'",
            ],
            timeout: 5
        ), result.exitStatus == 0 {
            for path in result.standardOutputString.split(
                whereSeparator: \.isNewline
            ).map(String.init) {
                if (try? validate(applicationPath: path)) != nil {
                    candidates.insert(
                        URL(fileURLWithPath: path)
                            .standardizedFileURL
                            .resolvingSymlinksInPath().path
                    )
                }
            }
        }
        return candidates.sorted(by: compareApplications)
    }

    private static func compareApplications(
        _ left: String,
        _ right: String
    ) -> Bool {
        let leftIdentity = bundleIdentity(left)
        let rightIdentity = bundleIdentity(right)
        let versionOrder = leftIdentity.version.compare(
            rightIdentity.version,
            options: .numeric
        )
        if versionOrder != .orderedSame {
            return versionOrder == .orderedAscending
        }
        if leftIdentity.build != rightIdentity.build {
            return leftIdentity.build < rightIdentity.build
        }
        return left < right
    }

    private static func bundleIdentity(
        _ applicationPath: String
    ) -> (version: String, build: String) {
        let info = URL(fileURLWithPath: applicationPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info, options: [.mappedIfSafe]),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any]
        else {
            return ("0", "")
        }
        return (
            values["CFBundleShortVersionString"] as? String ?? "0",
            values["DTXcodeBuild"] as? String
                ?? values["CFBundleVersion"] as? String
                ?? ""
        )
    }

    private static func bundleValue(_ key: String, from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let values = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any]
        else {
            return nil
        }
        return values[key] as? String
    }

    private static func signatureValue(
        _ key: String,
        in output: String
    ) -> String? {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let prefix = key + "="
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
    }
}
