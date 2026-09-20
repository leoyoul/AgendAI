import AItingjiCore
import SwiftUI

struct WeekCalendarView: View {
    @Environment(AppState.self) private var appState
    let meetings: [Meeting]
    let activeMeetingID: Meeting.ID?
    @Binding var displayedWeekDate: Date
    let onSelectMeeting: (Meeting.ID) -> Void

    @State private var editingWorkItem: WorkItem?
    @State private var todayScrollRequest = 0
    @State private var visibleWeekStartDate = Date()

    var body: some View {
        if activeMeetingID != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                calendarContent(now: context.date)
            }
        } else {
            calendarContent(now: Date())
        }
    }

    private func calendarContent(now: Date) -> some View {
        let calendar = Calendar.current
        let quarter = MeetingCalendar.quarter(containing: displayedWeekDate, calendar: calendar)
        let calendarPeople = appState.workbenchCalendarPeople
        let scheduledMeetings = meetings.filter { meeting in
            MeetingCalendar.effectiveIntervals(
                for: meeting,
                now: now,
                isLive: meeting.id == activeMeetingID
            ).contains { $0.start < quarter.interval.end && $0.end > quarter.interval.start }
        }
        let visibleWorkItems = appState.calendarReadyWorkItems.filter { item in
            guard let start = item.plannedStartDate ?? item.plannedEndDate,
                  let end = item.plannedEndDate ?? item.plannedStartDate else { return false }
            return WorkItemDate.normalized(start, calendar: calendar) < quarter.interval.end
                && WorkItemDate.normalized(end, calendar: calendar) >= quarter.interval.start
        }

        return VStack(spacing: 0) {
            WeekCalendarToolbar(
                displayedQuarterDate: $displayedWeekDate,
                quarter: quarter,
                calendar: calendar,
                people: appState.people,
                visibleWeekStartDate: visibleWeekStartDate,
                laneMode: Binding(
                    get: { appState.workbenchLaneMode },
                    set: { appState.setWorkbenchLaneMode($0) }
                ),
                workItemFilter: Binding(
                    get: { appState.workItemFilter },
                    set: { appState.workItemFilter = $0 }
                ),
                onToday: {
                    displayedWeekDate = Date()
                    visibleWeekStartDate = Date()
                    todayScrollRequest &+= 1
                },
                onQuarterChange: { date in
                    visibleWeekStartDate = date
                    todayScrollRequest &+= 1
                },
                onCreateWorkItem: {
                    if let id = appState.createManualWorkItem(),
                       let item = appState.workItems.first(where: { $0.id == id }) {
                        editingWorkItem = item
                    }
                }
            )

            WeekTimelineGrid(
                quarter: quarter,
                meetings: scheduledMeetings,
                workItems: visibleWorkItems,
                people: appState.people,
                calendarPeople: calendarPeople,
                participantSnapshots: appState.workbenchMeetingParticipants,
                laneMode: appState.workbenchLaneMode,
                currentUserPersonID: appState.currentUserPersonID,
                visibleWeekStartDate: $visibleWeekStartDate,
                now: now,
                activeMeetingID: activeMeetingID,
                todayScrollRequest: todayScrollRequest,
                onSelectMeeting: onSelectMeeting,
                onSelectWorkItem: { editingWorkItem = $0 },
                onStatusChange: { item, status in
                    _ = appState.setWorkItemStatus(item.id, status: status)
                }
            )
        }
        .onChange(of: displayedWeekDate) { _, newDate in
            let targetQuarter = MeetingCalendar.quarter(containing: newDate, calendar: calendar)
            if !targetQuarter.dates.contains(where: { calendar.isDate($0, inSameDayAs: visibleWeekStartDate) }) {
                visibleWeekStartDate = targetQuarter.interval.start
            }
        }
        .popover(item: $editingWorkItem, arrowEdge: .top) { item in
            WorkItemEditorView(
                item: item,
                people: appState.people,
                onSave: { updated in
                    appState.updateWorkItem(updated) ? nil : appState.statusMessage
                },
                onDelete: {
                    _ = appState.deleteWorkItem(item.id)
                    editingWorkItem = nil
                },
                onOpenSourceMeeting: { meetingID in
                    editingWorkItem = nil
                    onSelectMeeting(meetingID)
                },
                onCancel: { editingWorkItem = nil }
            )
        }
    }
}
