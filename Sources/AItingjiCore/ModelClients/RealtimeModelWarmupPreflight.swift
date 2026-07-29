import Foundation

public enum RealtimeModelWarmupError: Error, Equatable, Sendable {
    case missingASR
    case missingVoiceprint
    case invalidASRBaseURL
    case invalidVoiceprintBaseURL
}

public struct RealtimeModelWarmupSources: Equatable, Sendable {
    public var asr: ModelSource
    public var voiceprint: ModelSource

    public init(asr: ModelSource, voiceprint: ModelSource) {
        self.asr = asr
        self.voiceprint = voiceprint
    }
}

public enum RealtimeModelWarmupPreflight {
    public static func validate(
        asr: ModelSource?,
        voiceprint: ModelSource?
    ) throws -> RealtimeModelWarmupSources {
        guard let asr else {
            throw RealtimeModelWarmupError.missingASR
        }
        guard let voiceprint else {
            throw RealtimeModelWarmupError.missingVoiceprint
        }
        guard isCallable(source: asr, allowBuiltIn: false) else {
            throw RealtimeModelWarmupError.invalidASRBaseURL
        }
        guard isCallable(source: voiceprint, allowBuiltIn: true) else {
            throw RealtimeModelWarmupError.invalidVoiceprintBaseURL
        }
        return RealtimeModelWarmupSources(asr: asr, voiceprint: voiceprint)
    }

    private static func isCallable(source: ModelSource, allowBuiltIn: Bool) -> Bool {
        if allowBuiltIn, source.baseURL.hasPrefix("builtin://") {
            return true
        }
        if allowBuiltIn, source.baseURL.hasPrefix("sidecar://") {
            return true
        }
        if source.baseURL.hasPrefix("mock://") {
            return true
        }
        return !source.baseURL.contains("example.com")
    }
}

public enum RealtimeASRWarmupPreflight {
    public static func validate(asr: ModelSource?) throws -> ModelSource {
        guard let asr else {
            throw RealtimeModelWarmupError.missingASR
        }
        guard isCallable(source: asr) else {
            throw RealtimeModelWarmupError.invalidASRBaseURL
        }
        return asr
    }

    private static func isCallable(source: ModelSource) -> Bool {
        if source.baseURL.hasPrefix("mock://") {
            return true
        }
        return !source.baseURL.contains("example.com")
    }
}

extension RealtimeModelWarmupError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingASR:
            return "未配置默认转写模型。"
        case .missingVoiceprint:
            return "未配置默认声纹模型。"
        case .invalidASRBaseURL:
            return "默认转写模型仍是示例地址，请先配置真实 baseURL。"
        case .invalidVoiceprintBaseURL:
            return "默认声纹模型仍是示例地址，请先配置真实 baseURL 或使用本机说话人分离。"
        }
    }
}
