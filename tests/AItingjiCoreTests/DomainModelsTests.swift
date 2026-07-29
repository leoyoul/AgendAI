import AItingjiCore
import Foundation
import Testing

@Test
func meetingDefaultsToDraftMicrophone() {
    let meeting = Meeting(id: "m1", title: "周会", createdAt: Date(timeIntervalSince1970: 0))

    #expect(meeting.status == .draft)
    #expect(meeting.captureSource == .microphone)
}
