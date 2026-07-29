import Foundation

public struct PipelineSegmentResult: Equatable, Sendable {
    public var segment: TranscriptSegment
    public var embedding: [Double]

    public init(segment: TranscriptSegment, embedding: [Double]) {
        self.segment = segment
        self.embedding = embedding
    }
}

public struct TranscriptionPipeline<ASR: ASRClient, Voiceprint: VoiceprintClient, Postprocess: PostprocessClient>: Sendable {
    private let asrClient: ASR
    private let voiceprintClient: Voiceprint
    private let postprocessClient: Postprocess
    private let segmentRepository: SegmentRepository
    private var unknownAssigner: UnknownSpeakerAssigner

    public init(
        asrClient: ASR,
        voiceprintClient: Voiceprint,
        postprocessClient: Postprocess,
        segmentRepository: SegmentRepository,
        unknownAssigner: UnknownSpeakerAssigner = UnknownSpeakerAssigner()
    ) {
        self.asrClient = asrClient
        self.voiceprintClient = voiceprintClient
        self.postprocessClient = postprocessClient
        self.segmentRepository = segmentRepository
        self.unknownAssigner = unknownAssigner
    }

    public mutating func process(chunk: AudioChunk, meetingID: String) async throws -> PipelineSegmentResult {
        let asr = try await asrClient.transcribe(chunk: chunk)
        let voiceprint = try await voiceprintClient.identify(chunk: chunk)
        let unknown = unknownAssigner.assign(embedding: voiceprint.embedding)
        let finalText = try await postprocessClient.polish(text: asr.text)
        let segment = TranscriptSegment(
            id: "segment_\(meetingID)_\(chunk.sequence)",
            meetingID: meetingID,
            startMs: asr.startMs,
            endMs: asr.endMs,
            speakerLabel: unknown.label,
            autoSpeakerLabel: unknown.label,
            confidence: voiceprint.confidence,
            rawText: asr.text,
            processedText: finalText,
            finalText: finalText
        )

        try segmentRepository.create(segment)
        return PipelineSegmentResult(segment: segment, embedding: voiceprint.embedding)
    }
}
