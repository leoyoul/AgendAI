import AItingjiCore
import XCTest
@testable import AItingjiApp

final class MeetingRecordIconPresentationTests: XCTestCase {
    func testAllMeetingStatesHaveVisibleIcons() {
        let presentations = [
            MeetingRecordIconPresentation(activity: .none),
            MeetingRecordIconPresentation(activity: .recording),
            MeetingRecordIconPresentation(activity: .postprocessing),
            MeetingRecordIconPresentation(activity: .recentlyCompleted)
        ]

        XCTAssertTrue(presentations.allSatisfy { !$0.systemImage.isEmpty })
    }

    func testStandardMeetingUsesCalendarIcon() {
        let presentation = MeetingRecordIconPresentation(activity: .none)

        XCTAssertEqual(presentation.systemImage, "calendar")
        XCTAssertFalse(presentation.isPulsing)
    }

    func testRecordingMeetingUsesRedPulsePresentation() {
        let presentation = MeetingRecordIconPresentation(activity: .recording)

        XCTAssertEqual(presentation.systemImage, "record.circle.fill")
        XCTAssertTrue(presentation.isPulsing)
        XCTAssertTrue(presentation.accessibilityLabel.contains("录音"))
    }

    func testProcessingAndCompletedMeetingsDoNotPulse() {
        XCTAssertFalse(
            MeetingRecordIconPresentation(activity: .postprocessing).isPulsing
        )
        XCTAssertFalse(
            MeetingRecordIconPresentation(activity: .recentlyCompleted).isPulsing
        )
    }
}
