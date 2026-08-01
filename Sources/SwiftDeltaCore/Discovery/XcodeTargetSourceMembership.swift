//===--- XcodeTargetSourceMembership.swift - SwiftDelta ------------------------------------------===//
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

public struct XcodeTargetSourceMembership: Sendable {
    public let sourceFilesByTarget: [String: [String]]
    public let nativeSourceFilesByTarget: [String: [String]]
    public let dependenciesByTarget: [String: [String]]
    public let unsupportedReasons: [String]

    public init(
        sourceFilesByTarget: [String: [String]],
        nativeSourceFilesByTarget: [String: [String]] = [:],
        dependenciesByTarget: [String: [String]] = [:],
        unsupportedReasons: [String] = []
    ) {
        self.sourceFilesByTarget = sourceFilesByTarget
        self.nativeSourceFilesByTarget = nativeSourceFilesByTarget
        self.dependenciesByTarget = dependenciesByTarget
        self.unsupportedReasons = unsupportedReasons
    }
}

/// Reads target membership from the project model without treating unrelated
/// source files under the repository root as members of the selected target.
public enum XcodeTargetSourceMembershipReader {
    public static func read(
        project: ProjectContainer,
        projectRoot: URL
    ) throws -> XcodeTargetSourceMembership {
        guard project.kind == .project else {
            throw SwiftDeltaError.invalidConfiguration(
                field: "project",
                reason: "source membership must be read from an .xcodeproj"
            )
        }
        let projectURL = URL(fileURLWithPath: project.path)
        let pbxproj = projectURL.appendingPathComponent("project.pbxproj")
        let text = try String(
            contentsOf: pbxproj,
            encoding: .utf8
        )
        let parser = PBXSourceMembershipParser(
            text: text,
            sourceRoot: projectRoot
        )
        return parser.parse()
    }
}

private struct PBXSourceMembershipParser {
    let text: String
    let sourceRoot: URL

    func parse() -> XcodeTargetSourceMembership {
        let buildFileToReference = dictionary(
            section: "PBXBuildFile",
            valuePattern: #"fileRef = ([A-F0-9]{8,32})"#
        )
        let fileReferences = fileReferencePaths()
        let groups = groupModels()
        let parentGroups = parentGroupMap(groups)
        let sourcePhases = sourceBuildPhases()
        let targets = nativeTargets()
        let targetNames = targets.reduce(into: [String: String]()) {
            values, target in
            if values[target.id] == nil {
                values[target.id] = target.name
            }
        }
        let dependencyTargets = dictionary(
            section: "PBXTargetDependency",
            valuePattern: #"target = ([A-F0-9]{8,32})"#
        )
        var result: [String: [String]] = [:]
        var nativeResult: [String: [String]] = [:]
        var dependencies: [String: [String]] = [:]
        for target in targets {
            var paths = Set<String>()
            var nativePaths = Set<String>()
            for phase in target.sourcePhases {
                for buildFile in sourcePhases[phase] ?? [] {
                    guard let reference = buildFileToReference[buildFile],
                          let model = fileReferences[reference],
                          let url = resolve(
                            reference: reference,
                            model: model,
                            parentGroups: parentGroups,
                            groups: groups
                          )
                    else {
                        continue
                    }
                    if model.language == .swift {
                        paths.insert(url.standardizedFileURL.path)
                    } else if model.language == .native {
                        nativePaths.insert(url.standardizedFileURL.path)
                    }
                }
            }
            result[target.name] = Array(
                Set((result[target.name] ?? []) + Array(paths))
            ).sorted()
            nativeResult[target.name] = Array(
                Set((nativeResult[target.name] ?? []) + Array(nativePaths))
            ).sorted()
            dependencies[target.name] = Array(Set(
                (dependencies[target.name] ?? [])
                    + target.dependencies.compactMap {
                        dependencyTargets[$0].flatMap { targetNames[$0] }
                    }
            )).sorted()
        }
        var reasons: [String] = []
        if text.contains("PBXFileSystemSynchronizedRootGroup") {
            reasons.append(
                "file-system-synchronized groups require build-derived source membership"
            )
        }
        if text.contains("PBXShellScriptBuildPhase") {
            reasons.append(
                "shell-script build phases may contribute generated sources"
            )
        }
        if text.contains("platformFilter =")
            || text.contains("platformFilters =")
        {
            reasons.append(
                "conditional source membership requires exact build-derived compiler input"
            )
        }
        let duplicateTargetNames = Dictionary(grouping: targets, by: \.name)
            .filter { $0.value.count > 1 }
            .keys
            .sorted()
        if !duplicateTargetNames.isEmpty {
            reasons.append(
                "duplicate target names require project-qualified build-derived membership: "
                    + duplicateTargetNames.joined(separator: ", ")
            )
        }
        return XcodeTargetSourceMembership(
            sourceFilesByTarget: result,
            nativeSourceFilesByTarget: nativeResult,
            dependenciesByTarget: dependencies,
            unsupportedReasons: reasons
        )
    }

    private struct FileReference {
        enum Language {
            case swift
            case native
            case other
        }

        let path: String
        let sourceTree: String
        let language: Language
    }

    private struct Group {
        let path: String?
        let sourceTree: String
        let children: [String]
    }

    private struct NativeTarget {
        let id: String
        let name: String
        let sourcePhases: [String]
        let dependencies: [String]
    }

    private func fileReferencePaths() -> [String: FileReference] {
        var values: [String: FileReference] = [:]
        for entry in entries(in: "PBXFileReference") {
            let path = scalar("path", in: entry.body)
                ?? scalar("name", in: entry.body)
                ?? entry.comment
            guard let path else {
                continue
            }
            let sourceTree = scalar("sourceTree", in: entry.body) ?? "<group>"
            let type = scalar("lastKnownFileType", in: entry.body)
                ?? scalar("explicitFileType", in: entry.body)
                ?? ""
            let lowerPath = path.lowercased()
            let nativeExtensions = [
                ".m", ".mm", ".c", ".cc", ".cpp", ".cxx",
            ]
            let language: FileReference.Language
            if type == "sourcecode.swift" || lowerPath.hasSuffix(".swift") {
                language = .swift
            } else if type.hasPrefix("sourcecode.c")
                || type.hasPrefix("sourcecode.cpp")
                || type.hasPrefix("sourcecode.objc")
                || nativeExtensions.contains(where: lowerPath.hasSuffix)
            {
                language = .native
            } else {
                language = .other
            }
            values[entry.id] = FileReference(
                path: unquote(path),
                sourceTree: unquote(sourceTree),
                language: language
            )
        }
        return values
    }

    private func groupModels() -> [String: Group] {
        var values: [String: Group] = [:]
        for section in ["PBXGroup", "PBXVariantGroup"] {
            for entry in entries(in: section) {
                values[entry.id] = Group(
                    path: scalar("path", in: entry.body).map(unquote),
                    sourceTree: unquote(
                        scalar("sourceTree", in: entry.body) ?? "<group>"
                    ),
                    children: identifiers(inList: "children", body: entry.body)
                )
            }
        }
        return values
    }

    private func parentGroupMap(_ groups: [String: Group]) -> [String: String] {
        var parents: [String: String] = [:]
        for (groupID, group) in groups {
            for child in group.children where parents[child] == nil {
                parents[child] = groupID
            }
        }
        return parents
    }

    private func sourceBuildPhases() -> [String: [String]] {
        entries(in: "PBXSourcesBuildPhase").reduce(
            into: [String: [String]]()
        ) { values, entry in
            let identifiers = identifiers(
                inList: "files",
                body: entry.body
            )
            values[entry.id] = Array(
                Set((values[entry.id] ?? []) + identifiers)
            ).sorted()
        }
    }

    private func nativeTargets() -> [NativeTarget] {
        entries(in: "PBXNativeTarget").compactMap { entry in
            let name = scalar("name", in: entry.body).map(unquote)
                ?? entry.comment
            guard let name else {
                return nil
            }
            return NativeTarget(
                id: entry.id,
                name: name,
                sourcePhases: identifiers(
                    inList: "buildPhases",
                    body: entry.body
                ),
                dependencies: identifiers(
                    inList: "dependencies",
                    body: entry.body
                )
            )
        }
    }

    private func resolve(
        reference: String,
        model: FileReference,
        parentGroups: [String: String],
        groups: [String: Group]
    ) -> URL? {
        switch model.sourceTree {
        case "SDKROOT", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR":
            return nil
        case "<absolute>":
            return URL(fileURLWithPath: model.path)
        case "SOURCE_ROOT":
            return sourceRoot.appendingPathComponent(model.path)
        default:
            var components: [String] = [model.path]
            var current = parentGroups[reference]
            var visited = Set<String>()
            while let groupID = current, visited.insert(groupID).inserted {
                guard let group = groups[groupID] else {
                    break
                }
                if let path = group.path, !path.isEmpty {
                    components.insert(path, at: 0)
                }
                if group.sourceTree == "SOURCE_ROOT" {
                    break
                }
                current = parentGroups[groupID]
            }
            return components.reduce(sourceRoot) {
                $0.appendingPathComponent($1)
            }
        }
    }

    private struct Entry {
        let id: String
        let comment: String?
        let body: String
    }

    private func entries(in section: String) -> [Entry] {
        objectEntries().filter {
            scalar("isa", in: $0.body).map(unquote) == section
        }
    }

    private func objectEntries() -> [Entry] {
        let pattern = #"([A-F0-9]{8,32})(?: /\* (.*?) \*/)? = \{"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let fullRange = NSRange(text.startIndex..., in: text)
        var entries: [Entry] = []
        for match in expression.matches(in: text, range: fullRange) {
            guard let wholeRange = Range(match.range(at: 0), in: text),
                  let idRange = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            let bodyStart = wholeRange.upperBound
            var cursor = bodyStart
            var depth = 1
            var insideString = false
            var escaped = false
            while cursor < text.endIndex, depth > 0 {
                let character = text[cursor]
                if insideString {
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        insideString = false
                    }
                } else if character == "\"" {
                    insideString = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                }
                cursor = text.index(after: cursor)
            }
            guard depth == 0 else {
                continue
            }
            let bodyEnd = text.index(before: cursor)
            let comment = Range(match.range(at: 2), in: text).map {
                String(text[$0])
            }
            entries.append(
                Entry(
                    id: String(text[idRange]),
                    comment: comment,
                    body: String(text[bodyStart..<bodyEnd])
                )
            )
        }
        return entries
    }

    private func dictionary(
        section: String,
        valuePattern: String
    ) -> [String: String] {
        var values: [String: String] = [:]
        let expression = try? NSRegularExpression(pattern: valuePattern)
        for entry in entries(in: section) {
            let range = NSRange(entry.body.startIndex..., in: entry.body)
            guard let match = expression?.firstMatch(
                in: entry.body,
                range: range
            ), let valueRange = Range(match.range(at: 1), in: entry.body) else {
                continue
            }
            values[entry.id] = String(entry.body[valueRange])
        }
        return values
    }

    private func scalar(_ key: String, in body: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let groups = matches(
            #"(?m)\b\#(escaped) = ("(?:\\.|[^"])*"|[^;]+);"#,
            in: body
        )
        return groups.first?[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func identifiers(inList key: String, body: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        guard let list = matches(
            #"(?s)\b\#(escaped) = \((.*?)\);"#,
            in: body
        ).first?[1] else {
            return []
        }
        return matches(#"([A-F0-9]{8,32})"#, in: list).map { $0[1] }
    }

    private func matches(_ pattern: String, in value: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.matches(in: value, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: value) else {
                    return ""
                }
                return String(value[range])
            }
        }
    }

    private func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\ "#, with: " ")
    }
}
