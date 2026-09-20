import AItingjiCore
import Foundation
import Testing

@Test
func meetingDefaultsToDraftMicrophone() {
    let meeting = Meeting(id: "m1", title: "周会", createdAt: Date(timeIntervalSince1970: 0))

    #expect(meeting.status == .draft)
    #expect(meeting.captureSource == .microphone)
}

@Test
func voiceprintPersonDefaultsToHiddenFromCalendar() {
    let person = VoiceprintPerson(id: "person-default", displayName: "默认人员")

    #expect(person.isCalendarVisible == false)
}

@Test
func voiceprintPersonLegacyJSONDefaultsCalendarVisibilityToFalse() throws {
    let encoded = try JSONEncoder().encode(
        VoiceprintPerson(
            id: "person-legacy",
            displayName: "旧人员",
            isCalendarVisible: true
        )
    )
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object.removeValue(forKey: "isCalendarVisible")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let restored = try JSONDecoder().decode(VoiceprintPerson.self, from: legacyData)

    #expect(restored.id == "person-legacy")
    #expect(restored.isCalendarVisible == false)
}
