import SwiftUI

struct SidebarNavigationLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(AppTypography.sidebarIcon)
                .frame(width: AppLayoutMetrics.Sidebar.iconSlotWidth)
                .accessibilityHidden(true)

            Text(title)
                .font(AppTypography.navigation)
                .lineLimit(1)
        }
    }
}

struct SidebarNavigationButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovering: Bool
    let isSecondary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor(isPressed: configuration.isPressed), in: shape)
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppLayoutMetrics.Workbench.controlCornerRadius)
    }

    private var foregroundColor: Color {
        if isSelected { return .accentColor }
        if isSecondary { return .secondary }
        return .primary
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.12) }
        if isPressed { return Color.secondary.opacity(0.16) }
        if isHovering { return Color.secondary.opacity(0.10) }
        return .clear
    }
}
