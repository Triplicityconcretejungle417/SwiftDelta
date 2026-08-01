//===--- ConfigurationLoader.swift - SwiftDelta ------------------------------------------===//
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

public enum ConfigurationLoader {
    public static func load(
        projectRoot: URL,
        explicitURL: URL? = nil
    ) throws -> SwiftDeltaConfiguration {
        let url = explicitURL ?? projectRoot.appendingPathComponent(".swiftdelta.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            if explicitURL != nil {
                throw SwiftDeltaError.invalidConfiguration(
                    field: "configuration",
                    reason: "file does not exist at \(url.path)"
                )
            }
            return SwiftDeltaConfiguration()
        }

        do {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let configuration = try JSONDecoder().decode(SwiftDeltaConfiguration.self, from: data)
            try configuration.validate()
            return configuration
        } catch let error as SwiftDeltaError {
            throw error
        } catch let error as DecodingError {
            let details = error.swiftDeltaDescription
            throw SwiftDeltaError.invalidConfiguration(
                field: details.field,
                reason: details.reason
            )
        } catch {
            throw SwiftDeltaError.invalidConfiguration(
                field: "configuration",
                reason: error.localizedDescription
            )
        }
    }
}
