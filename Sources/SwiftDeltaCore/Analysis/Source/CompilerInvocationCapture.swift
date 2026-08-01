//===--- CompilerInvocationCapture.swift - SwiftDelta ------------------------------------------===//
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

struct CapturedSwiftCompilerInvocation: Sendable {
    let executable: String
    let originalArguments: [String]
    let analysisArguments: [String]
    let moduleName: String
    let targetName: String?
    let projectName: String?
    let architecture: String?
    let sourceFiles: [String]
}

struct CompilerInvocationCaptureResult: Sendable {
    let invocations: [CapturedSwiftCompilerInvocation]
    let buildExitStatus: Int32
    let buildFailureSummary: String?
    let artifactLease: TemporaryDirectory

    func bestInvocation(
        moduleName: String,
        targetName: String,
        architecture: String
    ) -> CapturedSwiftCompilerInvocation? {
        invocations
            .filter {
                $0.moduleName == moduleName
                    || $0.targetName == targetName
            }
            .sorted {
                score(
                    $0,
                    moduleName: moduleName,
                    targetName: targetName,
                    architecture: architecture
                ) > score(
                    $1,
                    moduleName: moduleName,
                    targetName: targetName,
                    architecture: architecture
                )
            }
            .first
    }

    private func score(
        _ invocation: CapturedSwiftCompilerInvocation,
        moduleName: String,
        targetName: String,
        architecture: String
    ) -> Int {
        var value = invocation.analysisArguments.count
        if invocation.moduleName == moduleName { value += 10_000 }
        if invocation.targetName == targetName { value += 5_000 }
        if invocation.architecture == architecture { value += 2_000 }
        return value
    }
}

/// Captures the Swift driver command emitted by an isolated selected-Xcode
/// build. The captured build directory stays alive through reference analysis
/// because exact arguments may refer to generated sources and dependency
/// products inside DerivedData.
struct CompilerInvocationCapture: Sendable {
    private let runner: any ProcessRunning

    init(runner: any ProcessRunning) {
        self.runner = runner
    }

    func captureXcodeBuild(
        container: ProjectContainer,
        scheme: String,
        configuration: String?,
        sdkIdentifier: String,
        destination: String?,
        developerDirectory: String,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompilerInvocationCaptureResult {
        let temporary = try TemporaryDirectory(
            prefix: "swiftdelta-compiler-context"
        )
        do {
            let derivedData = temporary.url.appendingPathComponent(
                "DerivedData",
                isDirectory: true
            )
            let sourcePackages = temporary.url.appendingPathComponent(
                "SourcePackages",
                isDirectory: true
            )
            let packageCache = temporary.url.appendingPathComponent(
                "PackageCache",
                isDirectory: true
            )
            let moduleCache = temporary.url.appendingPathComponent(
                "ModuleCache",
                isDirectory: true
            )
            for directory in [
                derivedData,
                sourcePackages,
                packageCache,
                moduleCache,
            ] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            try SwiftPackageDependencyCacheSeeder.seed(
                xcodeContainer: container,
                isolatedCache: packageCache
            )

            var arguments: [String] = []
            switch container.kind {
            case .project:
                arguments.append(contentsOf: ["-project", container.path])
            case .workspace:
                arguments.append(contentsOf: ["-workspace", container.path])
            case .package:
                throw SwiftDeltaError.invalidConfiguration(
                    field: "container",
                    reason:
                        "Xcode compiler invocation capture requires a project "
                        + "or workspace"
                )
            }
            arguments.append(contentsOf: [
                "-scheme", scheme,
                "-derivedDataPath", derivedData.path,
                "-clonedSourcePackagesDirPath", sourcePackages.path,
                "-packageCachePath", packageCache.path,
                "-disableAutomaticPackageResolution",
                "-onlyUsePackageVersionsFromResolvedFile",
                "-sdk", sdkIdentifier,
            ])
            if let configuration {
                arguments.append(
                    contentsOf: ["-configuration", configuration]
                )
            }
            if let destination {
                arguments.append(contentsOf: ["-destination", destination])
            }
            arguments.append(contentsOf: [
                "CODE_SIGNING_ALLOWED=NO",
                "CODE_SIGNING_REQUIRED=NO",
                "COMPILER_INDEX_STORE_ENABLE=NO",
                "build",
            ])

            let result = try runner.run(
                executable: "/usr/bin/xcodebuild",
                arguments: arguments,
                environment: [
                    "DEVELOPER_DIR": developerDirectory,
                    "CLANG_MODULE_CACHE_PATH": moduleCache.path,
                ],
                workingDirectory: URL(fileURLWithPath: container.path)
                    .deletingLastPathComponent(),
                timeout: timeout,
                cancellation: cancellation
            )
            let log = result.standardOutputString
                + "\n"
                + result.standardErrorString
            let invocations = CompilerInvocationLogParser.parse(
                log,
                artifactRoot: temporary.url
            )
            return CompilerInvocationCaptureResult(
                invocations: invocations,
                buildExitStatus: result.exitStatus,
                buildFailureSummary: result.exitStatus == 0
                    ? nil : result.safeErrorSummary,
                artifactLease: temporary
            )
        } catch {
            temporary.remove()
            throw error
        }
    }

    func captureSwiftPackageBuild(
        packageRoot: URL,
        xcodeApplicationPath: String,
        sdkPath: String,
        targetTriple: String,
        configuration: String?,
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool = { false }
    ) throws -> CompilerInvocationCaptureResult {
        let developerDirectory = try XcodeInstallation.validate(
            applicationPath: xcodeApplicationPath
        )
        let swift = URL(fileURLWithPath: developerDirectory)
            .appendingPathComponent(
                "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
            )
        let temporary = try TemporaryDirectory(
            prefix: "swiftdelta-package-compiler-context"
        )
        do {
            let scratch = temporary.url.appendingPathComponent(
                "Scratch",
                isDirectory: true
            )
            let cache = temporary.url.appendingPathComponent(
                "Cache",
                isDirectory: true
            )
            let configurationRoot = temporary.url.appendingPathComponent(
                "Configuration",
                isDirectory: true
            )
            let security = temporary.url.appendingPathComponent(
                "Security",
                isDirectory: true
            )
            let moduleCache = temporary.url.appendingPathComponent(
                "ModuleCache",
                isDirectory: true
            )
            for directory in [
                scratch,
                cache,
                configurationRoot,
                security,
                moduleCache,
            ] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            try SwiftPackageDependencyCacheSeeder.seed(
                packageRoot: packageRoot,
                isolatedCache: cache
            )
            var arguments = [
                "build",
                "--package-path", packageRoot.path,
                "--scratch-path", scratch.path,
                "--cache-path", cache.path,
                "--config-path", configurationRoot.path,
                "--security-path", security.path,
                "--disable-automatic-resolution",
                "--disable-experimental-prebuilts",
                "--disable-prefetching",
                "--skip-update",
                "--manifest-cache", "none",
                "-v",
            ]
            if let configuration {
                arguments.append(
                    contentsOf: [
                        "--configuration",
                        configuration.lowercased(),
                    ]
                )
            }
            if !sdkPath.isEmpty, !targetTriple.isEmpty {
                arguments.append(
                    contentsOf: [
                        "--sdk", sdkPath,
                        "--triple", targetTriple,
                    ]
                )
            }
            arguments.append(
                contentsOf: [
                    "-Xswiftc", "-module-cache-path",
                    "-Xswiftc", moduleCache.path,
                ]
            )
            let result = try runner.run(
                executable: swift.path,
                arguments: arguments,
                environment: [
                    "DEVELOPER_DIR": developerDirectory,
                    "CLANG_MODULE_CACHE_PATH": moduleCache.path,
                    "SWIFTPM_MODULECACHE_OVERRIDE": moduleCache.path,
                ],
                workingDirectory: packageRoot,
                timeout: timeout,
                cancellation: cancellation
            )
            let log = result.standardOutputString
                + "\n"
                + result.standardErrorString
            return CompilerInvocationCaptureResult(
                invocations: CompilerInvocationLogParser.parse(
                    log,
                    artifactRoot: temporary.url
                ),
                buildExitStatus: result.exitStatus,
                buildFailureSummary: result.exitStatus == 0
                    ? nil : result.safeErrorSummary,
                artifactLease: temporary
            )
        } catch {
            temporary.remove()
            throw error
        }
    }
}

enum CompilerInvocationLogParser {
    static func parse(
        _ log: String,
        artifactRoot: URL
    ) -> [CapturedSwiftCompilerInvocation] {
        var targetName: String?
        var projectName: String?
        var invocations: [CapturedSwiftCompilerInvocation] = []
        for rawLine in log.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ) {
            let line = String(rawLine)
            if let context = targetContext(in: line) {
                targetName = context.target
                projectName = context.project
            }
            guard let command = swiftCommand(in: line) else {
                continue
            }
            let expanded = expandResponseFiles(
                command.arguments,
                artifactRoot: artifactRoot
            )
            guard let moduleName = value(after: "-module-name", in: expanded),
                  !moduleName.isEmpty
            else {
                continue
            }
            let sourceFiles = sourcePaths(in: expanded)
            guard !sourceFiles.isEmpty else {
                continue
            }
            let triple = value(after: "-target", in: expanded)
            let invocation = CapturedSwiftCompilerInvocation(
                executable: command.executable,
                originalArguments: expanded,
                analysisArguments: analysisArguments(
                    from: expanded,
                    sourceFiles: sourceFiles
                ),
                moduleName: moduleName,
                targetName: targetName,
                projectName: projectName,
                architecture: triple?.split(separator: "-").first.map(
                    String.init
                ),
                sourceFiles: sourceFiles
            )
            invocations.append(invocation)
        }
        var seen = Set<String>()
        return invocations.filter {
            let key = [
                $0.moduleName,
                $0.targetName ?? "",
                $0.architecture ?? "",
                $0.sourceFiles.joined(separator: "\u{0}"),
                $0.analysisArguments.joined(separator: "\u{0}"),
            ].joined(separator: "\u{1F}")
            return seen.insert(key).inserted
        }
    }

    private static func targetContext(
        in line: String
    ) -> (target: String, project: String)? {
        guard let expression = try? NSRegularExpression(
            pattern: #"\(in target '([^']+)' from project '([^']+)'\)"#
        ) else {
            return nil
        }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range),
              let targetRange = Range(match.range(at: 1), in: line),
              let projectRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }
        return (String(line[targetRange]), String(line[projectRange]))
    }

    private static func swiftCommand(
        in line: String
    ) -> (executable: String, arguments: [String])? {
        let marker = "builtin-SwiftDriver -- "
        let commandText: String
        if let range = line.range(of: marker) {
            commandText = String(line[range.upperBound...])
        } else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("/swiftc ")
                    || trimmed.hasPrefix("swiftc ")
            else {
                return nil
            }
            commandText = trimmed
        }
        let words = shellWords(commandText)
        guard let executableIndex = words.firstIndex(where: {
            URL(fileURLWithPath: $0).lastPathComponent == "swiftc"
        }) else {
            return nil
        }
        return (
            words[executableIndex],
            Array(words.dropFirst(executableIndex + 1))
        )
    }

    private static func expandResponseFiles(
        _ arguments: [String],
        artifactRoot: URL,
        depth: Int = 0
    ) -> [String] {
        guard depth < 5 else { return arguments }
        var result: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "-filelist",
               arguments.indices.contains(index + 1)
            {
                let path = arguments[index + 1]
                result.append(contentsOf: responseWords(at: path))
                index += 2
                continue
            }
            if argument.hasPrefix("@") {
                let path = String(argument.dropFirst())
                let file = URL(fileURLWithPath: path).canonicalFileURL
                if file.path.hasPrefix(artifactRoot.path + "/")
                    || FileManager.default.isReadableFile(atPath: file.path)
                {
                    let expanded = responseWords(at: file.path)
                    result.append(
                        contentsOf: expandResponseFiles(
                            expanded,
                            artifactRoot: artifactRoot,
                            depth: depth + 1
                        )
                    )
                    index += 1
                    continue
                }
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    private static func responseWords(at path: String) -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: path
        ),
            let byteCount = attributes[.size] as? NSNumber,
            byteCount.intValue <= 16 * 1_024 * 1_024,
            let source = try? String(contentsOfFile: path, encoding: .utf8)
        else {
            return []
        }
        return shellWords(source)
    }

    private static func sourcePaths(in arguments: [String]) -> [String] {
        var seen = Set<String>()
        return arguments.compactMap { argument in
            guard argument.lowercased().hasSuffix(".swift"),
                  !argument.hasPrefix("-")
            else {
                return nil
            }
            let path = URL(fileURLWithPath: argument)
                .canonicalPath
            return seen.insert(path).inserted ? path : nil
        }.sorted()
    }

    private static func analysisArguments(
        from original: [String],
        sourceFiles: [String]
    ) -> [String] {
        let optionsWithValues: Set<String> = [
            "-emit-module-path",
            "-emit-module-interface-path",
            "-emit-private-module-interface-path",
            "-emit-package-module-interface-path",
            "-emit-objc-header-path",
            "-emit-dependencies-path",
            "-emit-reference-dependencies-path",
            "-serialize-diagnostics-path",
            "-emit-const-values-path",
            "-output-file-map",
            "-supplementary-output-file-map",
            "-index-store-path",
            "-index-unit-output-path",
            "-pch-output-dir",
            "-filelist",
            "-num-threads",
            "-dependency-scan-serialize-diagnostics-path",
            "-const-gather-protocols-list",
        ]
        let standaloneOptions: Set<String> = [
            "-c",
            "-emit-module",
            "-emit-object",
            "-emit-dependencies",
            "-emit-reference-dependencies",
            "-serialize-diagnostics",
            "-incremental",
            "-enable-batch-mode",
            "-use-frontend-parseable-output",
            "-parseable-output",
            "-save-temps",
            "-no-color-diagnostics",
            "-serialize-debugging-options",
            "-frontend",
            "-emit-const-values",
            "-emit-objc-header",
            "-experimental-emit-module-separately",
            "-disable-cmo",
            "-explicit-module-build",
        ]
        let frontendOptionsWithValues: Set<String> = [
            "-const-gather-protocols-file",
        ]
        var result: [String] = [
            "-typecheck",
            "-parse-as-library",
            "-dump-ast",
            "-dump-ast-format", "json",
            "-j1",
        ]
        var index = 0
        while index < original.count {
            let argument = original[index]
            if argument.lowercased().hasSuffix(".swift"),
               !argument.hasPrefix("-")
            {
                index += 1
                continue
            }
            if optionsWithValues.contains(argument) {
                index += 2
                continue
            }
            if standaloneOptions.contains(argument)
                || argument.range(
                    of: #"^-j\d+$"#,
                    options: .regularExpression
                ) != nil
            {
                index += 1
                continue
            }
            if argument == "-module-cache-path" {
                result.append(contentsOf: [
                    "-module-cache-path",
                    "<SWIFTDELTA_MODULE_CACHE>",
                ])
                index += 2
                continue
            }
            if argument == "-Xfrontend",
               original.indices.contains(index + 1),
               frontendOptionsWithValues.contains(original[index + 1])
            {
                if original.indices.contains(index + 3),
                   original[index + 2] == "-Xfrontend"
                {
                    index += 4
                } else {
                    index += 2
                }
                continue
            }
            if argument == "-Xfrontend",
               original.indices.contains(index + 1),
               standaloneOptions.contains(original[index + 1])
            {
                index += 2
                continue
            }
            result.append(argument)
            index += 1
        }
        result.append(contentsOf: sourceFiles)
        return result
    }

    private static func value(
        after option: String,
        in arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }

    static func shellWords(_ value: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character.isWhitespace {
                if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if escaped {
            current.append("\\")
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words
    }
}
