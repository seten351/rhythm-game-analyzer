import AppKit
import SwiftUI
import QuartzCore

/// Same five-column library, with a stationary selection that fades in place.
/// Native selection, scrolling, keyboard navigation and accessibility stay intact.
struct BrandLibraryTable: NSViewRepresentable {
    let rows: [LibraryChartRow]
    @Binding var selectedID: UUID?
    let palette: AppPalette
    let width: CGFloat
    let artwork: SongArtworkStore
    @BrandReduceMotion private var reduceMotion

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
        let sameRows = context.coordinator.lastRowIDs == rows.map(\.id)
        context.coordinator.animateSelection = selectionChanged && sameRows &&
            context.coordinator.lastSelectedID != nil && BrandMotion.isEnabled(theme: palette.theme, reduceMotion: reduceMotion)
        table.backgroundColor = NSColor(palette.surface)
        table.tableColumns[0].width = max(130, width - 370)
        let origin = scroll.contentView.bounds.origin
        if !sameRows {
            table.reloadData()
        } else {
            // Keeping hosted cells mounted lets a score increase retain its identity.
            table.enumerateAvailableRowViews { _, rowIndex in
                for columnIndex in table.tableColumns.indices {
                    if let host = table.view(atColumn: columnIndex, row: rowIndex, makeIfNecessary: false) as? NSHostingView<BrandLibraryCell> {
                        host.rootView = context.coordinator.cell(row: rowIndex, column: columnIndex)
                    }
                }
            }
        }
        table.enumerateAvailableRowViews { row, _ in context.coordinator.configure(row as? BrandTableRow) }
        if let index = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else { table.deselectAll(nil) }
        // Future native clicks arrive before updateNSView; leave these rows
        // configured for the next selection while keeping first selection immediate.
        context.coordinator.animateSelection = BrandMotion.isEnabled(theme: palette.theme, reduceMotion: reduceMotion)
        table.enumerateAvailableRowViews { row, _ in context.coordinator.configure(row as? BrandTableRow) }
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        if selectionChanged, let index = rows.firstIndex(where: { $0.id == selectedID }) { table.scrollRowToVisible(index) }
        context.coordinator.lastSelectedID = selectedID
        context.coordinator.lastRowIDs = rows.map(\.id)
        DispatchQueue.main.async { [weak table] in table?.headerView?.needsDisplay = true }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: BrandLibraryTable
        var updating = false
        var lastSelectedID: UUID?
        var lastRowIDs: [UUID] = []
        var animateSelection = false
        init(_ parent: BrandLibraryTable) { self.parent = parent }
        fileprivate func cell(row: Int, column: Int) -> BrandLibraryCell {
            BrandLibraryCell(row: parent.rows[row], column: column, palette: parent.palette, artwork: parent.artwork,
                             reduceMotion: parent.reduceMotion)
        }
        fileprivate func configure(_ row: BrandTableRow?) {
            row?.configure(selectionColor: NSColor(parent.palette.brand.selection),
                           markColor: NSColor(parent.palette.brand.noteBlue.color),
                           animated: animateSelection)
        }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let column = tableColumn,
                  let index = Int(column.identifier.rawValue) else { return nil }
            let cell = cell(row: row, column: index)
            if let host = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSHostingView<BrandLibraryCell> {
                host.rootView = cell; return host
            }
            let host = NSHostingView(rootView: cell)
            host.identifier = column.identifier
            return host
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = BrandTableRow()
            configure(view)
            return view
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            let next = parent.rows.indices.contains(table.selectedRow) ? parent.rows[table.selectedRow].id : nil
            if parent.selectedID != next { parent.selectedID = next }
        }
    }
}

private final class BrandTableRow: NSTableRowView {
    private let selectionFill = BrandTableSelectionFill()
    private var animateSelection = false
    private var selectionVisible = false

    init() {
        super.init(frame: .zero)
        selectionFill.wantsLayer = true
        selectionFill.alphaValue = 0
        selectionFill.setAccessibilityElement(false)
        addSubview(selectionFill, positioned: .below, relativeTo: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override var isSelected: Bool {
        didSet { setSelectionVisible(isSelected, animated: animateSelection) }
    }
    override func layout() {
        super.layout()
        selectionFill.frame = bounds
    }
    override func drawSelection(in dirtyRect: NSRect) { }

    func configure(selectionColor: NSColor, markColor: NSColor, animated: Bool) {
        selectionFill.selectionColor = selectionColor
        selectionFill.markColor = markColor
        selectionFill.needsDisplay = true
        animateSelection = animated
        if !animated { setSelectionVisible(isSelected, animated: false) }
    }

    func setSelectionVisible(_ visible: Bool, animated: Bool) {
        guard selectionVisible != visible || !animated else { return }
        selectionVisible = visible
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = BrandMotion.selectionDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                selectionFill.animator().alphaValue = visible ? 1 : 0
            }
        } else {
            selectionFill.layer?.removeAllAnimations()
            selectionFill.alphaValue = visible ? 1 : 0
        }
    }
}

private final class BrandTableSelectionFill: NSView {
    var selectionColor = NSColor.clear
    var markColor = NSColor.clear
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        selectionColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
        markColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: bounds.midY - 13.5, width: 3, height: 27), xRadius: 1.5, yRadius: 1.5).fill()
    }
}

private struct BrandLibraryCell: View {
    let row: LibraryChartRow
    let column: Int
    let palette: AppPalette
    let artwork: SongArtworkStore
    let reduceMotion: Bool
    var body: some View {
        Group {
            switch column {
            case 0:
                HStack(spacing: 7) {
                    Color.clear.frame(width: 3, height: 27).accessibilityHidden(true).allowsHitTesting(false)
                    SongArtworkView(song: row.song, size: 36)
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
            case 3: BrandMetricValue(value: row.bestPlay?.score, identity: row.id).frame(maxWidth: .infinity, alignment: .trailing)
            default: Text(row.plays.count.formatted()).monospacedDigit().foregroundStyle(palette.brand.secondaryText.color).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }.foregroundStyle(Color(nsColor: .labelColor)).frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.appPalette, palette)
            .environment(\.songArtworkStore, artwork)
            .environment(\.brandMotionVerificationReduceMotion, reduceMotion)
    }
}
