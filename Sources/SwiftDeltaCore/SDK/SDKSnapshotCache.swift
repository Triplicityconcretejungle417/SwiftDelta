//===--- SDKSnapshotCache.swift - SwiftDelta ------------------------------------------===//
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
import Darwin
import Foundation

public enum SDKSnapshotCachePolicy: String, Codable, Hashable, Sendable {
    case use
    case refresh
    case disabled
}

struct SDKSnapshotCacheIdentity: Codable, Hashable, Sendable {
    static let normalizationVersion = 1

    let xcodeBuild: String
    let developerDirectory: String
    let sdkIdentifier: String
    let sdkVersion: String
    let sdkPath: String
    let targetTriple: String
    let swiftCompilerIdentity: String
    let moduleName: String
    let extractionOptions: [String]
    let minimumAccessLevel: String
    let requestedExtractionMode: String
    let snapshotFormatVersion: Int
    let normalizationVersion: Int

    init(
        installation: SDKInstallationIdentity,
        targetTriple: String,
        moduleName: String,
        extractionOptions: [String],
        minimumAccessLevel: String,
        requestedExtractionMode: String
    ) {
        xcodeBuild = installation.xcodeBuild
        developerDirectory = URL(fileURLWithPath: installation.developerDirectory)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        sdkIdentifier = installation.sdkIdentifier
        sdkVersion = installation.sdkVersion
        sdkPath = URL(fileURLWithPath: installation.sdkPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        self.targetTriple = targetTriple
        swiftCompilerIdentity = installation.swiftVersion ?? "<unavailable>"
        self.moduleName = moduleName
        self.extractionOptions = extractionOptions
        self.minimumAccessLevel = minimumAccessLevel
        self.requestedExtractionMode = requestedExtractionMode
        snapshotFormatVersion = SDKSnapshot.currentFormatVersion
        normalizationVersion = Self.normalizationVersion
    }
}

struct CachedSDKModule: Sendable {
    let symbols: [SDKSymbol]
    let extraction: SDKModuleExtraction
}

struct SDKSnapshotCache: Sendable {
    fileprivate struct Payload: Codable {
        let symbols: [SDKSymbol]
        let extraction: SDKModuleExtraction
    }

    fileprivate struct Entry: Codable {
        static let formatVersion = 1

        let formatVersion: Int
        let identity: SDKSnapshotCacheIdentity
        let payloadDigest: String
        let payload: Payload
    }

    let root: URL

    static var defaultRoot: URL {
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return caches
            .appendingPathComponent("org.swiftdelta", isDirectory: true)
            .appendingPathComponent("SDKSnapshots", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
    }

    func read(
        identity: SDKSnapshotCacheIdentity
    ) -> CachedSDKModule? {
        do {
            return try withLock(for: identity) {
                let entryURL = try entryURL(for: identity)
                guard FileManager.default.isReadableFile(atPath: entryURL.path) else {
                    return nil
                }
                do {
                    let data = try Data(contentsOf: entryURL, options: [.mappedIfSafe])
                    let entry = try JSONDecoder().decode(Entry.self, from: data)
                    guard try isValid(entry, expected: identity) else {
                        try? FileManager.default.removeItem(at: entryURL)
                        return nil
                    }
                    return CachedSDKModule(
                        symbols: entry.payload.symbols,
                        extraction: entry.payload.extraction
                    )
                } catch {
                    try? FileManager.default.removeItem(at: entryURL)
                    return nil
                }
            }
        } catch {
            return nil
        }
    }

    func write(
        _ module: CachedSDKModule,
        identity: SDKSnapshotCacheIdentity
    ) {
        guard module.extraction.succeeded,
              module.extraction.moduleName == identity.moduleName,
              module.extraction.source.rawValue
                == identity.requestedExtractionMode,
              module.extraction.symbolCount == module.symbols.count,
              module.symbols.allSatisfy({ $0.moduleName == identity.moduleName })
        else {
            return
        }
        do {
            try withLock(for: identity) {
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let payload = Payload(
                    symbols: module.symbols,
                    extraction: module.extraction
                )
                let entry = Entry(
                    formatVersion: Entry.formatVersion,
                    identity: identity,
                    payloadDigest: try digest(payload),
                    payload: payload
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(entry)
                let destination = try entryURL(for: identity)
                let temporary = root.appendingPathComponent(
                    ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
                )
                do {
                    try data.write(to: temporary, options: [.atomic])
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(
                            destination,
                            withItemAt: temporary
                        )
                    } else {
                        try FileManager.default.moveItem(
                            at: temporary,
                            to: destination
                        )
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }
        } catch {
            // Cache writes are an optimization. Extraction evidence remains
            // valid even when the cache directory is unavailable.
        }
    }

    private func isValid(
        _ entry: Entry,
        expected identity: SDKSnapshotCacheIdentity
    ) throws -> Bool {
        guard entry.formatVersion == Entry.formatVersion,
              entry.identity == identity,
              entry.payload.extraction.succeeded,
              entry.payload.extraction.moduleName == identity.moduleName,
              entry.payload.extraction.source.rawValue
                == identity.requestedExtractionMode,
              entry.payload.extraction.symbolCount == entry.payload.symbols.count,
              entry.payload.symbols.allSatisfy({
                  $0.moduleName == identity.moduleName
              })
        else {
            return false
        }
        return entry.payloadDigest == (try digest(entry.payload))
    }

    fileprivate func isStructurallyValidEntry(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.formatVersion == Entry.formatVersion,
              entry.payload.extraction.succeeded,
              entry.payload.extraction.moduleName == entry.identity.moduleName,
              entry.payload.extraction.source.rawValue
                == entry.identity.requestedExtractionMode,
              entry.payload.extraction.symbolCount == entry.payload.symbols.count,
              entry.payload.symbols.allSatisfy({
                  $0.moduleName == entry.identity.moduleName
              }),
              entry.payloadDigest == (try? digest(entry.payload))
        else {
            return false
        }
        return true
    }

    private func entryURL(
        for identity: SDKSnapshotCacheIdentity
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(identity)
        return root.appendingPathComponent("\(sha256(data)).json")
    }

    private func digest(_ payload: Payload) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return sha256(try encoder.encode(payload))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func withLock<T>(
        for identity: SDKSnapshotCacheIdentity,
        _ operation: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let entry = try entryURL(for: identity)
        let lockURL = entry.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(.EIO)
        }
        return try operation()
    }
}

public struct SDKCacheStatus: Codable, Hashable, Sendable {
    public let root: String
    public let entryCount: Int
    public let invalidEntryCount: Int
    public let byteCount: Int64
    public let oldestModificationDate: Date?
    public let newestModificationDate: Date?

    public init(
        root: String,
        entryCount: Int,
        invalidEntryCount: Int,
        byteCount: Int64,
        oldestModificationDate: Date?,
        newestModificationDate: Date?
    ) {
        self.root = root
        self.entryCount = entryCount
        self.invalidEntryCount = invalidEntryCount
        self.byteCount = byteCount
        self.oldestModificationDate = oldestModificationDate
        self.newestModificationDate = newestModificationDate
    }
}

public struct SDKCachePruneResult: Codable, Hashable, Sendable {
    public let removedEntries: Int
    public let removedBytes: Int64
    public let remainingEntries: Int
    public let remainingBytes: Int64

    public init(
        removedEntries: Int,
        removedBytes: Int64,
        remainingEntries: Int,
        remainingBytes: Int64
    ) {
        self.removedEntries = removedEntries
        self.removedBytes = removedBytes
        self.remainingEntries = remainingEntries
        self.remainingBytes = remainingBytes
    }
}

/// Manages only files in SwiftDelta's SDK snapshot cache namespace.
public struct SDKCacheManager: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = (
            root ?? SDKSnapshotCache.defaultRoot
        ).standardizedFileURL.resolvingSymlinksInPath()
    }

    public func status() throws -> SDKCacheStatus {
        let entries = try cacheEntries()
        return SDKCacheStatus(
            root: root.path,
            entryCount: entries.count,
            invalidEntryCount: entries.count { !$0.isValid },
            byteCount: entries.reduce(0) { $0 + $1.size },
            oldestModificationDate: entries.compactMap(\.date).min(),
            newestModificationDate: entries.compactMap(\.date).max()
        )
    }

    public func prune(
        maximumAge: TimeInterval? = nil,
        maximumSize: Int64? = nil,
        now: Date = Date()
    ) throws -> SDKCachePruneResult {
        if let maximumAge, maximumAge < 0 {
            throw SwiftDeltaError.invalidConfiguration(
                field: "maximumAge",
                reason: "cache maximum age cannot be negative"
            )
        }
        if let maximumSize, maximumSize < 0 {
            throw SwiftDeltaError.invalidConfiguration(
                field: "maximumSize",
                reason: "cache maximum size cannot be negative"
            )
        }
        var entries = try cacheEntries().sorted {
            ($0.date ?? .distantPast, $0.url.lastPathComponent)
                < ($1.date ?? .distantPast, $1.url.lastPathComponent)
        }
        var selected = Set<String>()
        for entry in entries where !entry.isValid {
            selected.insert(entry.url.path)
        }
        if let maximumAge {
            let cutoff = now.addingTimeInterval(-maximumAge)
            for entry in entries where (entry.date ?? .distantPast) < cutoff {
                selected.insert(entry.url.path)
            }
        }
        if let maximumSize {
            var retainedSize = entries.reduce(0) { partial, entry in
                selected.contains(entry.url.path)
                    ? partial
                    : partial + entry.size
            }
            for entry in entries where retainedSize > maximumSize {
                guard !selected.contains(entry.url.path) else {
                    continue
                }
                selected.insert(entry.url.path)
                retainedSize -= entry.size
            }
        }
        var removedCount = 0
        var removedBytes: Int64 = 0
        for entry in entries where selected.contains(entry.url.path) {
            try removeOwnedEntry(entry.url)
            removedCount += 1
            removedBytes += entry.size
        }
        entries = try cacheEntries()
        return SDKCachePruneResult(
            removedEntries: removedCount,
            removedBytes: removedBytes,
            remainingEntries: entries.count,
            remainingBytes: entries.reduce(0) { $0 + $1.size }
        )
    }

    public func clear() throws -> SDKCachePruneResult {
        try prune(maximumSize: 0)
    }

    private struct CacheEntry {
        let url: URL
        let size: Int64
        let date: Date?
        let isValid: Bool
    }

    private func cacheEntries() throws -> [CacheEntry] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        let values: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ]
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(values),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ).compactMap { url in
            guard url.pathExtension == "json" else {
                return nil
            }
            let metadata = try url.resourceValues(forKeys: values)
            guard metadata.isRegularFile == true,
                  metadata.isSymbolicLink != true
            else {
                return nil
            }
            return CacheEntry(
                url: url,
                size: Int64(metadata.fileSize ?? 0),
                date: metadata.contentModificationDate,
                isValid: SDKSnapshotCache(root: root)
                    .isStructurallyValidEntry(at: url)
            )
        }
    }

    private func removeOwnedEntry(_ entry: URL) throws {
        let canonicalParent = entry.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard canonicalParent.path == root.path,
              entry.pathExtension == "json"
        else {
            throw SwiftDeltaError.unsafePath(entry.path)
        }
        let lockURL = entry.deletingPathExtension().appendingPathExtension("lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(.EIO)
        }
        if FileManager.default.fileExists(atPath: entry.path) {
            try FileManager.default.removeItem(at: entry)
        }
    }
}
