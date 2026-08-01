//===--- SyntheticPackageFixture.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

func packageManifest(
    toolsVersion: String = "6.0",
    platforms: String = ".iOS(.v15)",
    extraTargets: String = ""
) -> String {
    """
    // swift-tools-version: \(toolsVersion)
    import PackageDescription

    let package = Package(
        name: "SyntheticFixture",
        platforms: [\(platforms)],
        targets: [
            .target(name: "SyntheticTarget")\(extraTargets)
        ]
    )
    """
}
