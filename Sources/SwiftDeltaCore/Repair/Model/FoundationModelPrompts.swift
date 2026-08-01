//===--- FoundationModelPrompts.swift - SwiftDelta ------------------------------------------===//
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

struct FoundationModelPromptDefinition: Hashable, Sendable {
    let generation: FoundationModelHostGeneration
    let instructions: String
    let maximumDeclarationBytes: Int

    static func select(
        for version: OperatingSystemVersion
    ) -> FoundationModelPromptDefinition? {
        guard let generation = FoundationModelHostGeneration.detect(version) else {
            return nil
        }
        return switch generation {
        case .macOS26_0To26_3:
            FoundationModelPromptDefinition(
                generation: generation,
                instructions:
                    "Migrate one exact SDK-backed source use. Return a concrete "
                    + "anchored source edit when the supplied candidate declaration "
                    + "establishes one; use reviewOnly when verification is still "
                    + "needed. Prefer compiler Fix-its and deterministic candidates. "
                    + "Use only APIs and signatures established by the supplied SDK "
                    + "or compiler evidence. Return notRepairable only when no source "
                    + "edit can be derived. Return only the guided fields.",
                maximumDeclarationBytes: 1_500
            )
        case .macOS26_4:
            FoundationModelPromptDefinition(
                generation: generation,
                instructions:
                    "Produce one exact SDK-backed source migration using only the supplied "
                    + "candidate SDK declaration, stable symbol identities, and exact "
                    + "editing range. Prefer compiler evidence and supplied deterministic "
                    + "candidates. Produce bounded anchored replace, insertion, or "
                    + "deletion operations when required. Use reviewOnly rather than "
                    + "omitting a concrete edit that still needs build verification. "
                    + "Return notRepairable only when the evidence establishes no edit. Never invent "
                    + "APIs or behavior. Return only the guided fields.",
                maximumDeclarationBytes: 2_500
            )
        case .macOS27:
            FoundationModelPromptDefinition(
                generation: generation,
                instructions:
                    "Produce a bounded ordered set of exact anchored source edits for "
                    + "one compiler diagnostic or exact SDK-resolved source use. Treat "
                    + "the candidate SDK identity, declaration, compiler evidence, and "
                    + "supplied deterministic candidates as the only API authority. "
                    + "A coordinated syntax migration may use replacements, insertions, "
                    + "or deletions, but must remain inside the supplied editing range. "
                    + "For structural changes, return a complete modified copy of the "
                    + "allowed source fragment so the application can derive exact "
                    + "ranges locally. "
                    + "Use reviewOnly for concrete migrations that require verification. "
                    + "Compiler diagnostics and Fix-its are preferred but optional: "
                    + "an exact stable SDK rename with supplied destination-path and "
                    + "value declarations is sufficient to produce a concrete "
                    + "reviewOnly edit for isolated build validation. "
                    + "Return notRepairable only when no evidence-backed source edit exists. "
                    + "Return only guided fields and a concise rationale; do not provide "
                    + "hidden reasoning.",
                maximumDeclarationBytes: 4_000
            )
        }
    }

    func prompt(for context: RepairContext) -> String {
        let declaration = truncate(
            context.enclosingDeclaration,
            maximumUTF8Bytes: maximumDeclarationBytes
        )
        let location = (context.diagnostic?.location).map {
            [
                $0.path,
                $0.line.map(String.init),
                $0.column.map(String.init),
            ].compactMap { $0 }.joined(separator: ":")
        } ?? context.filePath
        let diagnosticLines: String
        if let diagnostic = context.diagnostic,
           let identifier = context.diagnosticIdentifier
        {
            diagnosticLines = """
            Diagnostic identifier: \(identifier)
            Diagnostic severity: \(diagnostic.severity.rawValue)
            Diagnostic: \(diagnostic.message)
            """
        } else {
            diagnosticLines = """
            Diagnostic identifier: none
            Diagnostic severity: none
            Diagnostic: no uniquely matching candidate diagnostic; evaluate the exact SDK-resolved source use as review-only evidence
            """
        }
        let baselineToolchain = context.toolchains.baseline.map {
            "\($0.xcodeVersion) (\($0.xcodeBuild)) · "
                + "\($0.sdkIdentifier) \($0.sdkVersion)"
        } ?? "unavailable"
        let candidateToolchain = context.toolchains.candidate.map {
            "\($0.xcodeVersion) (\($0.xcodeBuild)) · "
                + "\($0.sdkIdentifier) \($0.sdkVersion)"
        } ?? "unavailable"
        return """
        Source file identity: \(context.filePath)
        Source location: \(location)
        Evidence level: \(context.evidenceLevel == .diagnosticBacked ? "diagnostic-backed" : "SDK-risk")
        \(diagnosticLines)
        Language: \(context.language.rawValue)
        Target: \(context.compilerContext.target ?? "unavailable")
        Module: \(context.compilerContext.moduleName ?? "unavailable")
        SDK: \(context.compilerContext.sdkIdentifier)
        Destination: \(context.compilerContext.destination ?? "unavailable")
        Baseline toolchain: \(baselineToolchain)
        Candidate toolchain: \(candidateToolchain)
        Allowed source fragment:
        \(context.sourceFragment)
        Enclosing declaration:
        \(declaration)
        Resolved baseline symbol: \(context.resolvedSymbolIdentity)
        Candidate symbol: \(context.candidateSymbolIdentity)
        Baseline SDK declaration: \(context.baselineSDKDeclaration)
        Candidate SDK declaration: \(context.candidateSDKDeclaration)
        SDK differences: \(context.sdkDifferences.joined(separator: " | "))
        Compiler fix-it evidence: \(joined(context.compilerFixItEvidence))
        Deterministic candidates: \(joined(context.deterministicRepairCandidates))
        Restrictions: \(context.restrictions.joined(separator: " | "))

        SwiftDelta binds the source file, language, symbol identities, diagnostic,
        toolchains, and permitted range to this request. Do not repeat or invent
        those identities. Return the source transformation itself. Set
        revisedSourceLines to a complete compilable copy of Allowed source
        fragment with exactly one Swift source line per array item whenever any
        concrete edit is proposed. Do not combine consecutive Swift statements
        into one array item. Preserve unrelated syntax, attributes, formatting,
        and behavior.
        Do not copy an SDK declaration into source. The revised fragment must
        address the supplied baseline symbol use and use the candidate destination
        path and value declarations established by SDK differences. Every
        originalAnchor should copy the smallest useful source substring inside
        the allowed source fragment. Use replace, insertBefore, insertAfter, or
        delete. The source field contains only replacement or inserted source and
        must be empty only for delete. Prefer at least one concrete edit when the
        candidate declaration or migration message establishes the change. Use
        reviewOnly when the edit needs verification. When disposition is
        notRepairable, return no edits, copy the Allowed source fragment unchanged
        into revisedSourceLines, and explain exactly which evidence is missing.
        """
    }

    private func joined(_ values: [String]) -> String {
        values.isEmpty ? "none" : values.joined(separator: " | ")
    }

    private func truncate(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> String {
        guard value.utf8.count > maximumUTF8Bytes else {
            return value
        }
        var end = value.utf8.index(
            value.utf8.startIndex,
            offsetBy: maximumUTF8Bytes
        )
        while String.Index(end, within: value) == nil,
              end > value.utf8.startIndex
        {
            end = value.utf8.index(before: end)
        }
        guard let stringEnd = String.Index(end, within: value) else {
            return ""
        }
        return String(value[..<stringEnd]) + "\n[declaration truncated]"
    }
}
