import SwiftUI

struct WeekCalendarToolbar: View {
    @Binding var displayedWeekDate: Date
    let weekInterval: DateInterval
    let calendar: Calendar

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本周会议")
                    .font(.title2.bold())
                Text(dateRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                moveWeek(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("上一周")

            Button("今天") {
                displayedWeekDate = Date()
            }

            Button {
                moveWeek(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("下一周")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var dateRange: String {
        let lastDay = calendar.date(byAdding: .day, value: 6, to: weekInterval.start) ?? weekInterval.start
        let start = weekInterval.start.formatted(.dateTime.month().day())
        let end = lastDay.formatted(.dateTime.month().day())
        return "\(start) - \(end)"
    }

    private func moveWeek(by offset: Int) {
        if let date = calendar.date(byAdding: .day, value: offset * 7, to: displayedWeekDate) {
            displayedWeekDate = date
        }
    }
}
