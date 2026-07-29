import Foundation

public enum VoiceprintModelMigration {
    public static let bundledSidecarID = "builtin-diarization-sidecar"
    public static let sidecarModel = "funasr-paraformer-zh+fsmn-vad+ct-punc+cam++ + speechbrain-ecapa"
    public static let legacySidecarModels = [
        "funasr-paraformer-zh+fsmn-vad+ct-punc+cam++",
        "pyannote/speaker-diarization-community-1+speechbrain/spkrec-ecapa-voxceleb"
    ]
    private static let staleConfigOnlyMessage = "本机说话人分离 sidecar 可配置，首次真实模型加载需要 Hugging Face token。"

    public static func restoreBundledSidecar(_ sources: [ModelSource]) -> [ModelSource] {
        var restored = migrateDefaultBuiltInToDiarization(sources)
        restored = migrateSidecarModelToFunASR(restored)
        restored = clearStaleDiarizationTestResult(restored)
        guard !restored.contains(where: {
            $0.type == .voiceprint && $0.baseURL == "sidecar://diarization"
        }) else {
            return restored
        }

        let hasEnabledDefault = restored.contains {
            $0.type == .voiceprint && $0.enabled && $0.isDefault
        }
        restored.append(ModelSource(
            id: bundledSidecarID,
            type: .voiceprint,
            name: "本机说话人分离与声纹识别",
            baseURL: "sidecar://diarization",
            selectedModel: sidecarModel,
            availableModels: [sidecarModel],
            isDefault: !hasEnabledDefault,
            enabled: true
        ))
        return restored
    }

    public static func migrateDefaultBuiltInToDiarization(_ sources: [ModelSource]) -> [ModelSource] {
        guard !hasExternalDefaultVoiceprint(in: sources) else {
            return sources
        }

        var migrated = sources
        for index in migrated.indices where migrated[index].type == .voiceprint
            && migrated[index].isDefault
            && migrated[index].baseURL == "builtin://voiceprint" {
            migrated[index].name = "本机说话人分离"
            migrated[index].baseURL = "sidecar://diarization"
            migrated[index].apiKey = ""
            migrated[index].selectedModel = sidecarModel
            migrated[index].availableModels = [sidecarModel]
            migrated[index].enabled = true
        }
        return migrated
    }

    public static func migrateSidecarModelToFunASR(_ sources: [ModelSource]) -> [ModelSource] {
        var migrated = sources
        for index in migrated.indices where migrated[index].type == .voiceprint
            && migrated[index].baseURL == "sidecar://diarization"
            && migrated[index].selectedModel != sidecarModel {
            migrated[index].selectedModel = sidecarModel
            migrated[index].availableModels = [sidecarModel]
            migrated[index].lastTestOK = nil
            migrated[index].lastTestMessage = nil
            migrated[index].lastTestAt = nil
        }
        return migrated
    }

    public static func clearStaleDiarizationTestResult(_ sources: [ModelSource]) -> [ModelSource] {
        var migrated = sources
        for index in migrated.indices where migrated[index].type == .voiceprint
            && migrated[index].baseURL == "sidecar://diarization"
            && migrated[index].lastTestOK == true
            && migrated[index].lastTestMessage == staleConfigOnlyMessage {
            migrated[index].lastTestOK = nil
            migrated[index].lastTestMessage = nil
            migrated[index].lastTestAt = nil
        }
        return migrated
    }

    private static func hasExternalDefaultVoiceprint(in sources: [ModelSource]) -> Bool {
        sources.contains { source in
            source.type == .voiceprint
                && source.isDefault
                && source.enabled
                && source.baseURL != "builtin://voiceprint"
                && source.baseURL != "sidecar://diarization"
        }
    }
}
