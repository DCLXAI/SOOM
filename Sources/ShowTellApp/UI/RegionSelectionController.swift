import AppKit

@MainActor
final class RegionSelectionController {
    private let panel: NSPanel
    private let completion: (CGRect?) -> Void
    private var completed = false

    init(screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true

        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        panel.contentView = view
        view.onComplete = { [weak self] localBottomLeftRect in
            guard let self else { return }
            guard let localBottomLeftRect else {
                self.finish(nil)
                return
            }
            let localTopLeftRect = CGRect(
                x: localBottomLeftRect.minX,
                y: view.bounds.height - localBottomLeftRect.maxY,
                width: localBottomLeftRect.width,
                height: localBottomLeftRect.height
            )
            self.finish(localTopLeftRect)
        }
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.contentView)
    }

    private func finish(_ rect: CGRect?) {
        guard !completed else { return }
        completed = true
        panel.orderOut(nil)
        completion(rect)
    }
}

private final class RegionSelectionView: NSView {
    var onComplete: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var selectionRect: CGRect?

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.48).setFill()
        bounds.fill()

        if let selectionRect {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selectionRect.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selectionRect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 2
            border.stroke()

            let label = "\(Int(selectionRect.width)) × \(Int(selectionRect.height))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.72)
            ]
            label.draw(at: CGPoint(x: selectionRect.minX + 8, y: max(10, selectionRect.maxY + 8)), withAttributes: attributes)
        } else {
            let message = "드래그하여 녹화 영역 선택  ·  ESC 취소"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let size = message.size(withAttributes: attributes)
            message.draw(
                at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
                withAttributes: attributes
            )
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        selectionRect = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(startPoint.x, point.x),
            y: min(startPoint.y, point.y),
            width: abs(point.x - startPoint.x),
            height: abs(point.y - startPoint.y)
        ).intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selectionRect, selectionRect.width >= 64, selectionRect.height >= 64 else {
            startPoint = nil
            self.selectionRect = nil
            needsDisplay = true
            return
        }
        onComplete?(selectionRect.integral)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onComplete?(nil) }
        else { super.keyDown(with: event) }
    }
}
