//===--- SyntheticToolchainFixture.swift - SwiftDelta ------------------------------------------===//
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

func makeSyntheticXcode(in directory: TestDirectory, name: String) throws -> URL {
    let application = try directory.makeDirectory("\(name).app")
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.apple.dt.Xcode",
        "CFBundleShortVersionString": "99.0",
        "DTXcodeBuild": "99A1",
    ]
    let infoData = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    let infoURL = application.appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(
        at: infoURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try infoData.write(to: infoURL)
    let xcodebuild = try directory.write(
        "\(name).app/Contents/Developer/usr/bin/xcodebuild",
        "#!/bin/sh\nexit 0\n"
    )
    let swift = try directory.write(
        "\(name).app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
        "#!/bin/sh\nexit 0\n"
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: xcodebuild.path
    )
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: swift.path
    )
    return application
}
