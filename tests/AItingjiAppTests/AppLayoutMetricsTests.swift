import XCTest
@testable import AItingjiApp

final class AppLayoutMetricsTests: XCTestCase {
    func testSidebarNavigationUsesOneSharedRowHeightAndIconSlot() {
        XCTAssertEqual(AppLayoutMetrics.Sidebar.navigationRowHeight, 32)
        XCTAssertEqual(AppLayoutMetrics.Sidebar.iconSlotWidth, 18)
        XCTAssertEqual(AppLayoutMetrics.Sidebar.archiveButtonSize, 24)
        XCTAssertEqual(AppLayoutMetrics.Sidebar.navigationRowSpacing, 4)
        XCTAssertEqual(
            AppLayoutMetrics.Sidebar.navigationGroupHeight,
            AppLayoutMetrics.Sidebar.navigationRowHeight * 4
                + AppLayoutMetrics.Sidebar.navigationRowSpacing * 3
        )
    }

    func testWorkbenchControlsUseOneSharedHeightAndSpacing() {
        XCTAssertEqual(AppLayoutMetrics.Workbench.controlHeight, 28)
        XCTAssertEqual(AppLayoutMetrics.Workbench.controlSpacing, 8)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarGroupSpacing, 12)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarRowSpacing, 8)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarActionSpacing, 8)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarLegendSpacing, 8)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarHorizontalPadding, 20)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarVerticalPadding, 10)
        XCTAssertEqual(AppLayoutMetrics.Workbench.toolbarDividerHeight, 16)
        XCTAssertEqual(AppLayoutMetrics.Workbench.controlHorizontalPadding, 10)
        XCTAssertEqual(AppLayoutMetrics.Workbench.controlContentSpacing, 5)
        XCTAssertEqual(AppLayoutMetrics.Workbench.segmentedControlPadding, 3)
        XCTAssertEqual(AppLayoutMetrics.Workbench.segmentSpacing, 2)
    }
}
