//===--- AppleFoundationModelRepairProvider.swift - SwiftDelta ------------------------------------------===//
//
// This source file is part of the SwiftDelta open source project
//
// Copyright (c) 2026 Jiaxu Li
// Licensed under the Apache License, Version 2.0
//
// See LICENSE for license information
//
//===----------------------------------------------------------------------===//

#if canImport(FoundationModels)
import Foundation
import FoundationModels

@available(macOS 26.0, *)
@Generable
private struct AppleGeneratedRepairEdit {
    @Guide(
        description: "The exact source operation.",
        .anyOf(["replace", "insertBefore", "insertAfter", "delete"])
    )
    var operation: String

    @Guide(
        description:
            "A nonempty exact substring copied from the supplied source. It "
            + "anchors the replacement, insertion, or deletion."
    )
    var originalAnchor: String

    @Guide(
        description:
            "Only the replacement or inserted source. Empty only for delete."
    )
    var source: String
}

@available(macOS 26.0, *)
@Generable
private struct AppleGeneratedRepairProposal {
    @Guide(
        description:
            "applicable only for exact evidence-backed edits; "
            + "reviewOnly for a concrete suggestion with unresolved risk; "
            + "notRepairable when evidence is insufficient.",
        .anyOf(["applicable", "reviewOnly", "notRepairable"])
    )
    var disposition: String

    @Guide(
        description:
            "A bounded ordered set of exact anchored source edits. Empty when "
            + "disposition is notRepairable.",
        .maximumCount(8)
    )
    var edits: [AppleGeneratedRepairEdit]

    @Guide(
        description:
            "The complete modified allowed source fragment as one source line "
            + "per array element. Use this for coordinated or structural "
            + "migrations. Preserve the declaration and unrelated source. For "
            + "notRepairable, copy the supplied source unchanged.",
        .minimumCount(1),
        .maximumCount(160)
    )
    var revisedSourceLines: [String]

    @Guide(description: "A concise explanation based only on supplied evidence.")
    var explanation: String

    @Guide(
        description: "Any assumptions required by the proposal; empty when none.",
        .maximumCount(6)
    )
    var assumptions: [String]

    @Guide(
        description: "Unresolved safety or compatibility risks; empty when none.",
        .maximumCount(6)
    )
    var unresolvedRisks: [String]
}

struct AppleFoundationModelRepairProvider: FoundationModelRepairProviding {
    private let operatingSystemVersion: OperatingSystemVersion

    init(
        operatingSystemVersion: OperatingSystemVersion =
            ProcessInfo.processInfo.operatingSystemVersion
    ) {
        self.operatingSystemVersion = operatingSystemVersion
    }

    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus {
        guard let generation = FoundationModelHostGeneration.detect(
            operatingSystemVersion
        ) else {
            return FoundationModelProviderStatus(
                availability: .unsupportedOperatingSystem,
                generation: nil,
                reasoningLevel: "unsupported",
                supportsTokenCounting: false
            )
        }
        guard #available(macOS 26.0, *) else {
            return FoundationModelProviderStatus(
                availability: .unsupportedOperatingSystem,
                generation: generation,
                reasoningLevel: "unsupported",
                supportsTokenCounting: false
            )
        }
        return onDeviceStatus(
            generation: generation,
            requestedReasoning: options.reasoningLevel
        )
    }

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget? {
        let providerStatus = status(options: options)
        guard providerStatus.availability == .available else {
            throw FoundationModelRepairError.unavailable(
                providerStatus.availability
            )
        }
        guard providerStatus.supportsTokenCounting,
              #available(macOS 26.4, *)
        else {
            return nil
        }
        let definition = try promptDefinition()
        let prompt = definition.prompt(for: context)
        return try FoundationModelAsyncBridge.run(
            timeout: options.timeout,
            cancellation: cancellation
        ) {
            let model = SystemLanguageModel.default
            let tokenCount = try await model.tokenCount(
                for: definition.instructions + "\n" + prompt
            )
            return FoundationModelContextBudget(
                tokenCount: tokenCount,
                contextSize: model.contextSize
            )
        }
    }

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        let providerStatus = status(options: options)
        guard providerStatus.availability == .available else {
            throw FoundationModelRepairError.unavailable(
                providerStatus.availability
            )
        }
        guard let generation = providerStatus.generation else {
            throw FoundationModelRepairError.unavailable(
                .unsupportedOperatingSystem
            )
        }
        if generation != .macOS27, let requested = options.reasoningLevel {
            throw FoundationModelRepairError.unsupportedReasoning(
                requested: requested,
                generation: generation
            )
        }
        guard #available(macOS 26.0, *) else {
            throw FoundationModelRepairError.unavailable(
                .unsupportedOperatingSystem
            )
        }
        let definition = try promptDefinition()
        let prompt = definition.prompt(for: context)
        let generated = try FoundationModelAsyncBridge.run(
            timeout: options.timeout,
            cancellation: cancellation
        ) {
            do {
                return try await generateOnDevice(
                    prompt: prompt,
                    instructions: definition.instructions,
                    reasoningLevel: providerStatus.reasoningLevel
                )
            } catch let error as FoundationModelRepairError {
                throw error
            } catch {
                throw mapFoundationModelError(
                    error,
                    effectiveTimeout: options.timeout
                )
            }
        }
        return (try modelProposal(generated, context: context), providerStatus)
    }

    @available(macOS 26.0, *)
    private func onDeviceStatus(
        generation: FoundationModelHostGeneration,
        requestedReasoning: FoundationModelReasoningLevel?
    ) -> FoundationModelProviderStatus {
        let model = SystemLanguageModel.default
        let availability = availabilityState(model.availability)
        guard availability == .available else {
            return FoundationModelProviderStatus(
                availability: availability,
                generation: generation,
                reasoningLevel: "unsupported",
                supportsTokenCounting: generation != .macOS26_0To26_3
            )
        }
        guard model.supportsLocale(Locale.current) else {
            return FoundationModelProviderStatus(
                availability: .unsupportedLanguageOrLocale,
                generation: generation,
                reasoningLevel: "unsupported",
                supportsTokenCounting: generation != .macOS26_0To26_3
            )
        }
        if #available(macOS 27.0, *), generation == .macOS27 {
            guard model.capabilities.contains(.guidedGeneration) else {
                return FoundationModelProviderStatus(
                    availability: .unsupportedCapability("guided generation"),
                    generation: generation,
                    reasoningLevel: "unsupported",
                    supportsTokenCounting: true
                )
            }
            let supportsReasoning = model.capabilities.contains(.reasoning)
            let reasoning: String
            do {
                reasoning = try FoundationModelReasoningResolver.resolve(
                    generation: generation,
                    supportsReasoning: supportsReasoning,
                    requested: requestedReasoning
                )
            } catch {
                return FoundationModelProviderStatus(
                    availability: .unsupportedCapability(
                        requestedReasoning.map {
                            "\($0.rawValue) reasoning"
                        } ?? "configurable reasoning"
                    ),
                    generation: generation,
                    reasoningLevel: "unsupported",
                    supportsTokenCounting: true
                )
            }
            return FoundationModelProviderStatus(
                availability: .available,
                generation: generation,
                reasoningLevel: reasoning,
                supportsTokenCounting: true
            )
        }
        return FoundationModelProviderStatus(
            availability: requestedReasoning == nil
                ? .available
                : .unsupportedCapability(
                    "configurable reasoning on \(generation.rawValue)"
                ),
            generation: generation,
            reasoningLevel: "unsupported",
            supportsTokenCounting: generation == .macOS26_4
        )
    }

    @available(macOS 26.0, *)
    private func generateOnDevice(
        prompt: String,
        instructions: String,
        reasoningLevel: String
    ) async throws -> AppleGeneratedRepairProposal {
        let model = SystemLanguageModel.default
        let session = LanguageModelSession(
            model: model,
            tools: [],
            instructions: instructions
        )
        let options = GenerationOptions(
            samplingMode: .greedy,
            maximumResponseTokens:
                FoundationModelContextBudget.responseTokenAllowance
        )
        if #available(macOS 27.0, *), reasoningLevel != "unsupported" {
            let response = try await session.respond(
                to: prompt,
                generating: AppleGeneratedRepairProposal.self,
                options: options,
                contextOptions: ContextOptions(
                    includeSchemaInPrompt: true,
                    reasoningLevel: reasoning(reasoningLevel)
                )
            )
            return response.content
        }
        let response = try await session.respond(
            to: prompt,
            generating: AppleGeneratedRepairProposal.self,
            includeSchemaInPrompt: true,
            options: options
        )
        return response.content
    }

    @available(macOS 27.0, *)
    private func reasoning(
        _ value: String
    ) -> ContextOptions.ReasoningLevel {
        switch value {
        case FoundationModelReasoningLevel.light.rawValue:
            .light
        case FoundationModelReasoningLevel.moderate.rawValue:
            .moderate
        default:
            .deep
        }
    }

    @available(macOS 26.0, *)
    private func availabilityState(
        _ availability: SystemLanguageModel.Availability
    ) -> FoundationModelAvailabilityState {
        switch availability {
        case .available:
            .available
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                .unsupportedHardware
            case .appleIntelligenceNotEnabled:
                .appleIntelligenceDisabled
            case .modelNotReady:
                .modelNotReady
            @unknown default:
                .modelNotReady
            }
        }
    }

    private func promptDefinition() throws -> FoundationModelPromptDefinition {
        guard let definition = FoundationModelPromptDefinition.select(
            for: operatingSystemVersion
        ) else {
            throw FoundationModelRepairError.unavailable(
                .unsupportedOperatingSystem
            )
        }
        return definition
    }

    @available(macOS 26.0, *)
    private func modelProposal(
        _ generated: AppleGeneratedRepairProposal,
        context: RepairContext
    ) throws -> ModelRepairProposal {
        let disposition: ModelRepairDisposition
        switch generated.disposition {
        case "applicable":
            disposition = .repairable
        case "reviewOnly":
            disposition = .reviewRequired
        case "notRepairable":
            disposition = .notRepairable
        default:
            throw FoundationModelRepairError.invalidStructuredOutput(
                "the repair disposition was not recognized"
            )
        }
        let anchoredEdits = try generated.edits.map { edit in
            guard let operation = ModelRepairEditOperation(
                rawValue: edit.operation
            ) else {
                throw FoundationModelRepairError.invalidStructuredOutput(
                    "an edit operation was not recognized"
                )
            }
            return ModelRepairEdit(
                operation: operation,
                sourceFileIdentity: context.filePath,
                originalAnchor: edit.originalAnchor,
                source: edit.source
            )
        }
        let revised = generated.revisedSourceLines.joined(separator: "\n")
        let edits: [ModelRepairEdit]
        if !revised.isEmpty, revised != context.sourceFragment {
            // The file identity and permitted range are program-owned. A full
            // fragment replacement gives guided generation a reliable way to
            // express coordinated syntax changes without asking it to repeat
            // byte offsets or opaque internal identities.
            edits = [
                ModelRepairEdit(
                    operation: .replace,
                    sourceFileIdentity: context.filePath,
                    originalAnchor: context.sourceFragment,
                    source: revised
                ),
            ]
        } else {
            edits = anchoredEdits
        }
        return ModelRepairProposal(
            disposition: disposition,
            sourceFileIdentity: context.filePath,
            sourceLanguage: context.language,
            edits: edits,
            explanation: generated.explanation,
            confidence: context.evidenceLevel == .diagnosticBacked
                ? .medium : .low,
            evidenceUsed: modelEvidence(from: context),
            assumptions: generated.assumptions,
            unresolvedRisks: generated.unresolvedRisks
        )
    }

    private func modelEvidence(from context: RepairContext) -> [String] {
        var evidence = context.sdkDifferences
        evidence.append(contentsOf: context.compilerFixItEvidence)
        if let diagnostic = context.diagnostic {
            evidence.append(
                "Compiler \(diagnostic.severity.rawValue): \(diagnostic.message)"
            )
        }
        return Array(Set(evidence)).sorted()
    }

    private func mapFoundationModelError(
        _ error: any Error,
        effectiveTimeout: TimeInterval
    ) -> FoundationModelRepairError {
        if error is CancellationError {
            return .cancelled
        }
        if #available(macOS 27.0, *),
           let modelError = error as? LanguageModelError
        {
            switch modelError {
            case .contextSizeExceeded:
                return .contextSizeExceeded(tokenCount: nil, contextSize: nil)
            case .guardrailViolation, .refusal:
                return .guardrailRejected
            case .unsupportedCapability:
                return .unsupportedCapability(
                    modelError.localizedDescription
                )
            case .unsupportedGenerationGuide:
                return .unsupportedCapability("the requested generation guide")
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguageOrLocale
            case .timeout:
                return .timedOut(effectiveTimeout)
            case .rateLimited, .unsupportedTranscriptContent:
                return .generationFailed(modelError.localizedDescription)
            @unknown default:
                return .generationFailed(modelError.localizedDescription)
            }
        }
        if #available(macOS 27.0, *),
           let sessionError = error as? LanguageModelSession.Error
        {
            switch sessionError {
            case .concurrentRequests, .transcriptMutationWhileResponding:
                return .concurrentSessionUse
            @unknown default:
                return .concurrentSessionUse
            }
        }
        if #available(macOS 26.0, *),
           let generationError = error as? LanguageModelSession.GenerationError
        {
            switch generationError {
            case .exceededContextWindowSize:
                return .contextSizeExceeded(tokenCount: nil, contextSize: nil)
            case .assetsUnavailable:
                return .unavailable(.modelNotReady)
            case .guardrailViolation, .refusal:
                return .guardrailRejected
            case .unsupportedGuide:
                return .unsupportedCapability("the requested generation guide")
            case .unsupportedLanguageOrLocale:
                return .unsupportedLanguageOrLocale
            case .concurrentRequests:
                return .concurrentSessionUse
            case .decodingFailure:
                return .invalidStructuredOutput(
                    generationError.localizedDescription
                )
            case .rateLimited:
                return .generationFailed(
                    generationError.localizedDescription
                )
            @unknown default:
                return .generationFailed(
                    generationError.localizedDescription
                )
            }
        }
        return .generationFailed(error.localizedDescription)
    }
}

private enum FoundationModelAsyncBridge {
    static func run<Value: Sendable>(
        timeout: TimeInterval,
        cancellation: @escaping @Sendable () -> Bool,
        operation: @escaping @Sendable () async throws -> Value
    ) throws -> Value {
        let box = FoundationModelAsyncResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do {
                box.store(.success(try await operation()))
            } catch let error as FoundationModelRepairError {
                box.store(.failure(error))
            } catch is CancellationError {
                box.store(.failure(.cancelled))
            } catch {
                box.store(
                    .failure(.generationFailed(error.localizedDescription))
                )
            }
            semaphore.signal()
        }
        let start = Date()
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if cancellation() {
                box.invalidate()
                task.cancel()
                throw FoundationModelRepairError.cancelled
            }
            if Date().timeIntervalSince(start) >= timeout {
                box.invalidate()
                task.cancel()
                throw FoundationModelRepairError.timedOut(timeout)
            }
        }
        guard let result = box.load() else {
            throw FoundationModelRepairError.invalidStructuredOutput(
                "the session completed without a result"
            )
        }
        return try result.get()
    }
}

private final class FoundationModelAsyncResultBox<Value: Sendable>:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var result: Result<Value, FoundationModelRepairError>?
    private var acceptsResult = true

    func store(_ value: Result<Value, FoundationModelRepairError>) {
        lock.withLock {
            if acceptsResult {
                result = value
            }
        }
    }

    func load() -> Result<Value, FoundationModelRepairError>? {
        lock.withLock { result }
    }

    func invalidate() {
        lock.withLock {
            acceptsResult = false
            result = nil
        }
    }
}
#else
import Foundation

struct AppleFoundationModelRepairProvider: FoundationModelRepairProviding {
    func status(
        options: FoundationModelRepairOptions
    ) -> FoundationModelProviderStatus {
        FoundationModelProviderStatus(
            availability: .unsupportedOperatingSystem,
            generation: nil,
            reasoningLevel: "unsupported",
            supportsTokenCounting: false
        )
    }

    func contextBudget(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> FoundationModelContextBudget? {
        throw FoundationModelRepairError.unavailable(
            .unsupportedOperatingSystem
        )
    }

    func propose(
        for context: RepairContext,
        options: FoundationModelRepairOptions,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> (ModelRepairProposal, FoundationModelProviderStatus) {
        throw FoundationModelRepairError.unavailable(
            .unsupportedOperatingSystem
        )
    }
}
#endif
