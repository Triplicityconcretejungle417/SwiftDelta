//===--- RepresentativeReferenceCoverageTests.swift - SwiftDelta ------------------------------------------===//
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

final class RepresentativeReferenceCoverageTests: XCTestCase {
    func testRepresentativeMultiFileCorpusImprovesStableIdentityRecovery()
        throws
    {
        let xcode = try selectedXcodeApplication()
        let directory = try TestDirectory(name: "reference-corpus")
        let shared = try directory.write(
            "Sources/Shared.swift",
            """
            import Foundation

            @propertyWrapper
            struct Stored<Value> {
                var wrappedValue: Value
            }

            @resultBuilder
            enum FictionalBuilder {
                static func buildBlock(_ values: Int...) -> [Int] { values }
            }

            struct Box<Value> {
                var values: [Value]
                subscript(index: Int) -> Value { values[index] }
                func map<Result>(_ transform: (Value) -> Result) -> [Result] {
                    values.map(transform)
                }
            }

            func choose(_ value: Int) -> Int { value }
            func choose(_ value: String) -> Int { value.count }
            """
        )
        var files = [shared]
        for index in 0..<16 {
            files.append(
                try directory.write(
                    "Sources/Feature\(index).swift",
                    """
                    import Foundation

                    struct Feature\(index) {
                        @Stored var count = \(index)

                        @FictionalBuilder
                        func generatedValues() -> [Int] {
                            count
                            choose(count)
                        }

                        func execute(box: Box<Int>) -> Int {
                            let object = NSObject()
                            let text = NSString(string: "\\(object)")
                            let url = URL(fileURLWithPath: text as String)
                            let mapped = box.map { $0 + count }
                            let selected = box[0]
                            #if SYNTHETIC_ACTIVE
                            let conditional = Date().description.count
                            #else
                            let conditional = 0
                            #endif
                            return mapped.reduce(selected, +)
                                + url.path.count
                                + conditional
                                + #fileID.count
                        }
                    }
                    """
                )
            )
        }

        let runner = ASTCapturingRunner()
        let result = try CompilerReferenceResolver(runner: runner).resolve(
            CompilerReferenceRequest(
                files: files,
                projectRoot: directory.url,
                xcodeApplicationPath: xcode,
                sdkIdentifier: "macosx",
                activeCompilationConditions: ["SYNTHETIC_ACTIVE"],
                timeoutPerFile: 180
            )
        )
        let legacy = legacyReferenceCounts(in: try XCTUnwrap(runner.ast))

        let failureContext = (
            result.failures.map(\.message)
                + result.diagnostics.map(\.message)
        ).joined(separator: "\n")
        XCTAssertEqual(result.coverage.filesRequested, 17)
        XCTAssertEqual(
            result.coverage.filesAnalyzed,
            17,
            failureContext
        )
        XCTAssertEqual(result.coverage.filesFailed, 0)
        XCTAssertGreaterThan(result.coverage.stableIdentityReferences, 100)
        XCTAssertLessThan(
            result.coverage.unresolvedReferences,
            legacy.unresolved
        )
        let legacyRate = Double(legacy.stable)
            / Double(legacy.stable + legacy.unresolved)
        let currentRate = Double(result.coverage.stableIdentityReferences)
            / Double(
                result.coverage.stableIdentityReferences
                    + result.coverage.unresolvedReferences
            )
        XCTAssertGreaterThan(currentRate, legacyRate)
        XCTAssertTrue(result.importedModules.contains("Foundation"))
        XCTAssertTrue(
            result.references.allSatisfy {
                $0.resolutionMethod == .compilerUSR
                    && $0.preciseIdentifier?.isEmpty == false
            }
        )
        print(
            "REFERENCE_COVERAGE_BENCHMARK "
                + "files=17 "
                + "legacyStable=\(legacy.stable) "
                + "legacyUnresolved=\(legacy.unresolved) "
                + "currentStable=\(result.coverage.stableIdentityReferences) "
                + "currentUnresolved=\(result.coverage.unresolvedReferences) "
                + "legacyRate=\(legacyRate) currentRate=\(currentRate)"
        )
    }

    private func selectedXcodeApplication() throws -> String {
        let xcode = try selectedRealToolchains().candidate
        _ = try XcodeInstallation.validate(applicationPath: xcode)
        return xcode
    }

    private func legacyReferenceCounts(
        in data: Data
    ) -> (stable: Int, unresolved: Int) {
        var stable = 0
        var unresolved = 0
        for document in splitJSONDocuments(data) {
            guard let root = try? JSONSerialization.jsonObject(with: document)
            else {
                continue
            }
            walkLegacy(root, stable: &stable, unresolved: &unresolved)
        }
        return (stable, unresolved)
    }

    private func walkLegacy(
        _ value: Any,
        stable: inout Int,
        unresolved: inout Int
    ) {
        if let dictionary = value as? [String: Any] {
            if dictionary["_kind"] as? String == "declref_expr" {
                let declaration = dictionary["decl"] as? [String: Any]
                let identity = (declaration?["decl_usr"] as? String)
                    ?? (dictionary["decl_usr"] as? String)
                if identity?.isEmpty == false {
                    stable += 1
                } else {
                    unresolved += 1
                }
            }
            for child in dictionary.values {
                walkLegacy(child, stable: &stable, unresolved: &unresolved)
            }
        } else if let array = value as? [Any] {
            for child in array {
                walkLegacy(child, stable: &stable, unresolved: &unresolved)
            }
        }
    }

    private func splitJSONDocuments(_ data: Data) -> [Data] {
        var documents: [Data] = []
        var start: Int?
        var depth = 0
        var insideString = false
        var escaped = false
        for (index, byte) in data.enumerated() {
            if insideString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    insideString = false
                }
                continue
            }
            if byte == 0x22 {
                insideString = true
            } else if byte == 0x7B {
                if depth == 0 {
                    start = index
                }
                depth += 1
            } else if byte == 0x7D, depth > 0 {
                depth -= 1
                if depth == 0, let documentStart = start {
                    documents.append(
                        data.subdata(in: documentStart..<(index + 1))
                    )
                    start = nil
                }
            }
        }
        return documents
    }
}

private final class ASTCapturingRunner:
    ProcessRunning,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let underlying = ProcessRunner()
    private var storedAST: Data?

    var ast: Data? {
        lock.withLock { storedAST }
    }

    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ProcessResult {
        let result = try underlying.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: timeout,
            cancellation: cancellation
        )
        if arguments.contains("-dump-ast-format") {
            lock.withLock {
                storedAST = result.standardOutput.isEmpty
                    ? result.standardError
                    : result.standardOutput
            }
        }
        return result
    }
}
