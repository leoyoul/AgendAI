import AItingjiCore
import SwiftUI

struct SidebarNavigationGroup: View {
    let selectedDestination: WorkspaceDestination
    let pendingWorkItemCount: Int
    let isPersistenceAvailable: Bool
    let onSelectDestination: (WorkspaceDestination) -> Void
    let onCreateMeeting: () -> Void

    var body: some View {
        VStack(spacing: AppLayoutMetrics.Sidebar.navigationRowSpacing) {
            SidebarNavigationRow(
                title: "新建会议",
                systemImage: "plus",
                isSelected: false,
                isSecondary: true,
                isEnabled: isPersistenceAvailable,
                action: onCreateMeeting
            )

            SidebarNavigationRow(
                title: "工作台",
                systemImage: WorkspaceDestination.calendar.systemImage,
                isSelected: selectedDestination == .calendar,
                action: { onSelectDestination(.calendar) }
            )

            SidebarNavigationRow(
                title: "待办任务池",
                systemImage: WorkspaceDestination.workItemPool.systemImage,
                badge: pendingWorkItemCount,
                isSelected: selectedDestination == .workItemPool,
                action: { onSelectDestination(.workItemPool) }
            )

            SidebarNavigationRow(
                title: "设置",
                systemImage: WorkspaceDestination.settings.systemImage,
                isSelected: selectedDestination == .settings,
                action: { onSelectDestination(.settings) }
            )
        }
        .padding(.horizontal, AppLayoutMetrics.Sidebar.horizontalPadding)
        .frame(maxWidth: .infinity)
        .frame(height: AppLayoutMetrics.Sidebar.navigationGroupHeight)
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let badge: Int?
    let isSelected: Bool
    let isSecondary: Bool
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovering = false

    init(
        title: String,
        systemImage: String,
        badge: Int? = nil,
        isSelected: Bool,
        isSecondary: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.isSelected = isSelected
        self.isSecondary = isSecondary
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppLayoutMetrics.Sidebar.navigationRowSpacing + 4) {
                SidebarNavigationLabel(title: title, systemImage: systemImage)

                Spacer(minLength: 0)

                if let badge, badge > 0 {
                    Text("\(badge)")
                        .font(AppTypography.workbenchControl.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.14), in: Capsule())
                        .accessibilityLabel("待确认任务 \(badge) 个")
                }
            }
        }
        .buttonStyle(
            SidebarNavigationButtonStyle(
                isSelected: isSelected,
                isHovering: isHovering,
                isSecondary: isSecondary
            )
        )
        .frame(maxWidth: .infinity)
        .frame(height: AppLayoutMetrics.Sidebar.navigationRowHeight)
        .disabled(!isEnabled)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onHover { isHovering = $0 }
    }
}
