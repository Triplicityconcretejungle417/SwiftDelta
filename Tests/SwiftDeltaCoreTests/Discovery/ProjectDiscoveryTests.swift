//===--- ProjectDiscoveryTests.swift - SwiftDelta ------------------------------------------===//
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

final class ProjectDiscoveryTests: XCTestCase {
    func testXcodeTargetMembershipDoesNotIncludeUnrelatedRootSources() throws {
        let directory = try TestDirectory(name: "target-membership")
        let fixture = try makeSyntheticXcodeProject(
            in: directory,
            candidateOnlyWarning: false
        )
        let unrelated = try directory.write(
            "SyntheticXcodeProject/Unrelated/SyntheticFixture.swift",
            "struct UnrelatedFixture {}\n"
        )

        let membership = try XcodeTargetSourceMembershipReader.read(
            project: ProjectContainer(
                kind: .project,
                path: fixture.project.path
            ),
            projectRoot: fixture.root
        )

        XCTAssertEqual(
            membership.sourceFilesByTarget[fixture.scheme],
            [fixture.source.path]
        )
        XCTAssertFalse(
            membership.sourceFilesByTarget[fixture.scheme, default: []]
                .contains(unrelated.path)
        )
        XCTAssertTrue(membership.unsupportedReasons.isEmpty)
    }

    func testAppAndExtensionKeepOverlappingNamesAndDependenciesSeparate()
        throws
    {
        let directory = try TestDirectory(name: "multi-target-membership")
        let root = try directory.makeDirectory("Synthetic")
        let project = try directory.makeDirectory(
            "Synthetic/MultiTarget.xcodeproj"
        )
        let appSource = try directory.write(
            "Synthetic/App/File.swift",
            "struct AppFile {}\n"
        )
        let extensionSource = try directory.write(
            "Synthetic/Extension/File.swift",
            "struct ExtensionFile {}\n"
        )
        try directory.write(
            "Synthetic/MultiTarget.xcodeproj/project.pbxproj",
            """
            {
              objects = {
                A00000000000000000000001 = { isa = PBXBuildFile; fileRef = A00000000000000000000002; };
                A00000000000000000000002 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = File.swift; sourceTree = "<group>"; };
                A00000000000000000000003 = { isa = PBXGroup; children = (A00000000000000000000002); path = App; sourceTree = "<group>"; };
                A00000000000000000000004 = { isa = PBXSourcesBuildPhase; files = (A00000000000000000000001); };
                A00000000000000000000005 = { isa = PBXNativeTarget; name = SyntheticApp; buildPhases = (A00000000000000000000004); dependencies = (A0000000000000000000000B); };
                A00000000000000000000006 = { isa = PBXBuildFile; fileRef = A00000000000000000000007; };
                A00000000000000000000007 = { isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = File.swift; sourceTree = "<group>"; };
                A00000000000000000000008 = { isa = PBXGroup; children = (A00000000000000000000007); path = Extension; sourceTree = "<group>"; };
                A00000000000000000000009 = { isa = PBXSourcesBuildPhase; files = (A00000000000000000000006); };
                A0000000000000000000000A = { isa = PBXNativeTarget; name = SyntheticExtension; buildPhases = (A00000000000000000000009); dependencies = (); };
                A0000000000000000000000B = { isa = PBXTargetDependency; target = A0000000000000000000000A; };
                A0000000000000000000000C = { isa = PBXGroup; children = (A00000000000000000000003, A00000000000000000000008); sourceTree = "<group>"; };
              };
            }
            """
        )

        let membership = try XcodeTargetSourceMembershipReader.read(
            project: ProjectContainer(kind: .project, path: project.path),
            projectRoot: root
        )

        XCTAssertEqual(
            membership.sourceFilesByTarget["SyntheticApp"],
            [appSource.path]
        )
        XCTAssertEqual(
            membership.sourceFilesByTarget["SyntheticExtension"],
            [extensionSource.path]
        )
        XCTAssertEqual(
            membership.dependenciesByTarget["SyntheticApp"],
            ["SyntheticExtension"]
        )
        XCTAssertEqual(
            membership.dependenciesByTarget["SyntheticExtension"],
            []
        )
    }

func testDiscoveryFindsPurePackageAndExcludesGeneratedAndBuildArtifacts() throws {
        let directory = try TestDirectory(name: "discovery")
        let manifest = try directory.write("Package.swift", packageManifest())
        let source = try directory.write(
            "Sources/SyntheticTarget/File.swift",
            "public struct FictionalValue {}\n"
        )
        try directory.write(
            ".build/checkouts/Dependency/Source.swift",
            "public struct MustNotBeScanned {}\n"
        )
        try directory.write(
            "Generated/Generated.swift",
            "public struct MustNotBeScannedEither {}\n"
        )
        try directory.write(
            ".BUILD/Generated.swift",
            "public struct CaseVariantMustNotBeScanned {}\n"
        )
        try directory.write(
            "generatedsources/Generated.swift",
            "public struct CaseVariantGeneratedMustNotBeScanned {}\n"
        )

        let result = try ProjectDiscovery().discover(root: directory.url)
        let container = try ProjectDiscovery().selectBuildContainer(from: result)

        XCTAssertEqual(result.swiftFiles, [source.path])
        XCTAssertEqual(container.kind, .package)
        XCTAssertEqual(container.path, manifest.path)
    }

    func testBuildContainerPrefersSingleXcodeContainerAndReportsAmbiguity() throws {
        let directory = try TestDirectory(name: "selection")
        try directory.write("Package.swift", packageManifest())
        let project = try directory.makeDirectory("Synthetic.xcodeproj")
        var result = try ProjectDiscovery().discover(root: directory.url)

        XCTAssertEqual(
            try ProjectDiscovery().selectBuildContainer(from: result),
            ProjectContainer(kind: .project, path: project.path)
        )

        try directory.makeDirectory("Second.xcworkspace")
        result = try ProjectDiscovery().discover(root: directory.url)
        XCTAssertThrowsError(
            try ProjectDiscovery().selectBuildContainer(from: result)
        ) { error in
            guard case SwiftDeltaError.ambiguousSelection = error else {
                return XCTFail("Expected ambiguity, received \(error)")
            }
        }
    }
}
