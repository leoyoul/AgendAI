import CoreGraphics

enum AppLayoutMetrics {
    enum Sidebar {
        static let navigationRowHeight: CGFloat = 32
        static let iconSlotWidth: CGFloat = 18
        static let horizontalPadding: CGFloat = 12
        static let navigationRowSpacing: CGFloat = 4
        static let navigationGroupHeight: CGFloat =
            navigationRowHeight * 4 + navigationRowSpacing * 3
        static let meetingRowVerticalPadding: CGFloat = 6
        static let archiveButtonSize: CGFloat = 24
        static let meetingContentSpacing: CGFloat = 3
    }

    enum Workbench {
        static let controlHeight: CGFloat = 28
        static let controlSpacing: CGFloat = 8
        static let toolbarGroupSpacing: CGFloat = 12
        static let toolbarRowSpacing: CGFloat = 8
        static let toolbarActionSpacing: CGFloat = 8
        static let toolbarLegendSpacing: CGFloat = 8
        static let toolbarHorizontalPadding: CGFloat = 20
        static let toolbarVerticalPadding: CGFloat = 10
        static let toolbarDividerHeight: CGFloat = 16
        static let controlCornerRadius: CGFloat = 7
        static let controlHorizontalPadding: CGFloat = 10
        static let controlContentSpacing: CGFloat = 5
        static let segmentedControlPadding: CGFloat = 3
        static let segmentSpacing: CGFloat = 2
    }
}
