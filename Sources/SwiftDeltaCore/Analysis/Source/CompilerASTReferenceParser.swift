//===--- CompilerASTReferenceParser.swift - SwiftDelta ------------------------------------------===//
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

public enum CompilerASTReferenceParser {
    public static func parse(
        _ data: Data,
        source: Data,
        fallbackPath: String
    ) throws -> CompilerReferenceResolutionResult {
        try parseDocuments(
            data,
            sources: [fallbackPath: source],
            singleSourceCompatibility: source
        )
    }

    public static func parse(
        _ data: Data,
        sources: [String: Data],
        fallbackPath: String
    ) throws -> CompilerReferenceResolutionResult {
        try parseDocuments(data, sources: sources, singleSourceCompatibility: nil)
    }

    /// Decodes compiler documents only when each document identifies an exact
    /// requested source path. Missing and duplicate documents remain visible in
    /// coverage instead of being attributed to an arbitrary fallback file.
    public static func parse(
        _ data: Data,
        sources: [String: Data]
    ) throws -> CompilerReferenceResolutionResult {
        try parseDocuments(data, sources: sources, singleSourceCompatibility: nil)
    }

    private static func parseDocuments(
        _ data: Data,
        sources: [String: Data],
        singleSourceCompatibility: Data?
    ) throws -> CompilerReferenceResolutionResult {
        let documents = splitJSONDocuments(data)
        guard !documents.isEmpty else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "compilerAST",
                reason: "the compiler AST did not contain a JSON document"
            )
        }
        var references: [SDKSymbolReference] = []
        var modules = Set<String>()
        var modulesBySource: [String: [String]] = [:]
        var metricsBySource: [String: CompilerReferenceFileMetrics] = [:]
        var declarationReferences = 0
        var unresolvedReferences = 0
        var unresolvedReasons: [String: Int] = [:]
        var failures: [AnalysisFailure] = []
        var documentPaths = Set<String>()
        var records: [String: SourceAnalysisRecord] = [:]
        var normalizedSources: [String: Data] = [:]
        for (path, source) in sources.sorted(by: { $0.key < $1.key }) {
            let normalized = normalizedPath(path)
            if let existing = normalizedSources[normalized] {
                guard existing == source else {
                    throw SwiftDeltaError.invalidConfiguration(
                        field: "compilerAST",
                        reason:
                            "multiple requested source paths normalize to "
                            + "\(normalized) with different contents"
                    )
                }
                continue
            }
            normalizedSources[normalized] = source
        }
        for document in documents {
            guard let root = try? CompilerASTDocumentScanner.scan(document) else {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "The compiler emitted a malformed AST JSON document.",
                        location: nil
                    )
                )
                continue
            }
            // Newer drivers can interleave structured auxiliary records with
            // the requested AST stream. Only source-file records participate
            // in coverage; an auxiliary JSON record is not a missing source
            // document. A source-file record without a filename is still
            // malformed and remains an explicit failure below.
            guard root.kind == "source_file" else {
                continue
            }
            guard let emittedPath = root.filename,
                  !emittedPath.isEmpty
            else {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "The compiler AST document did not identify its source file.",
                        location: nil
                    )
                )
                continue
            }
            let filePath = normalizedPath(emittedPath)
            let source: Data
            if let exact = normalizedSources[filePath] {
                source = exact
            } else if let singleSourceCompatibility {
                // This branch preserves the original single-document parser API
                // used by clients that supply the source bytes separately. The
                // multi-file production path never uses it.
                source = singleSourceCompatibility
            } else {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message:
                            "The compiler emitted an AST document for an unrequested "
                            + "source path: \(emittedPath)",
                        location: SourceLocation(path: emittedPath)
                    )
                )
                continue
            }
            guard documentPaths.insert(filePath).inserted else {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message:
                            "The compiler emitted duplicate AST documents for "
                            + "\(emittedPath).",
                        location: SourceLocation(path: emittedPath)
                    )
                )
                records[filePath] = SourceAnalysisRecord(
                    path: filePath,
                    disposition: .failed,
                    reason: "duplicate compiler AST documents"
                )
                continue
            }
            let referenceCountBefore = references.count
            let declarationCountBefore = declarationReferences
            let unresolvedCountBefore = unresolvedReferences
            let reasonsBefore = unresolvedReasons
            let documentModules = Set(root.importedModules)
            for expression in root.references {
                declarationReferences += 1
                if expression.stableIdentities.count == 1,
                   let preciseIdentifier = expression.stableIdentities.first
                {
                    references.append(
                        SDKSymbolReference(
                            preciseIdentifier: preciseIdentifier,
                            sourceLocation: location(
                                byteOffset: expression.byteOffset,
                                source: source,
                                path: filePath
                            ),
                            resolutionMethod: .compilerUSR
                        )
                    )
                } else if expression.stableIdentities.count > 1 {
                    unresolvedReferences += 1
                    unresolvedReasons[
                        "compiler retained an ambiguous overload set",
                        default: 0
                    ] += 1
                } else {
                    unresolvedReferences += 1
                    let reason: String
                    if expression.type?.contains("<error") == true
                        || expression.type?.contains("<<error") == true
                    {
                        reason =
                            "compiler recovery reference had no stable symbol identity"
                    } else if expression.declarationUSRWasEmpty {
                        reason =
                            "project-local declaration reference had no exported stable identity"
                    } else if !expression.hasDeclaration {
                        reason =
                            "compiler AST declaration reference omitted declaration metadata"
                    } else {
                        reason =
                            "compiler AST declaration reference omitted a stable symbol identity"
                    }
                    unresolvedReasons[reason, default: 0] += 1
                }
            }
            modules.formUnion(documentModules)
            modulesBySource[filePath] = documentModules.sorted()
            let reasonDelta = unresolvedReasons.reduce(
                into: [String: Int]()
            ) { result, entry in
                let delta = entry.value - (reasonsBefore[entry.key] ?? 0)
                if delta > 0 {
                    result[entry.key] = delta
                }
            }
            metricsBySource[filePath] = CompilerReferenceFileMetrics(
                declarationReferences:
                    declarationReferences - declarationCountBefore,
                stableIdentityReferences:
                    references.count - referenceCountBefore,
                unresolvedReferences:
                    unresolvedReferences - unresolvedCountBefore,
                unresolvedReasons: reasonDelta
            )
            records[filePath] = SourceAnalysisRecord(
                path: filePath,
                disposition: references.count == referenceCountBefore
                    ? .analyzedWithoutSDKReferences
                    : .analyzedWithSDKReferences
            )
        }
        guard !documentPaths.isEmpty else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "compilerAST",
                reason: "the compiler AST JSON documents were malformed"
            )
        }
        for requestedPath in normalizedSources.keys.sorted()
            where records[requestedPath] == nil
        {
            records[requestedPath] = SourceAnalysisRecord(
                path: requestedPath,
                disposition: .missingCompilerOutput,
                reason: "the compiler emitted no AST document for this requested source"
            )
            failures.append(
                AnalysisFailure(
                    kind: .parse,
                    message:
                        "The compiler emitted no AST document for requested source "
                        + "\(requestedPath).",
                    location: SourceLocation(path: requestedPath)
                )
            )
        }
        let sourceRecords = records.values.sorted { $0.path < $1.path }
        let successfullyAnalyzed = sourceRecords.count { $0.disposition.isSuccessful }
        let filesWithoutReferences = sourceRecords.count {
            $0.disposition == .analyzedWithoutSDKReferences
        }
        let filesFailed = sourceRecords.count {
            !$0.disposition.isSuccessful
        }
        return CompilerReferenceResolutionResult(
            references: references,
            importedModules: modules.sorted(),
            failures: failures,
            coverage: ReferenceResolutionCoverage(
                sdkIdentifier: "",
                filesRequested: normalizedSources.count,
                filesAnalyzed: successfullyAnalyzed,
                filesWithoutSDKReferences: filesWithoutReferences,
                filesFailed: filesFailed,
                declarationReferences: declarationReferences,
                stableIdentityReferences: references.count,
                unresolvedReferences: unresolvedReferences,
                unresolvedReasons: unresolvedReasons,
                isComplete: failures.isEmpty
                    && successfullyAnalyzed == normalizedSources.count,
                sourceFiles: sourceRecords
            ),
            importedModulesBySource: modulesBySource,
            metricsBySource: metricsBySource
        )
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).canonicalPath
    }

    private static func splitJSONDocuments(_ data: Data) -> [Data] {
        var documents: [Data] = []
        var searchIndex = data.startIndex
        while searchIndex < data.endIndex {
            guard let documentStart = nextStructuredDocumentStart(
                in: data,
                from: searchIndex
            ) else {
                break
            }
            var index = documentStart
            var depth = 0
            var insideString = false
            var escaped = false
            var documentEnd: Data.Index?
            while index < data.endIndex {
                let byte = data[index]
                if insideString {
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        insideString = false
                    }
                } else if byte == 0x22 {
                    insideString = true
                } else if byte == 0x7B {
                    depth += 1
                } else if byte == 0x7D {
                    depth -= 1
                    if depth == 0 {
                        documentEnd = data.index(after: index)
                        break
                    }
                }
                index = data.index(after: index)
            }
            guard let documentEnd else {
                break
            }
            documents.append(data.subdata(in: documentStart..<documentEnd))
            searchIndex = documentEnd
        }
        return documents
    }

    /// AST JSON shares stderr with source-rendered diagnostics. A closure such
    /// as `{ value in` is not a document boundary and may be unmatched in the
    /// rendered excerpt, so framing begins only at a structured compiler root.
    private static func nextStructuredDocumentStart(
        in data: Data,
        from start: Data.Index
    ) -> Data.Index? {
        let kindKey: [UInt8] = [
            0x22, 0x5F, 0x6B, 0x69, 0x6E, 0x64, 0x22,
        ]
        var index = start
        while index < data.endIndex {
            guard data[index] == 0x7B else {
                index = data.index(after: index)
                continue
            }
            var keyIndex = data.index(after: index)
            while keyIndex < data.endIndex,
                  data[keyIndex] == 0x20
                    || data[keyIndex] == 0x09
                    || data[keyIndex] == 0x0A
                    || data[keyIndex] == 0x0D
            {
                keyIndex = data.index(after: keyIndex)
            }
            guard data.distance(from: keyIndex, to: data.endIndex)
                    >= kindKey.count
            else {
                return nil
            }
            let keyEnd = data.index(keyIndex, offsetBy: kindKey.count)
            if data[keyIndex..<keyEnd].elementsEqual(kindKey) {
                return index
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func location(
        byteOffset: Int,
        source: Data,
        path: String
    ) -> SourceLocation {
        let safeOffset = max(0, min(byteOffset, source.count))
        let prefix = source.prefix(safeOffset)
        var line = 1
        var lineStart = 0
        for (index, byte) in prefix.enumerated() where byte == 0x0A {
            line += 1
            lineStart = index + 1
        }
        let columnData = prefix.dropFirst(lineStart)
        let column = String(decoding: columnData, as: UTF8.self).count + 1
        return SourceLocation(path: path, line: line, column: column)
    }
}
