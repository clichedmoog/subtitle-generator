import AppKit

class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Draw app icon
        if let icon = NSApp.applicationIconImage {
            icon.draw(in: bounds)
        }

        // Draw progress bar
        let barHeight: CGFloat = 28
        let barInset: CGFloat = 8
        let barY: CGFloat = 6
        let barRect = NSRect(x: barInset, y: barY, width: bounds.width - barInset * 2, height: barHeight)

        // Background
        NSColor.black.withAlphaComponent(0.6).setFill()
        let bgPath = NSBezierPath(roundedRect: barRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
        bgPath.fill()

        // Progress fill
        let fillWidth = (barRect.width - 4) * CGFloat(min(max(progress, 0), 1))
        if fillWidth > 0 {
            let fillRect = NSRect(x: barRect.minX + 2, y: barRect.minY + 2, width: fillWidth, height: barHeight - 4)
            NSColor.systemBlue.setFill()
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: (barHeight - 4) / 2, yRadius: (barHeight - 4) / 2)
            fillPath.fill()
        }
    }
}
