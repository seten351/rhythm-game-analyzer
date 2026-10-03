import AppKit
import SwiftUI

/// Same five-column library, using AppKit's row drawing hook for a quiet selection.
/// Native selection, scrolling, keyboard navigation and accessibility stay intact.
struct BrandLibraryTable: NSViewRepresentable {
    let rows: [LibraryChartRow]
    @Binding var selectedID: UUID?
    let palette: AppPalette
    let width: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.selectionHighlightStyle = .regular
        table.rowHeight = 54
        table.intercellSpacing = NSSize(width: 8, height: 1)
        table.usesAlternatingRowBackgroundColors = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for (index, title) in ["曲名 / 難易度", "Lv.", "達成", "最高スコア", "回数"].enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = title
            column.minWidth = index == 0 ? 130 : [0, 34, 80, 94, 34][index]
            column.width = column.minWidth
            column.resizingMask = index == 0 ? .autoresizingMask : []
            table.addTableColumn(column)
        }
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.setAccessibilityIdentifier("library.table")
        table.setAccessibilityLabel("楽曲・譜面")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.parent = self
        context.coordinator.updating = true
        defer { context.coordinator.updating = false }
        let selectionChanged = context.coordinator.lastSelectedID != selectedID
        table.backgroundColor = NSColor(palette.surface)
        table.tableColumns[0].width = max(130, width - 370)
        let origin = scroll.contentView.bounds.origin
        table.reloadData()
        if let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        table.enumerateAvailableRowViews { row, _ in
            (row as? BrandTableRow)?.selectionColor = NSColor(palette.brand.selection)
            row.needsDisplay = true
        }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if selectionChanged, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.scrollRowToVisible(index) }
        context.coordinator.lastSelectedID = selectedID
        DispatchQueue.main.async { [weak table] in table?.headerView?.needsDisplay = true }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: BrandLibraryTable
        var updating = false
        var lastSelectedID: UUID?
        init(_ parent: BrandLibraryTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let column = tableColumn,
                  let index = Int(column.identifier.rawValue) else { return nil }
            let cell = BrandLibraryCell(row: parent.rows[row], column: index,
                                       selected: parent.rows[row].id == parent.selectedID,
                                       palette: parent.palette)
            if let host = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSHostingView<BrandLibraryCell> {
                host.rootView = cell; return host
            }
            let host = NSHostingView(rootView: cell)
            host.identifier = column.identifier
            return host
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            BrandTableRow(selectionColor: NSColor(parent.palette.brand.selection))
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let next = parent.rows.indices.contains(table.selectedRow) ? parent.rows[table.selectedRow].id : nil
            if parent.selectedID != next { parent.selectedID = next }
        }
    }
}

private final class BrandTableRow: NSTableRowView {
    var selectionColor: NSColor
    init(selectionColor: NSColor) { self.selectionColor = selectionColor; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
}

private struct BrandLibraryCell: View {
    let row: LibraryChartRow
    let column: Int
    let selected: Bool
    let palette: AppPalette
    var body: some View {
        Group {
            switch column {
            case 0:
                HStack(spacing: 7) {
                    BrandAccentMark(color: selected ? palette.brand.noteBlue.color : .clear).frame(height: 27)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.song.title).font(.callout.weight(.medium)).lineLimit(1).help(row.song.title)
                        HStack(spacing: 7) {
                            Text(row.chart.difficulty)
                            if row.song.provisional { Text("マスタ未照合").foregroundStyle(.orange) }
                            if row.isArchived { Text("アーカイブ") }
                        }.font(.caption).foregroundStyle(palette.brand.secondaryText.color).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            case 1: Text(row.chart.level.map(String.init) ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
            case 2: LibraryAchievementLabel(row: row).frame(maxWidth: .infinity, alignment: .leading)
            case 3: Text(row.bestPlay?.score.formatted() ?? "—").monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            default: Text(row.plays.count.formatted()).monospacedDigit().foregroundStyle(palette.brand.secondaryText.color).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.foregroundStyle(Color(nsColor: .labelColor)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.appPalette, palette)
    }
}
