import Foundation

public struct LiveTranscriptionCoordinator<ASR: ASRClient, Voiceprint: VoiceprintClient, Postprocess: PostprocessClient>: Sendable {
    private let meetingID: Meeting.ID
    private var pipeline: TranscriptionPipeline<ASR, Voiceprint, Postprocess>

    public init(
        meetingID: Meeting.ID,
        asrClient: ASR,
        voiceprintClient: Voiceprint,
        postprocessClient: Postprocess,
        segmentRepository: SegmentRepository
    ) {
        self.meetingID = meetingID
        self.pipeline = TranscriptionPipeline(
            asrClient: asrClient,
            voiceprintClient: voiceprintClient,
            postprocessClient: postprocessClient,
            segmentRepository: segmentRepository
        )
    }

    public mutating func process(chunk: AudioChunk) async throws -> PipelineSegmentResult {
        try await pipeline.process(chunk: chunk, meetingID: meetingID)
    }
}
