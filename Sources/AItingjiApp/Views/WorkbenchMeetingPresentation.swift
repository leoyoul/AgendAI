import AItingjiCore

/// The workbench keeps the user's selected people view stable while allowing an
/// unmatched live recording to be attributed to the current user's visible lane.
enum WorkbenchMeetingRouting {
    static func belongs(
        meetingID: Meeting.ID,
        participantPersonIDs: [VoiceprintPerson.ID],
        lanePersonID: VoiceprintPerson.ID?,
        laneMode: WorkbenchLaneMode,
        activeMeetingID: Meeting.ID?,
        currentUserPersonID: VoiceprintPerson.ID?
    ) -> Bool {
        guard laneMode == .people, let lanePersonID else {
            return laneMode == .mixed
        }

        if participantPersonIDs.contains(lanePersonID) {
            return true
        }

        return meetingID == activeMeetingID
            && participantPersonIDs.isEmpty
            && currentUserPersonID == lanePersonID
    }
}

enum WorkbenchMeetingActivity: Equatable {
    case scheduled
    case recording

    init(meeting: Meeting, activeMeetingID: Meeting.ID?) {
        self = meeting.id == activeMeetingID && meeting.status == .recording
            ? .recording
            : .scheduled
    }

    var isRecording: Bool {
        self == .recording
    }

    var label: String {
        isRecording ? "录制中" : "会议"
    }

    var systemImage: String {
        isRecording ? "record.circle.fill" : "circle.fill"
    }
}
