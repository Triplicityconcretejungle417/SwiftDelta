//===--- PackageAnalyzer.swift - SwiftDelta ------------------------------------------===//
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
import SwiftParser
import SwiftSyntax

public struct PackageAnalyzer: Sendable {
    public let maximumManifestSize: Int

    public init(maximumManifestSize: Int = 1_024 * 1_024) {
        self.maximumManifestSize = maximumManifestSize
    }

    public func analyze(
        manifestURL: URL
    ) throws -> PackageAnalysisResult {
        let data = try boundedRead(manifestURL, limit: maximumManifestSize)
        guard let source = String(data: data, encoding: .utf8) else {
            throw SwiftDeltaError.invalidConfiguration(
                field: manifestURL.path,
                reason: "Package.swift must use UTF-8 encoding"
            )
        }

        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: manifestURL.path, tree: tree)
        let visitor = PackageManifestVisitor(converter: converter)
        visitor.walk(tree)

        let toolsVersion = parseToolsVersion(source)
        var failures: [AnalysisFailure] = []

        if tree.hasError {
            failures.append(
                AnalysisFailure(
                    kind: .parse,
                    message: "Package.swift contains syntax that SwiftSyntax could not fully parse.",
                    location: SourceLocation(path: manifestURL.path)
                )
            )
        }

        let resolvedURL = manifestURL
            .deletingLastPathComponent()
            .appendingPathComponent("Package.resolved")
        let resolvedState = inspectResolvedFile(at: resolvedURL)
        if let failure = resolvedState.failure {
            failures.append(failure)
        }
        let binaryInspection = inspectBinaryTargets(
            visitor.binaryTargets,
            packageRoot: manifestURL.deletingLastPathComponent()
        )
        failures.append(contentsOf: binaryInspection.failures)
        return PackageAnalysisResult(
            metadata: PackageMetadata(
                manifestPath: manifestURL.path,
                toolsVersion: toolsVersion,
                minimumPlatforms: visitor.platforms,
                resolvedFilePresent: resolvedState.present,
                resolvedDependencyCount: resolvedState.count,
                binaryTargets: visitor.binaryTargets.sorted(),
                binaryTargetSlices: binaryInspection.details,
                pluginCount: visitor.pluginCount
            ),
            findings: [],
            failures: failures
        )
    }

    private func parseToolsVersion(_ source: String) -> String? {
        guard let firstLine = source.split(
            whereSeparator: \.isNewline
        ).first else {
            return nil
        }
        let pattern = #"^//\s*swift-tools-version:\s*([0-9]+(?:\.[0-9]+)*)\s*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: String(firstLine),
                  range: NSRange(firstLine.startIndex..<firstLine.endIndex, in: firstLine)
              ),
              let range = Range(match.range(at: 1), in: firstLine)
        else {
            return nil
        }
        return String(firstLine[range])
    }

    private func inspectResolvedFile(
        at url: URL
    ) -> (present: Bool, count: Int?, failure: AnalysisFailure?) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (false, nil, nil)
        }
        do {
            let data = try boundedRead(url, limit: 5 * 1_024 * 1_024)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pins = root["pins"] as? [Any]
            else {
                return (
                    true,
                    nil,
                    AnalysisFailure(
                        kind: .parse,
                        message: "Package.resolved does not contain a valid pins array.",
                        location: SourceLocation(path: url.path)
                    )
                )
            }
            return (true, pins.count, nil)
        } catch {
            return (
                true,
                nil,
                AnalysisFailure(
                    kind: .parse,
                    message: "Could not read Package.resolved: \(error.localizedDescription)",
                    location: SourceLocation(path: url.path)
                )
            )
        }
    }

    private func boundedRead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw SwiftDeltaError.fileTooLarge(path: url.path, limit: limit)
        }
        return data
    }

    private func inspectBinaryTargets(
        _ references: [String],
        packageRoot: URL
    ) -> (details: [String: [BinaryTargetSlice]], failures: [AnalysisFailure]) {
        var details: [String: [BinaryTargetSlice]] = [:]
        var failures: [AnalysisFailure] = []
        let canonicalRoot = packageRoot.standardizedFileURL.resolvingSymlinksInPath()

        for reference in references where !reference.contains("://") {
            let artifact = canonicalRoot
                .appendingPathComponent(reference)
                .standardizedFileURL
                .resolvingSymlinksInPath()
            guard artifact.isContained(in: canonicalRoot) else {
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message: "Binary target path escapes the package root.",
                        location: SourceLocation(path: artifact.path)
                    )
                )
                continue
            }
            guard artifact.pathExtension.lowercased() == "xcframework" else {
                continue
            }
            let info = artifact.appendingPathComponent("Info.plist")
            guard FileManager.default.fileExists(atPath: info.path) else {
                failures.append(
                    AnalysisFailure(
                        kind: .fileRead,
                        message: "Local XCFramework is missing Info.plist.",
                        location: SourceLocation(path: artifact.path)
                    )
                )
                continue
            }
            do {
                let data = try boundedRead(info, limit: 5 * 1_024 * 1_024)
                guard let root = try PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any],
                let libraries = root["AvailableLibraries"] as? [[String: Any]]
                else {
                    throw SwiftDeltaError.invalidConfiguration(
                        field: info.path,
                        reason: "AvailableLibraries is missing"
                    )
                }
                details[reference] = libraries.compactMap { library in
                    guard let platform = library["SupportedPlatform"] as? String,
                          let architectures = library["SupportedArchitectures"] as? [String]
                    else {
                        return nil
                    }
                    return BinaryTargetSlice(
                        platform: platform,
                        variant: library["SupportedPlatformVariant"] as? String,
                        architectures: architectures.sorted()
                    )
                }
            } catch {
                failures.append(
                    AnalysisFailure(
                        kind: .parse,
                        message: "Could not inspect XCFramework metadata: \(error.localizedDescription)",
                        location: SourceLocation(path: info.path)
                    )
                )
            }
        }
        return (details, failures)
    }

}
