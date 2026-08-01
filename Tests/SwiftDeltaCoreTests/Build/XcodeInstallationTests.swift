//===--- XcodeInstallationTests.swift - SwiftDelta ------------------------------------------===//
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

final class XcodeInstallationTests: XCTestCase {
    func testValidationRequiresXcodeBundleIdentity() throws {
        let directory = try TestDirectory(name: "xcode-identity")
        defer { directory.remove() }
        let application = try makeXcode(
            in: directory,
            bundleIdentifier: "com.example.Substitute"
        )

        XCTAssertThrowsError(
            try XcodeInstallation.validate(applicationPath: application.path)
        )
    }

    func testTrustInspectionAcceptsAppleIdentityAndIntegrity() throws {
        let directory = try TestDirectory(name: "xcode-trust")
        defer { directory.remove() }
        let application = try makeXcode(
            in: directory,
            bundleIdentifier: "com.apple.dt.Xcode"
        )
        let runner = signatureRunner(verificationError: nil)

        let result = try XcodeInstallation.inspectTrust(
            applicationPath: application.path,
            runner: runner
        )

        XCTAssertEqual(result.state, .trusted)
        XCTAssertEqual(result.teamIdentifier, "59GAB85EFG")
    }

    func testTrustInspectionDistinguishesUnavailableTrustChain() throws {
        let directory = try TestDirectory(name: "xcode-trust-chain")
        defer { directory.remove() }
        let application = try makeXcode(
            in: directory,
            bundleIdentifier: "com.apple.dt.Xcode"
        )
        let runner = signatureRunner(
            verificationError: "CSSMERR_TP_NOT_TRUSTED"
        )

        let result = try XcodeInstallation.inspectTrust(
            applicationPath: application.path,
            runner: runner
        )

        XCTAssertEqual(result.state, .appleSignedTrustUnavailable)
        XCTAssertTrue(result.detail.contains("trust chain"))
    }

    func testTrustInspectionRejectsSubstitutedTeam() throws {
        let directory = try TestDirectory(name: "xcode-substituted-team")
        defer { directory.remove() }
        let application = try makeXcode(
            in: directory,
            bundleIdentifier: "com.apple.dt.Xcode"
        )
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--verbose=4") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data(
                        "Identifier=com.apple.dt.Xcode\nTeamIdentifier=BADTEAM\n".utf8
                    )
                )
            }
            if call.arguments.contains("-r-") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data(
                        "designated => identifier \"com.apple.dt.Xcode\" and anchor apple".utf8
                    )
                )
            }
            return ProcessResult(
                exitStatus: 0,
                standardOutput: Data(),
                standardError: Data()
            )
        }

        let result = try XcodeInstallation.inspectTrust(
            applicationPath: application.path,
            runner: runner
        )

        XCTAssertEqual(result.state, .invalid)
    }

    private func makeXcode(
        in directory: TestDirectory,
        bundleIdentifier: String
    ) throws -> URL {
        let application = directory.url.appendingPathComponent(
            "SyntheticXcode.app",
            isDirectory: true
        )
        let executable = application.appendingPathComponent(
            "Contents/Developer/usr/bin/xcodebuild"
        )
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0",
            "ProductBuildVersion": "1A1",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(
            to: application.appendingPathComponent("Contents/Info.plist")
        )
        return application
    }

    private func signatureRunner(
        verificationError: String?
    ) -> StubProcessRunner {
        StubProcessRunner { call in
            if call.arguments.contains("--verbose=4") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data(
                        "Identifier=com.apple.dt.Xcode\nTeamIdentifier=59GAB85EFG\n".utf8
                    )
                )
            }
            if call.arguments.contains("-r-") {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data(),
                    standardError: Data(
                        "designated => identifier \"com.apple.dt.Xcode\" and anchor apple".utf8
                    )
                )
            }
            return ProcessResult(
                exitStatus: verificationError == nil ? 0 : 1,
                standardOutput: Data(),
                standardError: Data((verificationError ?? "").utf8)
            )
        }
    }
}
