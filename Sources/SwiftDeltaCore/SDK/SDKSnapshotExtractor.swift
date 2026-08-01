//===--- SDKSnapshotExtractor.swift - SwiftDelta ------------------------------------------===//
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

public struct SDKSnapshotRequest: Sendable {
    public let xcodeApplicationPath: String
    public let sdkIdentifier: String
    public let modules: [String]
    public let timeout: TimeInterval
    public let cachePolicy: SDKSnapshotCachePolicy
    public let cacheDirectory: URL?
    public let installationIdentity: SDKInstallationIdentity?

    public init(
        xcodeApplicationPath: String,
        sdkIdentifier: String,
        modules: [String],
        timeout: TimeInterval = 180,
        cachePolicy: SDKSnapshotCachePolicy = .use,
        cacheDirectory: URL? = nil,
        installationIdentity: SDKInstallationIdentity? = nil
    ) {
        self.xcodeApplicationPath = xcodeApplicationPath
        self.sdkIdentifier = sdkIdentifier
        self.modules = Array(Set(modules)).sorted()
        self.timeout = timeout
        self.cachePolicy = cachePolicy
        self.cacheDirectory = cacheDirectory
        self.installationIdentity = installationIdentity
    }
}

/// Extracts and normalizes the public API of selected SDK modules.
///
/// Compiler symbol graphs are preferred because they carry stable identities.
/// A Swift interface is used only when symbol graph extraction fails.
public struct SDKSnapshotExtractor: Sendable {
    private let runner: any ProcessRunning
    private let progress: OperationProgress

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        progress: OperationProgress = .silent
    ) {
        self.runner = runner
        self.progress = progress
    }

    public func extract(
        _ request: SDKSnapshotRequest,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> SDKSnapshot {
        let identity = try installationIdentity(
            for: request
        )
        let temporaryDirectory = try TemporaryDirectory(prefix: "swiftdelta-sdk-snapshot")
        defer { temporaryDirectory.remove() }

        // Tool lookup and SDK identity inspection are bounded preflight work.
        // The user-selected timeout remains intact for module extraction.
        let preflightTimeout = min(request.timeout, 30)
        let extractor: String?
        let extractorLookupFailure: String?
        do {
            extractor = try toolPath(
                "swift-symbolgraph-extract",
                developerDirectory: identity.developerDirectory,
                timeout: preflightTimeout
            )
            extractorLookupFailure = nil
        } catch {
            extractor = nil
            extractorLookupFailure =
                "swift-symbolgraph-extract discovery failed during the "
                + "\(Int(preflightTimeout))-second toolchain preflight: "
                + error.localizedDescription
        }
        let target = targetTriple(
            sdkIdentifier: request.sdkIdentifier,
            sdkVersion: identity.sdkVersion
        )
        let extractionOptions = [
            "-skip-inherited-docs",
        ]
        let cache = SDKSnapshotCache(
            root: request.cacheDirectory ?? SDKSnapshotCache.defaultRoot
        )

        var symbols: [SDKSymbol] = []
        var warnings: [String] = []
        var moduleExtractions: [SDKModuleExtraction] = []
        for (moduleIndex, module) in request.modules.enumerated() {
            if cancellation() {
                throw SwiftDeltaError.processCancelled(executable: "swift-symbolgraph-extract")
            }
            let cacheIdentity = SDKSnapshotCacheIdentity(
                installation: identity,
                targetTriple: target,
                moduleName: module,
                extractionOptions: extractionOptions,
                minimumAccessLevel: "public",
                requestedExtractionMode: (
                    extractor == nil
                        ? SDKModuleExtractionSource.swiftInterface.rawValue
                        : SDKModuleExtractionSource.symbolGraph.rawValue
                )
            )
            if request.cachePolicy == .use,
               let cached = cache.read(identity: cacheIdentity)
            {
                progress.message(
                    "Using cached \(module) SDK metadata from Xcode "
                        + "\(identity.xcodeVersion) — \(cached.symbols.count) public symbols"
                )
                symbols.append(contentsOf: cached.symbols)
                moduleExtractions.append(cached.extraction)
                progress.measure(
                    completed: moduleIndex + 1,
                    total: request.modules.count,
                    label: "SDK modules"
                )
                continue
            }
            let moduleDirectory = temporaryDirectory.url
                .appendingPathComponent("module-\(safePathComponent(module))", isDirectory: true)
            let outputDirectory = moduleDirectory.appendingPathComponent("output", isDirectory: true)
            let moduleCache = moduleDirectory.appendingPathComponent("module-cache", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: moduleCache,
                withIntermediateDirectories: true
            )

            let extraction = try progress.phase(
                "Extracting \(module) from Xcode \(identity.xcodeVersion)",
                completedMessage: "Finished extracting \(module)"
            ) {
                progress.measure(
                    completed: moduleIndex,
                    total: request.modules.count,
                    label: "SDK modules"
                )
                return try extractModule(
                    module,
                    extractor: extractor,
                    extractorLookupFailure: extractorLookupFailure,
                    target: target,
                    identity: identity,
                    request: request,
                    moduleDirectory: moduleDirectory,
                    outputDirectory: outputDirectory,
                    moduleCache: moduleCache,
                    cancellation: cancellation
                )
            }
            progress.measure(
                completed: moduleIndex + 1,
                total: request.modules.count,
                label: "SDK modules"
            )
            symbols.append(contentsOf: extraction.symbols)
            moduleExtractions.append(extraction.record)
            if let warning = extraction.warning {
                warnings.append(warning)
            }
            if request.cachePolicy != .disabled,
               extraction.record.succeeded,
               extraction.record.source.rawValue
                    == cacheIdentity.requestedExtractionMode
            {
                cache.write(
                    CachedSDKModule(
                        symbols: extraction.symbols,
                        extraction: extraction.record
                    ),
                    identity: cacheIdentity
                )
            }
        }

        return SDKSnapshot(
            identity: identity,
            modules: request.modules,
            symbols: mergeDuplicateSymbols(symbols),
            moduleExtractions: moduleExtractions,
            extractionWarnings: warnings
        )
    }

    private func installationIdentity(
        for request: SDKSnapshotRequest
    ) throws -> SDKInstallationIdentity {
        guard let identity = request.installationIdentity else {
            return try inspectIdentity(
                xcodeApplicationPath: request.xcodeApplicationPath,
                sdkIdentifier: request.sdkIdentifier,
                timeout: min(request.timeout, 120)
            )
        }
        let requestedXcode = URL(
            fileURLWithPath: request.xcodeApplicationPath
        ).standardizedFileURL.resolvingSymlinksInPath().path
        let identityXcode = URL(
            fileURLWithPath: identity.xcodeApplicationPath
        ).standardizedFileURL.resolvingSymlinksInPath().path
        guard requestedXcode == identityXcode,
              request.sdkIdentifier == identity.sdkIdentifier
        else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "SDK installation identity",
                reason:
                    "the reused identity does not match the selected Xcode "
                    + "and SDK"
            )
        }
        return identity
    }

    private func extractModule(
        _ module: String,
        extractor: String?,
        extractorLookupFailure: String?,
        target: String,
        identity: SDKInstallationIdentity,
        request: SDKSnapshotRequest,
        moduleDirectory: URL,
        outputDirectory: URL,
        moduleCache: URL,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> ModuleExtractionResult {
        guard let extractor else {
            return interfaceFallback(
                module: module,
                identity: identity,
                failure: contextualFailure(
                    operation: "swift-symbolgraph-extract discovery",
                    module: module,
                    identity: identity,
                    elapsed: 0,
                    timeout: min(request.timeout, 30),
                    detail: extractorLookupFailure ?? "the extractor was unavailable"
                )
            )
        }

        let startedAt = Date()
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: extractor,
                arguments: [
                    "-module-name", module,
                    "-target", target,
                    "-sdk", identity.sdkPath,
                    "-minimum-access-level", "public",
                    "-skip-inherited-docs",
                    "-output-dir", outputDirectory.path,
                    "-module-cache-path", moduleCache.path,
                ],
                environment: ["DEVELOPER_DIR": identity.developerDirectory],
                workingDirectory: moduleDirectory,
                timeout: request.timeout,
                cancellation: cancellation
            )
        } catch let error as SwiftDeltaError {
            if case .processCancelled = error {
                throw error
            }
            return interfaceFallback(
                module: module,
                identity: identity,
                failure: contextualFailure(
                    operation: "swift-symbolgraph-extract",
                    module: module,
                    identity: identity,
                    elapsed: Date().timeIntervalSince(startedAt),
                    timeout: request.timeout,
                    detail: error.localizedDescription
                )
            )
        } catch {
            return interfaceFallback(
                module: module,
                identity: identity,
                failure: contextualFailure(
                    operation: "swift-symbolgraph-extract",
                    module: module,
                    identity: identity,
                    elapsed: Date().timeIntervalSince(startedAt),
                    timeout: request.timeout,
                    detail: error.localizedDescription
                )
            )
        }

        guard result.exitStatus == 0 else {
            return interfaceFallback(
                module: module,
                identity: identity,
                failure: contextualFailure(
                    operation: "swift-symbolgraph-extract",
                    module: module,
                    identity: identity,
                    elapsed: Date().timeIntervalSince(startedAt),
                    timeout: request.timeout,
                    detail:
                        "exited with status \(result.exitStatus): "
                        + result.safeErrorSummary
                )
            )
        }

        do {
            let graphFiles = try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ).filter { $0.lastPathComponent.hasSuffix(".symbols.json") }
                .sorted { $0.path < $1.path }
            guard !graphFiles.isEmpty else {
                return interfaceFallback(
                    module: module,
                    identity: identity,
                    failure: contextualFailure(
                        operation: "swift-symbolgraph-extract",
                        module: module,
                        identity: identity,
                        elapsed: Date().timeIntervalSince(startedAt),
                        timeout: request.timeout,
                        detail: "completed without producing symbol graph files"
                    )
                )
            }
            let graphData = try graphFiles.map {
                try Data(contentsOf: $0, options: [.mappedIfSafe])
            }
            let normalized = try SymbolGraphNormalizer.normalize(
                graphData,
                requestedModule: module
            )
            return ModuleExtractionResult(
                symbols: normalized,
                record: SDKModuleExtraction(
                    moduleName: module,
                    source: .symbolGraph,
                    symbolCount: normalized.count
                ),
                warning: nil
            )
        } catch {
            return interfaceFallback(
                module: module,
                identity: identity,
                failure: contextualFailure(
                    operation: "symbol graph normalization",
                    module: module,
                    identity: identity,
                    elapsed: Date().timeIntervalSince(startedAt),
                    timeout: request.timeout,
                    detail: error.localizedDescription
                )
            )
        }
    }

    private func interfaceFallback(
        module: String,
        identity: SDKInstallationIdentity,
        failure: String
    ) -> ModuleExtractionResult {
        do {
            let fallback = try SDKInterfaceScanner.scan(
                module: module,
                sdkPath: identity.sdkPath
            )
            guard !fallback.isEmpty else {
                let detail =
                    "\(failure) Swift-interface fallback found no usable public declarations."
                return ModuleExtractionResult(
                    symbols: [],
                    record: SDKModuleExtraction(
                        moduleName: module,
                        source: .failed,
                        symbolCount: 0,
                        detail: detail
                    ),
                    warning: "\(module): \(detail)"
                )
            }
            let detail =
                "\(failure) Swift-interface fallback was used; declarations "
                + "normalized from .swiftinterface do not have compiler USRs."
            return ModuleExtractionResult(
                symbols: fallback,
                record: SDKModuleExtraction(
                    moduleName: module,
                    source: .swiftInterface,
                    symbolCount: fallback.count,
                    detail: detail
                ),
                warning: "\(module): \(detail)"
            )
        } catch {
            let detail =
                "\(failure) Swift-interface fallback also failed: "
                + error.localizedDescription
            return ModuleExtractionResult(
                symbols: [],
                record: SDKModuleExtraction(
                    moduleName: module,
                    source: .failed,
                    symbolCount: 0,
                    detail: detail
                ),
                warning: "\(module): \(detail)"
            )
        }
    }

    private func contextualFailure(
        operation: String,
        module: String,
        identity: SDKInstallationIdentity,
        elapsed: TimeInterval,
        timeout: TimeInterval,
        detail: String
    ) -> String {
        let elapsedText = String(format: "%.1f", max(0, elapsed))
        let timeoutText = String(format: "%.1f", timeout)
        return
            "\(operation) for module \(module), SDK \(identity.sdkIdentifier) "
            + "\(identity.sdkVersion), Xcode \(identity.xcodeVersion) "
            + "(\(identity.xcodeBuild)) failed after \(elapsedText) seconds "
            + "(effective timeout \(timeoutText) seconds): \(detail)"
    }

    public func inspectIdentity(
        xcodeApplicationPath: String,
        sdkIdentifier: String,
        timeout: TimeInterval = 30
    ) throws -> SDKInstallationIdentity {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: xcodeApplicationPath
        )
        let xcodeOutput = try requiredOutput(
            executable: "/usr/bin/xcodebuild",
            arguments: ["-version"],
            developerDirectory: developerDirectory,
            timeout: timeout
        )
        let xcodeLines = xcodeOutput.split(whereSeparator: \.isNewline).map(String.init)
        let xcodeVersion = xcodeLines.first?
            .replacingOccurrences(of: "Xcode ", with: "") ?? "unknown"
        let xcodeBuild = xcodeLines.first(where: { $0.hasPrefix("Build version ") })?
            .replacingOccurrences(of: "Build version ", with: "") ?? "unknown"
        let sdkPath = try requiredOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", sdkIdentifier, "--show-sdk-path"],
            developerDirectory: developerDirectory,
            timeout: timeout
        )
        let sdkVersion = try requiredOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--sdk", sdkIdentifier, "--show-sdk-version"],
            developerDirectory: developerDirectory,
            timeout: timeout
        )
        let swiftVersion = try? requiredOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["swift", "--version"],
            developerDirectory: developerDirectory,
            timeout: timeout
        )
        return SDKInstallationIdentity(
            xcodeApplicationPath: URL(fileURLWithPath: xcodeApplicationPath)
                .standardizedFileURL.path,
            developerDirectory: developerDirectory,
            xcodeVersion: xcodeVersion,
            xcodeBuild: xcodeBuild,
            platform: Self.platformName(for: sdkIdentifier),
            sdkIdentifier: sdkIdentifier,
            sdkVersion: sdkVersion,
            sdkPath: sdkPath,
            swiftVersion: swiftVersion
        )
    }

    private func toolPath(
        _ tool: String,
        developerDirectory: String,
        timeout: TimeInterval
    ) throws -> String {
        try requiredOutput(
            executable: "/usr/bin/xcrun",
            arguments: ["--find", tool],
            developerDirectory: developerDirectory,
            timeout: timeout
        )
    }

    private func requiredOutput(
        executable: String,
        arguments: [String],
        developerDirectory: String,
        timeout: TimeInterval
    ) throws -> String {
        let command = ([executable] + arguments).joined(separator: " ")
        let result: ProcessResult
        do {
            result = try runner.run(
                executable: executable,
                arguments: arguments,
                environment: ["DEVELOPER_DIR": developerDirectory],
                workingDirectory: nil,
                timeout: timeout,
                cancellation: { false }
            )
        } catch let SwiftDeltaError.processTimedOut(_, seconds) {
            throw SwiftDeltaError.processTimedOut(
                executable:
                    "SDK identity preflight \(command) with DEVELOPER_DIR="
                    + developerDirectory,
                seconds: seconds
            )
        }
        guard result.exitStatus == 0 else {
            throw SwiftDeltaError.processFailed(
                executable: command,
                status: result.exitStatus,
                message: result.safeErrorSummary
            )
        }
        let value = result.standardOutputString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw SwiftDeltaError.processFailed(
                executable: command,
                status: result.exitStatus,
                message: "the tool returned an empty value"
            )
        }
        return value
    }

    private func targetTriple(sdkIdentifier: String, sdkVersion: String) -> String {
        let version = sdkVersion.split(separator: " ").first.map(String.init) ?? sdkVersion
        return switch sdkIdentifier.lowercased() {
        case "iphoneos": "arm64-apple-ios\(version)"
        case "iphonesimulator": "arm64-apple-ios\(version)-simulator"
        case "appletvos": "arm64-apple-tvos\(version)"
        case "appletvsimulator": "arm64-apple-tvos\(version)-simulator"
        case "watchos": "arm64-apple-watchos\(version)"
        case "watchsimulator": "arm64-apple-watchos\(version)-simulator"
        case "xros": "arm64-apple-xros\(version)"
        case "xrsimulator": "arm64-apple-xros\(version)-simulator"
        default: "arm64-apple-macosx\(version)"
        }
    }

    private func safePathComponent(_ value: String) -> String {
        let filtered = value.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return filtered.isEmpty ? "module" : filtered
    }

    private func mergeDuplicateSymbols(_ symbols: [SDKSymbol]) -> [SDKSymbol] {
        var values: [String: SDKSymbol] = [:]
        for symbol in symbols {
            guard let existing = values[symbol.id] else {
                values[symbol.id] = symbol
                continue
            }
            let relationships = Array(Set(existing.relationships + symbol.relationships)).sorted {
                ($0.kind, $0.target) < ($1.kind, $1.target)
            }
            let availability = Array(Set(existing.availability + symbol.availability)).sorted {
                ($0.domain, $0.description) < ($1.domain, $1.description)
            }
            values[symbol.id] = SDKSymbol(
                id: symbol.id,
                moduleName: symbol.moduleName,
                preciseIdentifier: symbol.preciseIdentifier ?? existing.preciseIdentifier,
                fullyQualifiedName: symbol.fullyQualifiedName,
                baseName: symbol.baseName,
                kind: symbol.kind,
                declaration: symbol.declaration ?? existing.declaration,
                signature: symbol.signature ?? existing.signature,
                parameters: symbol.parameters.isEmpty ? existing.parameters : symbol.parameters,
                returnType: symbol.returnType ?? existing.returnType,
                availability: availability,
                isUnavailable: symbol.isUnavailable || existing.isUnavailable,
                renamedDestination: symbol.renamedDestination ?? existing.renamedDestination,
                migrationMessage: symbol.migrationMessage ?? existing.migrationMessage,
                concurrency: symbol.concurrency,
                relationships: relationships,
                propertyReadable: symbol.propertyReadable ?? existing.propertyReadable,
                propertyWritable: symbol.propertyWritable ?? existing.propertyWritable,
                isProtocolRequirement: symbol.isProtocolRequirement
                    || existing.isProtocolRequirement
            )
        }
        return values.values.sorted {
            ($0.moduleName, $0.fullyQualifiedName, $0.id)
                < ($1.moduleName, $1.fullyQualifiedName, $1.id)
        }
    }

    public static func platformName(for sdkIdentifier: String) -> String {
        switch sdkIdentifier.lowercased() {
        case "iphoneos": "iOS"
        case "iphonesimulator": "iOS Simulator"
        case "appletvos": "tvOS"
        case "appletvsimulator": "tvOS Simulator"
        case "watchos": "watchOS"
        case "watchsimulator": "watchOS Simulator"
        case "xros": "visionOS"
        case "xrsimulator": "visionOS Simulator"
        default: "macOS"
        }
    }
}

private struct ModuleExtractionResult {
    let symbols: [SDKSymbol]
    let record: SDKModuleExtraction
    let warning: String?
}
