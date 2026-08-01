//===--- CompilerASTReferenceParserTests.swift - SwiftDelta ------------------------------------------===//
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

final class CompilerASTReferenceParserTests: XCTestCase {
    func testNormalizedSourceAliasesAreDeduplicatedOrRejectedPrecisely()
        throws
    {
        let canonical = "/Synthetic/Target/File.swift"
        let alias = "/Synthetic/Target/./File.swift"
        let source = Data("let value = 1\n".utf8)
        let document = try JSONSerialization.data(
            withJSONObject: [
                "_kind": "source_file",
                "filename": canonical,
                "items": [],
            ],
            options: [.sortedKeys]
        )

        let result = try CompilerASTReferenceParser.parse(
            document,
            sources: [
                canonical: source,
                alias: source,
            ]
        )

        XCTAssertEqual(result.coverage.filesRequested, 1)
        XCTAssertEqual(result.coverage.filesAnalyzed, 1)
        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertThrowsError(
            try CompilerASTReferenceParser.parse(
                document,
                sources: [
                    canonical: source,
                    alias: Data("let other = 2\n".utf8),
                ]
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "normalize to \(canonical) with different contents"
                )
            )
        }
    }

    func testDeepCompilerASTUsesBoundedCallStack() throws {
        let path = "/Synthetic/Target/Deep.swift"
        let depth = 4_096
        let document =
            #"{"_kind":"source_file","filename":""#
            + path
            + #"","items":"#
            + String(repeating: "[", count: depth)
            + #"{"_kind":"import_decl","module_path":["FictionalDeepSDK"]}"#
            + String(repeating: "]", count: depth)
            + "}"

        let result = try CompilerASTReferenceParser.parse(
            Data(document.utf8),
            sources: [path: Data("import FictionalDeepSDK\n".utf8)]
        )

        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesAnalyzed, 1)
        XCTAssertEqual(result.importedModules, ["FictionalDeepSDK"])
    }

    func testPartialDocumentsCannotClaimCompleteCoverage() throws {
        let sources = Dictionary(
            uniqueKeysWithValues: (0..<66).map {
                ("/Synthetic/Target/File\($0).swift", Data("let value\($0) = \($0)\n".utf8))
            }
        )
        var output = Data()
        for index in 0..<40 {
            let document: [String: Any] = [
                "_kind": "source_file",
                "filename": "/Synthetic/Target/File\(index).swift",
                "items": [],
            ]
            output.append(
                try JSONSerialization.data(
                    withJSONObject: document,
                    options: [.sortedKeys]
                )
            )
            output.append(0x0A)
        }

        let result = try CompilerASTReferenceParser.parse(
            output,
            sources: sources
        )

        XCTAssertEqual(result.coverage.filesRequested, 66)
        XCTAssertEqual(result.coverage.filesAnalyzed, 40)
        XCTAssertEqual(result.coverage.filesWithoutSDKReferences, 40)
        XCTAssertEqual(result.coverage.filesFailed, 26)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertEqual(
            result.coverage.sourceFiles.count {
                $0.disposition == .missingCompilerOutput
            },
            26
        )
    }

    func testDuplicateAndUnknownDocumentsAreRejectedWithoutFallbackAttribution() throws {
        let path = "/Synthetic/Target/File.swift"
        let source = Data("let value = 1\n".utf8)
        let known: [String: Any] = [
            "_kind": "source_file",
            "filename": path,
            "items": [],
        ]
        let unknown: [String: Any] = [
            "_kind": "source_file",
            "filename": "/Synthetic/Other/File.swift",
            "items": [],
        ]
        var output = Data()
        for document in [known, known, unknown] {
            output.append(
                try JSONSerialization.data(
                    withJSONObject: document,
                    options: [.sortedKeys]
                )
            )
        }

        let result = try CompilerASTReferenceParser.parse(
            output,
            sources: [path: source]
        )

        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesAnalyzed, 0)
        XCTAssertEqual(result.coverage.filesFailed, 1)
        XCTAssertTrue(
            result.failures.contains {
                $0.message.contains("duplicate AST documents")
            }
        )
        XCTAssertTrue(
            result.failures.contains {
                $0.message.contains("unrequested source path")
            }
        )
    }

    func testAuxiliaryStructuredRecordsDoNotReduceASTCoverage() throws {
        let path = "/Synthetic/Target/File.swift"
        let source = Data("let value = 1\n".utf8)
        let auxiliary: [String: Any] = [
            "_kind": "diagnostic_metadata",
            "compiler": "synthetic",
        ]
        let document: [String: Any] = [
            "_kind": "source_file",
            "filename": path,
            "items": [],
        ]
        var output = try JSONSerialization.data(
            withJSONObject: auxiliary,
            options: [.sortedKeys]
        )
        output.append(0x0A)
        output.append(
            try JSONSerialization.data(
                withJSONObject: document,
                options: [.sortedKeys]
            )
        )

        let result = try CompilerASTReferenceParser.parse(
            output,
            sources: [path: source]
        )

        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesAnalyzed, 1)
        XCTAssertEqual(result.coverage.filesFailed, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testDiagnosticClosureBracesCannotConsumeFollowingASTDocuments() throws {
        let firstPath = "/Synthetic/Target/First.swift"
        let secondPath = "/Synthetic/Target/Second.swift"
        let first = try JSONSerialization.data(
            withJSONObject: [
                "_kind": "source_file",
                "filename": firstPath,
                "items": [],
            ],
            options: [.sortedKeys]
        )
        let second = try JSONSerialization.data(
            withJSONObject: [
                "_kind": "source_file",
                "filename": secondPath,
                "items": [],
            ],
            options: [.sortedKeys]
        )
        var output = first
        output.append(
            Data(
                """
                /Synthetic/Target/First.swift:1:1: warning: example
                1 | value.onChange { value in
                  |                `- warning: example
                """.utf8
            )
        )
        output.append(second)

        let result = try CompilerASTReferenceParser.parse(
            output,
            sources: [
                firstPath: Data("let first = 1\n".utf8),
                secondPath: Data("let second = 2\n".utf8),
            ]
        )

        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesAnalyzed, 2)
        XCTAssertEqual(result.coverage.filesFailed, 0)
        XCTAssertTrue(result.failures.isEmpty)
    }

    func testNonzeroCompilerExitKeepsPartialEvidenceExplicitlyIncomplete() throws {
        let directory = try TestDirectory(name: "partial-compiler-exit")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let source = try directory.write(
            "Project/Sources/File.swift",
            "import FictionalSDK\nlet value = fictionalValue\n"
        )
        let document: [String: Any] = [
            "_kind": "source_file",
            "filename": source.path,
            "items": [
                [
                    "_kind": "import_decl",
                    "module_path": ["FictionalSDK"],
                ],
            ],
        ]
        let ast = try JSONSerialization.data(
            withJSONObject: document,
            options: [.sortedKeys]
        )
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcrun",
               call.arguments == ["--find", "swiftc"]
            {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("/Synthetic/swiftc\n".utf8),
                    standardError: Data()
                )
            }
            if call.executable == "/Synthetic/swiftc" {
                return ProcessResult(
                    exitStatus: 1,
                    standardOutput: ast,
                    standardError: Data(
                        "\(source.path):1:1: error: fictional type-check failure\n".utf8
                    )
                )
            }
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        let context = TargetBuildContext(
            toolchainRole: "candidate",
            xcodeApplicationPath: xcode.path,
            sdkIdentifier: "macosx",
            sdkPath: "/Synthetic/Fictional.sdk",
            platform: "macosx",
            target: "FictionalTarget",
            moduleName: "FictionalTarget",
            architecture: "arm64",
            deploymentTarget: "13.0",
            sourceFiles: [source.path],
            compilerArguments: [
                "-typecheck",
                "-dump-ast",
                "-dump-ast-format", "json",
                source.path,
            ],
            evidenceSource: .exactCompilerInvocation,
            isAuthoritative: true
        )

        let result = try CompilerReferenceResolver(runner: runner).resolve(
            CompilerReferenceRequest(
                buildContext: context,
                projectRoot: source.deletingLastPathComponent()
                    .deletingLastPathComponent(),
                timeoutPerFile: 60
            )
        )

        XCTAssertEqual(result.coverage.compilerExitStatus, 1)
        XCTAssertEqual(result.coverage.filesAnalyzed, 1)
        XCTAssertFalse(result.coverage.isComplete)
        XCTAssertTrue(
            result.failures.contains {
                $0.message.contains("partial reference evidence")
            }
        )
    }

    func testMissingDocumentRetriesOnePrimaryFileWithFullTargetContext() throws {
        let directory = try TestDirectory(name: "compiler-document-retry")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let first = try directory.write(
            "Project/Sources/First.swift",
            "struct First {}\n"
        )
        let second = try directory.write(
            "Project/Sources/Second.swift",
            "struct Second { let first: First }\n"
        )
        let ast: @Sendable (String) throws -> Data = { path in
            try JSONSerialization.data(
                withJSONObject: [
                    "_kind": "source_file",
                    "filename": path,
                    "items": [],
                ],
                options: [.sortedKeys]
            )
        }
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcrun",
               call.arguments == ["--find", "swiftc"]
            {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("/Synthetic/swiftc\n".utf8),
                    standardError: Data()
                )
            }
            if call.executable == "/Synthetic/swiftc" {
                let path = call.arguments.contains("-primary-file")
                    ? second.path
                    : first.path
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: try ast(path),
                    standardError: Data()
                )
            }
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        let context = TargetBuildContext(
            toolchainRole: "candidate",
            xcodeApplicationPath: xcode.path,
            sdkIdentifier: "macosx",
            sdkPath: "/Synthetic/MacOSX27.sdk",
            platform: "macosx",
            target: "FictionalTarget",
            moduleName: "FictionalTarget",
            architecture: "arm64",
            deploymentTarget: "13.0",
            sourceFiles: [first.path, second.path],
            compilerArguments: [],
            evidenceSource: .xcodeBuild,
            isAuthoritative: true
        )

        let result = try CompilerReferenceResolver(runner: runner).resolve(
            CompilerReferenceRequest(
                buildContext: context,
                projectRoot: first.deletingLastPathComponent()
                    .deletingLastPathComponent(),
                timeoutPerFile: 60
            )
        )

        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesRequested, 2)
        XCTAssertEqual(result.coverage.filesAnalyzed, 2)
        XCTAssertEqual(result.coverage.filesWithoutSDKReferences, 2)
        XCTAssertTrue(result.failures.isEmpty)
        let retry = try XCTUnwrap(
            runner.calls.first {
                $0.executable == "/Synthetic/swiftc"
                    && $0.arguments.contains("-primary-file")
            }
        )
        XCTAssertTrue(retry.arguments.contains(first.path))
        XCTAssertTrue(retry.arguments.contains(second.path))
        XCTAssertTrue(retry.arguments.contains("arm64-apple-macosx13.0"))
    }

    func testSixtySixRequestedFilesRecoverAllMissingCompilerDocuments() throws {
        let directory = try TestDirectory(name: "compiler-document-retry-corpus")
        let xcode = try makeSyntheticXcode(in: directory, name: "Candidate")
        let sourceFiles = try (0..<66).map { index in
            try directory.write(
                "Project/Sources/File\(index).swift",
                "struct Value\(index) {}\n"
            )
        }
        let ast: @Sendable (String) throws -> Data = { path in
            try JSONSerialization.data(
                withJSONObject: [
                    "_kind": "source_file",
                    "filename": path,
                    "items": [],
                ],
                options: [.sortedKeys]
            )
        }
        var initialOutput = Data()
        for file in sourceFiles.prefix(40) {
            initialOutput.append(try ast(file.path))
            initialOutput.append(0x0A)
        }
        let initialAST = initialOutput
        let runner = StubProcessRunner { call in
            if call.executable == "/usr/bin/xcrun",
               call.arguments == ["--find", "swiftc"]
            {
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: Data("/Synthetic/swiftc\n".utf8),
                    standardError: Data()
                )
            }
            if call.executable == "/Synthetic/swiftc" {
                if let primaryIndex = call.arguments.firstIndex(of: "-primary-file"),
                   call.arguments.indices.contains(primaryIndex + 1)
                {
                    return ProcessResult(
                        exitStatus: 0,
                        standardOutput: try ast(call.arguments[primaryIndex + 1]),
                        standardError: Data()
                    )
                }
                return ProcessResult(
                    exitStatus: 0,
                    standardOutput: initialAST,
                    standardError: Data()
                )
            }
            return ProcessResult(
                exitStatus: 1,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        let context = TargetBuildContext(
            toolchainRole: "candidate",
            xcodeApplicationPath: xcode.path,
            sdkIdentifier: "macosx",
            sdkPath: "/Synthetic/MacOSX27.sdk",
            platform: "macosx",
            target: "FictionalTarget",
            moduleName: "FictionalTarget",
            architecture: "arm64",
            deploymentTarget: "13.0",
            sourceFiles: sourceFiles.map(\.path),
            compilerArguments: [],
            evidenceSource: .xcodeBuild,
            isAuthoritative: true
        )

        let result = try CompilerReferenceResolver(runner: runner).resolve(
            CompilerReferenceRequest(
                buildContext: context,
                projectRoot: directory.url.appendingPathComponent("Project"),
                timeoutPerFile: 60
            )
        )

        XCTAssertTrue(result.coverage.isComplete)
        XCTAssertEqual(result.coverage.filesRequested, 66)
        XCTAssertEqual(result.coverage.filesAnalyzed, 66)
        XCTAssertEqual(result.coverage.filesWithoutSDKReferences, 66)
        XCTAssertEqual(result.coverage.filesFailed, 0)
        XCTAssertEqual(
            runner.calls.count {
                $0.executable == "/Synthetic/swiftc"
                    && $0.arguments.contains("-primary-file")
            },
            26
        )
    }

    func testCompilerASTParserUsesUSRLocationsAndOnlyActiveCompilerImports() throws {
        let source = Data(
            """
            import FictionalSDK
            func exercise() {
                FictionalSDKCall()
            }
            """.utf8
        )
        let sourceText = String(decoding: source, as: UTF8.self)
        let callRange = try XCTUnwrap(sourceText.range(of: "FictionalSDKCall"))
        let callOffset = sourceText.utf8.distance(
            from: sourceText.utf8.startIndex,
            to: callRange.lowerBound.samePosition(in: sourceText.utf8)!
        )
        let object: [String: Any] = [
            "_kind": "source_file",
            "filename": "/Synthetic/Fixture.swift",
            "items": [
                [
                    "_kind": "import_decl",
                    "module_path": ["FictionalSDK"],
                ],
                [
                    "_kind": "declref_expr",
                    "range": ["start": callOffset, "end": callOffset + 10],
                    "decl": [
                        "_kind": "decl_ref",
                        "decl_usr": "usr.fictional.call",
                    ],
                ],
                [
                    "_kind": "declref_expr",
                    "range": ["start": callOffset, "end": callOffset + 10],
                    "decl": [
                        "_kind": "decl_ref",
                    ],
                ],
            ],
        ]
        let ast = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let result = try CompilerASTReferenceParser.parse(
            ast,
            source: source,
            fallbackPath: "/Synthetic/Fallback.swift"
        )

        XCTAssertEqual(result.importedModules, ["FictionalSDK"])
        XCTAssertEqual(result.references.count, 1)
        XCTAssertEqual(result.references[0].preciseIdentifier, "usr.fictional.call")
        XCTAssertEqual(result.references[0].resolutionMethod, .compilerUSR)
        XCTAssertEqual(result.references[0].sourceLocation.path, "/Synthetic/Fixture.swift")
        XCTAssertEqual(result.references[0].sourceLocation.line, 3)
        XCTAssertEqual(result.coverage.declarationReferences, 2)
        XCTAssertEqual(result.coverage.stableIdentityReferences, 1)
        XCTAssertEqual(result.coverage.unresolvedReferences, 1)
        XCTAssertEqual(
            result.coverage.unresolvedReasons[
                "compiler AST declaration reference omitted a stable symbol identity"
            ],
            1
        )
    }

    func testCompilerDirectIdentityRecoveryAndUnresolvedReasonsAreCategorized() throws {
        let source = Data("func exercise() {}\n".utf8)
        let object: [String: Any] = [
            "_kind": "source_file",
            "filename": "/Synthetic/Fixture.swift",
            "items": [
                [
                    "_kind": "declref_expr",
                    "decl_usr": "usr.fictional.direct",
                    "range": ["start": 0, "end": 4],
                ],
                [
                    "_kind": "declref_expr",
                    "type": "<error type>",
                    "range": ["start": 5, "end": 13],
                ],
            ],
        ]
        let ast = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )

        let result = try CompilerASTReferenceParser.parse(
            ast,
            source: source,
            fallbackPath: "/Synthetic/Fallback.swift"
        )

        XCTAssertEqual(result.coverage.declarationReferences, 2)
        XCTAssertEqual(result.coverage.stableIdentityReferences, 1)
        XCTAssertEqual(result.coverage.unresolvedReferences, 1)
        XCTAssertEqual(
            result.coverage.unresolvedReasons[
                "compiler recovery reference had no stable symbol identity"
            ],
            1
        )
    }
}
