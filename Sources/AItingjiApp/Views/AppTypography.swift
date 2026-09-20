import SwiftUI

enum AppTypography {
    static let brand = Font.title3.weight(.semibold)
    static let brandVersion = Font.caption.weight(.medium)
    static let navigation = Font.body.weight(.medium)
    static let section = Font.caption.weight(.semibold)
    static let meetingTitle = Font.callout.weight(.medium)
    static let meetingMetadata = Font.caption.monospacedDigit()
    static let workbenchTitle = Font.title2.weight(.semibold)
    static let workbenchSubtitle = Font.caption.monospacedDigit()
    static let workbenchControl = Font.caption
    static let workbenchLegend = Font.caption2
    static let sidebarIcon = Font.system(size: 14, weight: .medium)
    static let meetingIcon = Font.system(size: 13, weight: .medium)
}
