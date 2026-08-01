//===--- RepairPathPolicy.swift - SwiftDelta ------------------------------------------===//
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

enum RepairPathPolicy {
    private static let protectedFileNames: Set<String> = [
        "package.swift",
        "package.resolved",
    ]

    private static let protectedExtensions: Set<String> = [
        "pbxproj",
        "xcworkspace",
        "xcodeproj",
    ]

    private static let protectedComponents: Set<String> = [
        ".build",
        ".swiftpm",
        "deriveddata",
        "generated",
        "generatedsources",
        "sourcepackages",
        "pods",
        "vendor",
        "node_modules",
    ]

    static func language(for file: URL) -> RepairLanguage? {
        switch file.pathExtension.lowercased() {
        case "swift": .swift
        case "m": .objectiveC
        case "mm": .objectiveCpp
        case "c": .c
        case "cc", "cpp", "cxx": .cpp
        case "h": .cOrObjectiveCHeader
        case "hh", "hpp", "hxx": .cppOrObjectiveCppHeader
        default: nil
        }
    }

    static func validate(relativePath: String) throws {
        let components = NSString(string: relativePath).pathComponents
        guard !NSString(string: relativePath).isAbsolutePath,
              !components.contains(".."),
              !components.isEmpty
        else {
            throw RepairError.protectedPath(
                relativePath,
                reason: "repair paths must remain relative to the analyzed project root"
            )
        }
        let fileName = components.last ?? ""
        let lowercasedComponents = components.map {
            $0.lowercased()
        }
        guard !protectedFileNames.contains(fileName.lowercased()),
              !protectedExtensions.contains(
                  URL(fileURLWithPath: fileName).pathExtension.lowercased()
              )
        else {
            throw RepairError.protectedPath(
                relativePath,
                reason: "package manifests, lock files, and Xcode project metadata are not repair targets"
            )
        }
        if let index = lowercasedComponents.firstIndex(
            where: protectedComponents.contains
        ) {
            let component = components[index]
            throw RepairError.protectedPath(
                relativePath,
                reason: "'\(component)' is a dependency, cache, or build-output directory"
            )
        }
        if lowercasedComponents.contains("carthage"),
           lowercasedComponents.contains("checkouts")
            || lowercasedComponents.contains("build")
        {
            throw RepairError.protectedPath(
                relativePath,
                reason: "Carthage dependency and build directories are not repair targets"
            )
        }
        if lowercasedComponents.contains(where: {
            $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace")
                || $0.hasSuffix(".sdk") || $0.hasSuffix(".xctoolchain")
        }) {
            throw RepairError.protectedPath(
                relativePath,
                reason: "Xcode project, workspace, toolchain, and SDK contents are not repair targets"
            )
        }
    }

    static func rejectGeneratedSource(_ source: String, path: String) throws {
        let fileName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        let prefix = String(source.prefix(4_096)).lowercased()
        let generatedPath = fileName.contains(".generated.")
            || fileName.hasSuffix("+generated.swift")
        let generatedMarker = prefix.contains("// @generated")
            || prefix.contains("/* @generated")
            || prefix.contains("// generated file. do not edit")
            || prefix.contains("// this file is generated; do not edit")
        guard !generatedPath, !generatedMarker else {
            throw RepairError.protectedPath(
                path,
                reason: "the file is reliably identified as generated source"
            )
        }
    }
}
