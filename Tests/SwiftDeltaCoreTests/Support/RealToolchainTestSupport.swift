//===--- RealToolchainTestSupport.swift - SwiftDelta ------------------------------------------===//
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
import SwiftDeltaCore
import XCTest

func selectedRealToolchains() throws -> (
    baseline: String,
    candidate: String,
    baselineExpected: ExpectedToolchainIdentity,
    candidateExpected: ExpectedToolchainIdentity
) {
    // Environment selection keeps local Xcode paths out of portable tests.
    let environment = ProcessInfo.processInfo.environment
    guard let baseline = environment["SWIFTDELTA_BASELINE_XCODE"],
          let candidate = environment["SWIFTDELTA_CANDIDATE_XCODE"]
    else {
        throw XCTSkip(
            "Set SWIFTDELTA_BASELINE_XCODE and SWIFTDELTA_CANDIDATE_XCODE "
                + "to run real two-Xcode integration tests."
        )
    }
    return (
        baseline,
        candidate,
        ExpectedToolchainIdentity(
            version: environment["SWIFTDELTA_BASELINE_VERSION"],
            build: environment["SWIFTDELTA_BASELINE_BUILD"],
            sdk: environment["SWIFTDELTA_BASELINE_SDK"]
        ),
        ExpectedToolchainIdentity(
            version: environment["SWIFTDELTA_CANDIDATE_VERSION"],
            build: environment["SWIFTDELTA_CANDIDATE_BUILD"],
            sdk: environment["SWIFTDELTA_CANDIDATE_SDK"]
        )
    )
}

func assertSDKIdentity(
    _ identity: SDKInstallationIdentity,
    expected: ExpectedToolchainIdentity
) throws {
    if let version = expected.version {
        XCTAssertEqual(identity.xcodeVersion, version)
    }
    if let build = expected.build {
        XCTAssertEqual(identity.xcodeBuild, build)
    }
    if let sdk = expected.sdk {
        XCTAssertEqual(identity.sdkVersion, sdk)
    }
    XCTAssertEqual(identity.sdkIdentifier, "macosx")
    XCTAssertEqual(identity.platform, "macOS")
}

func environmentSnapshot(
    from identity: SDKInstallationIdentity
) -> EnvironmentSnapshot {
    EnvironmentSnapshot(
        xcodeVersion: "Xcode \(identity.xcodeVersion)\nBuild version \(identity.xcodeBuild)",
        swiftVersion: identity.swiftVersion,
        sdkVersion: identity.sdkVersion,
        developerDirectory: identity.developerDirectory
    )
}

func realPackageInvocation(
    xcode: String,
    manifest: URL
) -> BuildInvocation {
    BuildInvocation(
        xcodePath: xcode,
        container: ProjectContainer(kind: .package, path: manifest.path),
        configuration: "Debug",
        timeout: 300
    )
}

func assertUniqueArgumentPaths(
    _ option: String,
    calls: [ProcessCall]
) throws {
    let values = try calls.map { call in
        let index = try XCTUnwrap(call.arguments.firstIndex(of: option))
        return call.arguments[index + 1]
    }
    XCTAssertEqual(Set(values).count, values.count)
}

struct ExpectedToolchainIdentity {
    let version: String?
    let build: String?
    let sdk: String?
}
