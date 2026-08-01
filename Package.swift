// swift-tools-version: 6.4

//===--- Package.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import PackageDescription

let package = Package(
    name: "SwiftDelta",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "swiftdelta", targets: ["SwiftDelta"]),
        .library(name: "SwiftDeltaCore", targets: ["SwiftDeltaCore"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        ),
    ],
    targets: [
        .target(
            name: "SwiftDeltaCore",
            dependencies: [
                "CDiagnosticReader",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "CDiagnosticReader",
            linkerSettings: [
                .linkedLibrary("dl"),
            ]
        ),
        .executableTarget(
            name: "SwiftDelta",
            dependencies: [
                "SwiftDeltaCore",
            ]
        ),
        .testTarget(
            name: "SwiftDeltaCoreTests",
            dependencies: ["SwiftDeltaCore"]
        ),
        .testTarget(
            name: "SwiftDeltaCLITests",
            dependencies: [
                "SwiftDelta",
            ]
        ),
    ]
)
