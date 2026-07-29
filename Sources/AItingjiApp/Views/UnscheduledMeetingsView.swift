import AItingjiCore
import SwiftUI

struct UnscheduledMeetingsView: View {
    let meetings: [Meeting]
    let onSelectMeeting: (Meeting.ID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("未安排时间", systemImage: "tray")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(meetings) { meeting in
                        Button {
                            onSelectMeeting(meeting.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(meeting.title)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text(meeting.createdAt.formatted(.dateTime.weekday().hour().minute()))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 180, alignment: .leading)
                            .padding(9)
                            .background(itemColor(meeting).opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(itemColor(meeting).opacity(0.3), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func itemColor(_ meeting: Meeting) -> Color {
        meeting.isArchived ? .green : .secondary
    }
}
