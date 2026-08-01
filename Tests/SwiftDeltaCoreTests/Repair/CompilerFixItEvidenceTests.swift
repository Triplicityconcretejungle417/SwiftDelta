//===--- CompilerFixItEvidenceTests.swift - SwiftDelta ------------------------------------------===//
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

final class CompilerFixItEvidenceTests: XCTestCase {
    func testSwiftAndClangStructuredFixItsProduceAuditableRepairs() throws {
        let directory = try TestDirectory(name: "fixit-evidence")
        defer { directory.remove() }
        let swift = try directory.write(
            "Sources/App.swift",
            "func use(value: Int) {}\nuse(vlaue: 1)\n"
        )
        let c = try directory.write("Sources/main.c", "int main(void) { return 0 }\n")
        let swiftData = try Data(contentsOf: swift)
        let cData = try Data(contentsOf: c)
        let swiftOffset = try XCTUnwrap(
            swiftData.range(of: Data("vlaue".utf8))
        ).lowerBound
        let cOffset = try XCTUnwrap(cData.firstIndex(of: 0x7D))
        let fixIts = [
            StructuredDiagnosticFixIt(
                filePath: swift.path,
                sourceRange: RepairSourceRange(
                    start: sourcePosition(swiftOffset, in: swiftData),
                    end: sourcePosition(
                        swiftOffset + "vlaue".utf8.count,
                        in: swiftData
                    )
                ),
                replacementText: "value",
                diagnosticText: "incorrect argument label",
                diagnosticSeverity: .error,
                diagnosticIndex: 0,
                fixItIndex: 0,
                compilerContext: targetAwareEvidence(
                    compiler: "swift-frontend"
                )
            ),
            StructuredDiagnosticFixIt(
                filePath: c.path,
                sourceRange: RepairSourceRange(
                    start: sourcePosition(cOffset, in: cData),
                    end: sourcePosition(cOffset, in: cData)
                ),
                replacementText: ";",
                diagnosticText: "expected ';' after return statement",
                diagnosticSeverity: .error,
                diagnosticIndex: 0,
                fixItIndex: 0,
                compilerContext: targetAwareEvidence(compiler: "clang")
            ),
        ]

        let result = CompilerFixItRepairBuilder.build(
            fixIts: fixIts,
            projectRoot: directory.url
        )

        XCTAssertTrue(result.1.isEmpty)
        XCTAssertEqual(result.0.count, 2)
        XCTAssertEqual(
            Set(result.0.map(\.evidenceSource)),
            [.swiftCompilerFixIt, .clangCompilerFixIt]
        )
        XCTAssertTrue(
            result.0.allSatisfy { $0.safety == .safe },
            result.0.map { "\($0.originalText)->\($0.replacementText):\($0.safety)" }
                .joined(separator: ", ")
        )
    }

    func testRealSelectedToolchainDecodesSwiftAndClangFixItsWhenConfigured()
        throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard let candidate = environment["SWIFTDELTA_CANDIDATE_XCODE"],
              FileManager.default.fileExists(atPath: candidate)
        else {
            throw XCTSkip("SWIFTDELTA_CANDIDATE_XCODE is not configured")
        }
        let directory = try TestDirectory(name: "real-fixit-evidence")
        defer { directory.remove() }
        let swift = try directory.write(
            "Sources/App.swift",
            "func use(value: Int) {}\nfunc run() { use(vlaue: 1) }\n"
        )
        let c = try directory.write(
            "Sources/main.c",
            "int main(void) { return 0 }\n"
        )

        let extraction = try CompilerFixItExtractor().extract(
            CompilerFixItRequest(
                files: [swift, c],
                projectRoot: directory.url,
                candidateXcodePath: candidate,
                sdkIdentifier: "macosx"
            )
        )

        XCTAssertTrue(extraction.failures.isEmpty)
        guard !extraction.fixIts.isEmpty else {
            throw XCTSkip(
                "The selected local compiler produced readable serialized "
                    + "diagnostics but exposed no structured Swift or Clang "
                    + "Fix-its through its bundled libclang."
            )
        }
        let replacements = Set(extraction.fixIts.map(\.replacementText))
        XCTAssertTrue(replacements.contains("value"), "\(replacements)")
        XCTAssertTrue(replacements.contains(";"), "\(replacements)")
        XCTAssertTrue(
            extraction.fixIts.allSatisfy {
                !$0.filePath.isEmpty
                    && $0.sourceRange.start.utf8Offset
                        <= $0.sourceRange.end.utf8Offset
            }
        )
    }

    func testNativeHeadersAreRecognizedWithoutAssumingTheyAreAutomaticallySafe()
        throws
    {
        let directory = try TestDirectory(name: "header-fixit")
        defer { directory.remove() }
        let header = try directory.write(
            "Sources/SyntheticHeader.h",
            "int synthetic_value(void) { return 0 }\n"
        )
        let data = try Data(contentsOf: header)
        let insertion = try XCTUnwrap(data.firstIndex(of: 0x7D))
        let fixIt = StructuredDiagnosticFixIt(
            filePath: header.path,
            sourceRange: RepairSourceRange(
                start: sourcePosition(insertion, in: data),
                end: sourcePosition(insertion, in: data)
            ),
            replacementText: ";",
            diagnosticText: "expected ';' after return statement",
            diagnosticSeverity: .error,
            diagnosticIndex: 0,
            fixItIndex: 0
        )

        let repairs = CompilerFixItRepairBuilder.build(
            fixIts: [fixIt],
            projectRoot: directory.url
        ).0

        XCTAssertEqual(repairs.count, 1)
        XCTAssertEqual(repairs[0].language, .cOrObjectiveCHeader)
        XCTAssertEqual(repairs[0].evidenceSource, .clangCompilerFixIt)
        XCTAssertEqual(repairs[0].safety, .reviewRequired)
    }

    func testFixItDoesNotBindToAnUnrelatedSameLineFinding() throws {
        let directory = try TestDirectory(name: "fixit-finding-association")
        defer { directory.remove() }
        let file = try directory.write(
            "Sources/App.swift",
            "func use(value: Int) {}\nuse(vlaue: 1)\n"
        )
        let data = try Data(contentsOf: file)
        let offset = try XCTUnwrap(
            data.range(of: Data("vlaue".utf8))
        ).lowerBound
        let fixIt = StructuredDiagnosticFixIt(
            filePath: file.path,
            sourceRange: RepairSourceRange(
                start: sourcePosition(offset, in: data),
                end: sourcePosition(offset + 5, in: data)
            ),
            replacementText: "value",
            diagnosticText: "incorrect argument label",
            diagnosticSeverity: .error,
            diagnosticIndex: 0,
            fixItIndex: 0,
            compilerContext: targetAwareEvidence(
                compiler: "swift-frontend"
            )
        )
        let unrelated = Finding(
            findingID: "compiler.compiler.unrelated",
            category: .compiler,
            title: "Unrelated diagnostic",
            explanation: "a different compiler problem",
            severity: .error,
            confidence: .high,
            location: SourceLocation(
                path: file.path,
                line: 2,
                column: 1
            ),
            origin: .compiler,
            target: "FictionalTarget"
        )

        let repair = try XCTUnwrap(
            CompilerFixItRepairBuilder.build(
                fixIts: [fixIt],
                projectRoot: directory.url,
                analysisFindings: [unrelated]
            ).0.first
        )

        XCTAssertNotEqual(
            repair.relatedFindingIdentifier,
            unrelated.findingID
        )
    }

    private func targetAwareEvidence(
        compiler: String
    ) -> RepairCompilerContextEvidence {
        RepairCompilerContextEvidence(
            compilerPath: "/Synthetic/\(compiler)",
            target: "FictionalTarget",
            moduleName: "FictionalTarget",
            sdkIdentifier: "macosx",
            sdkPath: "/Synthetic/Fictional.sdk",
            diagnosticIdentity: "diagnostic.fictional",
            evidenceArtifact: "serializedDiagnostics",
            isTargetAware: true
        )
    }
}
