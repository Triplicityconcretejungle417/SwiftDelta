//===--- RobustnessPropertyTests.swift - SwiftDelta ------------------------------------------===//
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

final class RobustnessPropertyTests: XCTestCase {
    func testUTF8RangeValidationAcrossDeterministicMixedWidthCorpus() throws {
        let directory = try TestDirectory(name: "utf8-range-property")
        defer { directory.remove() }
        let source =
            "let ascii = 1\n"
            + "let café = \"e\u{301}\"\r\n"
            + "let 路径 = \"🙂👩🏽‍💻\"\n"
        let file = try directory.write("Sources/边界 File.swift", source)
        let document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        var validOffsets = Set<Int>()
        for index in source.indices {
            validOffsets.insert(
                source.utf8.distance(
                    from: source.utf8.startIndex,
                    to: index.samePosition(in: source.utf8)!
                )
            )
        }
        validOffsets.insert(source.utf8.count)

        for offset in 0...source.utf8.count {
            let position = RepairSourcePosition(
                line: 1,
                column: 1,
                utf8Offset: offset
            )
            let range = RepairSourceRange(start: position, end: position)
            if validOffsets.contains(offset) {
                XCTAssertEqual(try document.text(in: range), "")
            } else {
                XCTAssertThrowsError(try document.text(in: range))
            }
        }
    }

    func testLargeStructuredCorpusAndReportsRemainCompleteAndByteStable()
        throws
    {
        let parseStarted = Date()
        var sources: [String: Data] = [:]
        var output = Data()
        for fileIndex in 0..<200 {
            let path = "/Synthetic/Corpus/File \(fileIndex).swift"
            sources[path] = Data("let value = 1\n".utf8)
            let references: [[String: Any]] = (0..<10).map { referenceIndex in
                [
                    "_kind": "declref_expr",
                    "decl_usr":
                        "usr.synthetic.\(fileIndex).\(referenceIndex)",
                    "range": ["start": 0, "end": 3],
                ]
            }
            output.append(
                try JSONSerialization.data(
                    withJSONObject: [
                        "_kind": "source_file",
                        "filename": path,
                        "items": references,
                    ],
                    options: [.sortedKeys]
                )
            )
            output.append(0x0A)
        }
        let resolution = try CompilerASTReferenceParser.parse(
            output,
            sources: sources
        )
        let parseDuration = Date().timeIntervalSince(parseStarted)

        XCTAssertTrue(resolution.coverage.isComplete)
        XCTAssertEqual(resolution.coverage.filesRequested, 200)
        XCTAssertEqual(resolution.coverage.filesAnalyzed, 200)
        XCTAssertEqual(resolution.coverage.stableIdentityReferences, 2_000)
        XCTAssertEqual(resolution.coverage.unresolvedReferences, 0)

        let findings = (0..<1_000).map { index in
            Finding(
                findingID: "synthetic.finding.\(index)",
                category: .sdk,
                title: "Synthetic compatibility finding \(index)",
                explanation:
                    "A deterministic synthetic compatibility detail \(index).",
                severity: index.isMultiple(of: 7) ? .error : .warning,
                confidence: .high,
                location: SourceLocation(
                    path: "/Synthetic/Corpus/File \(index % 200).swift",
                    line: index % 40 + 1,
                    column: index % 12 + 1
                ),
                origin: .sdk
            )
        }
        let report = AnalysisReport(
            generatedAt: Date(timeIntervalSince1970: 1_000),
            projectRoot: "/Synthetic/Corpus",
            findings: findings
        )
        let reportStarted = Date()
        let firstJSON = try JSONReportRenderer.render(report)
        let secondJSON = try JSONReportRenderer.render(report)
        let firstSARIF = try SARIFReportRenderer.render(report)
        let secondSARIF = try SARIFReportRenderer.render(report)
        let reportDuration = Date().timeIntervalSince(reportStarted)

        XCTAssertEqual(firstJSON, secondJSON)
        XCTAssertEqual(firstSARIF, secondSARIF)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: firstJSON)
                as? [String: Any]
        )
        XCTAssertEqual((object["findings"] as? [Any])?.count, 1_000)
        print(
            "SYNTHETIC_STRESS "
                + "files=200 references=2000 findings=1000 "
                + "parseSeconds=\(parseDuration) "
                + "reportSeconds=\(reportDuration)"
        )
    }

    func testThreeHundredRepairCandidatesRemainOrderedAndConflictFree()
        throws
    {
        let directory = try TestDirectory(name: "repair-plan-stress")
        defer { directory.remove() }
        let names = (0..<300).map { "oldValue\($0)" }
        let source = names.map { "let \($0) = 0" }.joined(separator: "\n")
            + "\n"
        let file = try directory.write("Sources/Large.swift", source)
        let document = try RepairSourceDocument(
            root: directory.url,
            file: file
        )
        let repairs = try names.enumerated().map { index, name in
            try makeRepair(
                document: document,
                original: name,
                replacement: "newValue\(index)",
                identifier: "repair.stress.\(index)",
                finding: "finding.stress.\(index)"
            )
        }
        let started = Date()
        let plan = RepairPlanBuilder.build(
            projectRoot: directory.url,
            repairs: repairs,
            generatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let first = try RepairPlanJSON.encode(plan)
        let second = try RepairPlanJSON.encode(plan)
        let duration = Date().timeIntervalSince(started)

        XCTAssertEqual(plan.repairs.count, 300)
        XCTAssertTrue(plan.conflicts.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            plan.repairs.map(\.repairIdentifier),
            plan.repairs.map(\.repairIdentifier).sorted {
                let left = Int($0.split(separator: ".").last ?? "") ?? 0
                let right = Int($1.split(separator: ".").last ?? "") ?? 0
                return left < right
            }
        )
        print(
            "REPAIR_STRESS candidates=300 seconds=\(duration) "
                + "jsonBytes=\(first.count)"
        )
    }
}
