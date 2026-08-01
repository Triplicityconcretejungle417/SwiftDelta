//===--- RepairSourceDocument.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

import CryptoKit
import Foundation

struct RepairSourceDocument {
    let root: URL
    let url: URL
    let relativePath: String
    let language: RepairLanguage
    let data: Data
    let text: String
    let fingerprint: RepairFileFingerprint
    let permissions: NSNumber

    init(
        root: URL,
        file: URL,
        maximumFileSize: Int = 5 * 1_024 * 1_024
    ) throws {
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let standardizedFile = file.standardizedFileURL
        let resourceValues = try standardizedFile.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard resourceValues.isSymbolicLink != true else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "symbolic-link source files are not modified"
            )
        }
        let resolvedFile = standardizedFile.resolvingSymlinksInPath()
        guard resolvedFile.isContained(in: canonicalRoot),
              resourceValues.isRegularFile == true
        else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "the source file is outside the analyzed project root"
            )
        }
        let absoluteComponents = resolvedFile.pathComponents
        if absoluteComponents.contains(where: {
            $0.hasSuffix(".sdk") || $0.hasSuffix(".xctoolchain")
        }) || absoluteComponents.contains(where: { $0.hasSuffix(".app") })
            && absoluteComponents.contains("Contents")
            && absoluteComponents.contains("Developer")
        {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "Xcode application, toolchain, and SDK contents are never modified"
            )
        }
        guard let relativePath = resolvedFile.relativePath(from: canonicalRoot),
              !relativePath.isEmpty
        else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "the source path could not be represented relative to the project root"
            )
        }
        try RepairPathPolicy.validate(relativePath: relativePath)
        guard let language = RepairPathPolicy.language(for: resolvedFile) else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "the file does not have a supported source extension"
            )
        }
        if let size = resourceValues.fileSize, size > maximumFileSize {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "the source file exceeds the \(maximumFileSize)-byte repair limit"
            )
        }

        let bytes = try Data(contentsOf: resolvedFile, options: [.mappedIfSafe])
        guard bytes.count <= maximumFileSize else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "the source file exceeds the \(maximumFileSize)-byte repair limit"
            )
        }
        guard let source = String(data: bytes, encoding: .utf8) else {
            throw RepairError.protectedPath(
                standardizedFile.path,
                reason: "only UTF-8 source files can be repaired"
            )
        }
        try RepairPathPolicy.rejectGeneratedSource(source, path: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: resolvedFile.path)

        self.root = canonicalRoot
        self.url = resolvedFile
        self.relativePath = relativePath
        self.language = language
        self.data = bytes
        self.text = source
        self.fingerprint = RepairFingerprint.file(bytes)
        self.permissions = attributes[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o644)
    }

    func text(in range: RepairSourceRange) throws -> String {
        let normalized = try normalizedByteRange(range)
        guard let value = String(data: data.subdata(in: normalized), encoding: .utf8) else {
            throw RepairError.invalidRange(
                relativePath,
                reason: "the source range does not align to UTF-8 scalar boundaries"
            )
        }
        return value
    }

    func normalizedByteRange(_ range: RepairSourceRange) throws -> Range<Int> {
        let lower = range.start.utf8Offset
        let upper = range.end.utf8Offset
        guard lower >= 0, upper >= lower, upper <= data.count else {
            throw RepairError.invalidRange(
                relativePath,
                reason: "UTF-8 offsets \(lower)..<\(upper) are outside a \(data.count)-byte file"
            )
        }
        guard let lowerUTF8 = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: lower,
            limitedBy: text.utf8.endIndex
        ),
        let upperUTF8 = text.utf8.index(
            text.utf8.startIndex,
            offsetBy: upper,
            limitedBy: text.utf8.endIndex
        ),
        String.Index(lowerUTF8, within: text) != nil,
        String.Index(upperUTF8, within: text) != nil
        else {
            throw RepairError.invalidRange(
                relativePath,
                reason: "the source range does not align to UTF-8 boundaries"
            )
        }
        return lower..<upper
    }
}

enum RepairFingerprint {
    static func file(_ data: Data) -> RepairFileFingerprint {
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return RepairFileFingerprint(digest: digest, byteCount: data.count)
    }

    static func identifier(_ fields: [String]) -> String {
        let data = Data(fields.joined(separator: "\u{1F}").utf8)
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "repair.\(digest)"
    }
}

private extension URL {
    func relativePath(from root: URL) -> String? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let fileComponents = standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else {
            return nil
        }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }
}
