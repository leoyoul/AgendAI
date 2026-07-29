import Foundation

public enum MeetingRecordingTimeline {
    public static let fallbackDuration: TimeInterval = 15 * 60

    public static func beginInterval(
        for meeting: inout Meeting,
        at date: Date
    ) {
        if let openIndex = meeting.recordingIntervals.lastIndex(where: { $0.endedAt == nil }) {
            meeting.recordingIntervals[openIndex].endedAt = max(
                date,
                meeting.recordingIntervals[openIndex].startedAt
            )
        }

        meeting.startedAt = meeting.startedAt ?? date
        meeting.endedAt = nil
        meeting.recordingIntervals.append(
            MeetingRecordingInterval(startedAt: date)
        )
    }

    public static func endInterval(
        for meeting: inout Meeting,
        at date: Date
    ) {
        closeInterval(for: &meeting, at: date)
        if let startedAt = meeting.startedAt {
            meeting.endedAt = max(date, startedAt)
        }
    }

    public static func closeInterval(
        for meeting: inout Meeting,
        at date: Date
    ) {
        guard let openIndex = meeting.recordingIntervals.lastIndex(where: { $0.endedAt == nil }) else {
            return
        }

        meeting.recordingIntervals[openIndex].endedAt = max(
            date,
            meeting.recordingIntervals[openIndex].startedAt
        )
    }

    public static func recovered(
        _ meeting: Meeting,
        endingAt endDate: Date
    ) -> Meeting {
        var recovered = meeting
        guard let startedAt = recovered.startedAt else {
            return recovered
        }

        let end = max(endDate, startedAt)
        if recovered.recordingIntervals.isEmpty {
            recovered.recordingIntervals = [
                MeetingRecordingInterval(
                    startedAt: startedAt,
                    endedAt: end
                )
            ]
        } else {
            for index in recovered.recordingIntervals.indices {
                guard recovered.recordingIntervals[index].endedAt == nil else {
                    continue
                }
                recovered.recordingIntervals[index].endedAt = max(
                    end,
                    recovered.recordingIntervals[index].startedAt
                )
            }
        }
        recovered.endedAt = end
        if recovered.status == .recording {
            recovered.status = .failed
        }
        return recovered
    }

    public static func intervals(
        for meeting: Meeting,
        now: Date,
        isLive: Bool
    ) -> [DateInterval] {
        if !meeting.recordingIntervals.isEmpty {
            return meeting.recordingIntervals.compactMap { interval in
                let end: Date
                if let endedAt = interval.endedAt, endedAt > interval.startedAt {
                    end = endedAt
                } else if isLive,
                          meeting.status == .recording,
                          now > interval.startedAt {
                    end = now
                } else {
                    end = interval.startedAt.addingTimeInterval(fallbackDuration)
                }
                return DateInterval(start: interval.startedAt, end: end)
            }
        }

        guard let start = meeting.startedAt else {
            return []
        }

        let end: Date
        if let endedAt = meeting.endedAt, endedAt > start {
            end = endedAt
        } else if isLive,
                  meeting.status == .recording,
                  now > start {
            end = now
        } else {
            end = start.addingTimeInterval(fallbackDuration)
        }
        return [DateInterval(start: start, end: end)]
    }
}
