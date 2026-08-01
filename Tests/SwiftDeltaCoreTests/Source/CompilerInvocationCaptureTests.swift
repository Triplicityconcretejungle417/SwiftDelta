//===--- CompilerInvocationCaptureTests.swift - SwiftDelta ------------------------------------------===//
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

final class CompilerInvocationCaptureTests: XCTestCase {
    func testBuildLogParserExpandsResponseFilesAndRetainsSemanticArguments()
        throws
    {
        let directory = try TestDirectory(name: "compiler-invocation-log")
        let first = try directory.write(
            "Project/Sources/First.swift",
            "struct First {}\n"
        )
        let second = try directory.write(
            "Project/Sources/Second.swift",
            "struct Second {}\n"
        )
        let response = try directory.write(
            "Artifacts/common-args.resp",
            """
            -module-name SyntheticApplication
            -sdk /Synthetic/iPhoneSimulator.sdk
            -target arm64-apple-ios17.2-simulator
            -D SYNTHETIC_FEATURE
            -module-cache-path /Synthetic/Build/ModuleCache
            -emit-module-path /Synthetic/Build/SyntheticApplication.swiftmodule
            """
        )
        let fileList = try directory.write(
            "Artifacts/Sources.SwiftFileList",
            "\(first.path)\n\(second.path)\n"
        )
        let outputMap = try directory.write(
            "Artifacts/output-map.json",
            "{}\n"
        )
        let log = """
        SwiftDriver normal arm64 (in target 'SyntheticApplication' from project 'SyntheticContainer')
            builtin-SwiftDriver -- /Synthetic/Toolchain/usr/bin/swiftc @\(response.path) -filelist \(fileList.path) -output-file-map \(outputMap.path) -c -j8
        """

        let values = CompilerInvocationLogParser.parse(
            log,
            artifactRoot: directory.url
        )

        let invocation = try XCTUnwrap(values.only)
        XCTAssertEqual(
            invocation.executable,
            "/Synthetic/Toolchain/usr/bin/swiftc"
        )
        XCTAssertEqual(invocation.moduleName, "SyntheticApplication")
        XCTAssertEqual(invocation.targetName, "SyntheticApplication")
        XCTAssertEqual(invocation.projectName, "SyntheticContainer")
        XCTAssertEqual(invocation.architecture, "arm64")
        XCTAssertEqual(invocation.sourceFiles, [first.path, second.path])
        XCTAssertTrue(
            invocation.analysisArguments.contains("SYNTHETIC_FEATURE")
        )
        XCTAssertTrue(
            invocation.analysisArguments.contains(
                "<SWIFTDELTA_MODULE_CACHE>"
            )
        )
        XCTAssertFalse(
            invocation.analysisArguments.contains("-output-file-map")
        )
        XCTAssertFalse(invocation.analysisArguments.contains("-c"))
        XCTAssertFalse(invocation.analysisArguments.contains("-j8"))
        XCTAssertTrue(invocation.analysisArguments.contains("-dump-ast"))
    }

    func testBuildLogParserKeepsSameNamedTargetsInDifferentProjectsDistinct()
        throws
    {
        let directory = try TestDirectory(name: "compiler-project-identity")
        let first = try directory.write(
            "First/Sources/Shared.swift",
            "struct FirstShared {}\n"
        )
        let second = try directory.write(
            "Second/Sources/Shared.swift",
            "struct SecondShared {}\n"
        )
        let log = """
        SwiftDriver normal arm64 (in target 'Shared' from project 'FirstProject')
            /Synthetic/swiftc -module-name Shared -target arm64-apple-macosx14.0 \(first.path)
        SwiftDriver normal arm64 (in target 'Shared' from project 'SecondProject')
            /Synthetic/swiftc -module-name Shared -target arm64-apple-macosx14.0 \(second.path)
        """

        let values = CompilerInvocationLogParser.parse(
            log,
            artifactRoot: directory.url
        )

        XCTAssertEqual(values.count, 2)
        XCTAssertEqual(
            Set(values.compactMap(\.projectName)),
            ["FirstProject", "SecondProject"]
        )
        XCTAssertEqual(
            Set(values.map(\.sourceFiles)),
            Set([[first.path], [second.path]])
        )
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
