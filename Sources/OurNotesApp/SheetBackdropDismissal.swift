import AppKit
import SwiftUI

/// Keeps the native sheet's focus, Escape handling and accessibility. The monitor
/// belongs to this sheet only, and never intercepts a click inside its window.
struct SheetBackdropDismissal: NSViewRepresentable {
    let onDismiss: () -> Void

    func makeNSView(context: Context) -> BackdropObserverView {
        BackdropObserverView(onDismiss: onDismiss)
    }
    func updateNSView(_ view: BackdropObserverView, context: Context) { view.onDismiss = onDismiss }
    static func dismantleNSView(_ view: BackdropObserverView, coordinator: ()) { view.stopObserving() }
}

final class BackdropObserverView: NSView {
    var onDismiss: () -> Void
    private var monitor: Any?

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let sheet = self.window, sheet.isVisible,
                  let parent = sheet.sheetParent, parent.attachedSheet === sheet,
                  event.window === parent else { return event }
            let point = parent.convertPoint(toScreen: event.locationInWindow)
            guard SheetBackdropHitTest.shouldDismiss(point: point, sheetFrame: sheet.frame,
                                                    backdropFrame: parent.convertToScreen(parent.contentLayoutRect)) else { return event }
            self.onDismiss()
            // Consume the click so a control behind the sheet cannot also activate.
            return nil
        }
    }

    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}

enum SheetBackdropHitTest {
    static func shouldDismiss(point: CGPoint, sheetFrame: CGRect, backdropFrame: CGRect) -> Bool {
        backdropFrame.contains(point) && !sheetFrame.contains(point)
    }
}
