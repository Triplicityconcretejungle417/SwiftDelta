//===--- SyntheticXcodeProjectFixture.swift - SwiftDelta ------------------------------------------===//
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

struct SyntheticXcodeProject {
    let root: URL
    let project: URL
    let source: URL
    let scheme: String
}

func makeSyntheticXcodeProject(
    in directory: TestDirectory,
    candidateOnlyWarning: Bool = true
) throws -> SyntheticXcodeProject {
    let root = try directory.makeDirectory("SyntheticXcodeProject")
    let project = try directory.makeDirectory(
        "SyntheticXcodeProject/SyntheticIntegration.xcodeproj"
    )
    let sourceText = """
    import Foundation

    \(candidateOnlyWarning ? """
    #if compiler(>=6.4)
    @available(*, deprecated, message: "synthetic candidate-only project diagnostic")
    private func syntheticCandidateOnlyAPI() {}
    private let syntheticCandidateOnlyValue: Void = syntheticCandidateOnlyAPI()
    #endif

    """ : "")public struct SyntheticFixture {
        public init() {}
    }
    """
    let source = try directory.write(
        "SyntheticXcodeProject/Sources/SyntheticFixture.swift",
        sourceText
    )
    try directory.write(
        "SyntheticXcodeProject/SyntheticIntegration.xcodeproj/project.pbxproj",
        """
        // !$*UTF8*$!
        {
            archiveVersion = 1;
            classes = {};
            objectVersion = 56;
            objects = {
                A00000000000000000000001 = {
                    isa = PBXBuildFile;
                    fileRef = A00000000000000000000002;
                };
                A00000000000000000000002 = {
                    isa = PBXFileReference;
                    lastKnownFileType = sourcecode.swift;
                    path = SyntheticFixture.swift;
                    sourceTree = "<group>";
                };
                A00000000000000000000003 = {
                    isa = PBXFileReference;
                    explicitFileType = archive.ar;
                    includeInIndex = 0;
                    path = libSyntheticIntegration.a;
                    sourceTree = BUILT_PRODUCTS_DIR;
                };
                A00000000000000000000004 = {
                    isa = PBXGroup;
                    children = (
                        A00000000000000000000005,
                        A00000000000000000000006,
                    );
                    sourceTree = "<group>";
                };
                A00000000000000000000005 = {
                    isa = PBXGroup;
                    children = (A00000000000000000000002);
                    path = Sources;
                    sourceTree = "<group>";
                };
                A00000000000000000000006 = {
                    isa = PBXGroup;
                    children = (A00000000000000000000003);
                    name = Products;
                    sourceTree = "<group>";
                };
                A00000000000000000000007 = {
                    isa = PBXSourcesBuildPhase;
                    buildActionMask = 2147483647;
                    files = (A00000000000000000000001);
                    runOnlyForDeploymentPostprocessing = 0;
                };
                A00000000000000000000008 = {
                    isa = PBXFrameworksBuildPhase;
                    buildActionMask = 2147483647;
                    files = ();
                    runOnlyForDeploymentPostprocessing = 0;
                };
                A00000000000000000000009 = {
                    isa = PBXNativeTarget;
                    buildConfigurationList = A00000000000000000000010;
                    buildPhases = (
                        A00000000000000000000007,
                        A00000000000000000000008,
                    );
                    buildRules = ();
                    dependencies = ();
                    name = SyntheticIntegration;
                    productName = SyntheticIntegration;
                    productReference = A00000000000000000000003;
                    productType = "com.apple.product-type.library.static";
                };
                A0000000000000000000000A = {
                    isa = PBXProject;
                    attributes = {
                        BuildIndependentTargetsInParallel = 1;
                        LastSwiftUpdateCheck = 1500;
                        LastUpgradeCheck = 1500;
                    };
                    buildConfigurationList = A0000000000000000000000B;
                    compatibilityVersion = "Xcode 14.0";
                    developmentRegion = en;
                    hasScannedForEncodings = 0;
                    knownRegions = (en, Base);
                    mainGroup = A00000000000000000000004;
                    productRefGroup = A00000000000000000000006;
                    projectDirPath = "";
                    projectRoot = "";
                    targets = (A00000000000000000000009);
                };
                A0000000000000000000000C = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        MACOSX_DEPLOYMENT_TARGET = 13.0;
                        SDKROOT = macosx;
                    };
                    name = Debug;
                };
                A0000000000000000000000D = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        MACOSX_DEPLOYMENT_TARGET = 13.0;
                        SDKROOT = macosx;
                    };
                    name = Release;
                };
                A0000000000000000000000E = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        ARCHS = arm64;
                        CODE_SIGNING_ALLOWED = NO;
                        ONLY_ACTIVE_ARCH = YES;
                        PRODUCT_NAME = "$(TARGET_NAME)";
                        SWIFT_VERSION = 5.0;
                        SWIFT_TREAT_WARNINGS_AS_ERRORS = NO;
                    };
                    name = Debug;
                };
                A0000000000000000000000F = {
                    isa = XCBuildConfiguration;
                    buildSettings = {
                        ARCHS = arm64;
                        CODE_SIGNING_ALLOWED = NO;
                        ONLY_ACTIVE_ARCH = YES;
                        PRODUCT_NAME = "$(TARGET_NAME)";
                        SWIFT_VERSION = 5.0;
                        SWIFT_TREAT_WARNINGS_AS_ERRORS = NO;
                    };
                    name = Release;
                };
                A00000000000000000000010 = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        A0000000000000000000000E,
                        A0000000000000000000000F,
                    );
                    defaultConfigurationIsVisible = 0;
                    defaultConfigurationName = Release;
                };
                A0000000000000000000000B = {
                    isa = XCConfigurationList;
                    buildConfigurations = (
                        A0000000000000000000000C,
                        A0000000000000000000000D,
                    );
                    defaultConfigurationIsVisible = 0;
                    defaultConfigurationName = Release;
                };
            };
            rootObject = A0000000000000000000000A;
        }
        """
    )
    try directory.write(
        "SyntheticXcodeProject/SyntheticIntegration.xcodeproj/xcshareddata/xcschemes/SyntheticIntegration.xcscheme",
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme LastUpgradeVersion="1500" version="1.7">
           <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
              <BuildActionEntries>
                 <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
                    <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="A00000000000000000000009" BuildableName="libSyntheticIntegration.a" BlueprintName="SyntheticIntegration" ReferencedContainer="container:SyntheticIntegration.xcodeproj"/>
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
        </Scheme>
        """
    )
    return SyntheticXcodeProject(
        root: root,
        project: project,
        source: source,
        scheme: "SyntheticIntegration"
    )
}
