import AppKit
import OSLog
import SwiftUI
import ScreenXCore

/// Schreibt die Datei, die beim Herausziehen einer Karte übergeben wird.
enum DragFile {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ScreenX", isDirectory: true)
    }

    static func write(_ capture: Capture, settings: AppSettings) throws -> URL {
        let encoded = try ImageExporter.data(
            for: capture.image,
            scale: capture.scale,
            format: settings.exportFormat,
            jpegQuality: settings.jpegQuality
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(
            ImageExporter.fileName(date: capture.date, format: settings.exportFormat)
        )
        try encoded.write(to: url, options: .atomic)
        return url
    }
}

/// Transparente AppKit-Fläche über dem Vorschaubild: Ziehen startet eine Dateiübergabe,
/// ein Klick ohne Ziehen ruft `onClick` auf.
struct ThumbnailDragView: NSViewRepresentable {
    let image: NSImage
    let makeFile: () throws -> URL
    let onClick: (() -> Void)?
    let onDragEnded: (_ dropped: Bool) -> Void

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.image = image
        view.makeFile = makeFile
        view.onClick = onClick
        view.onDragEnded = onDragEnded
    }
}

final class DragSourceView: NSView, NSDraggingSource {
    private static let logger = Logger(subsystem: "com.screenx.app", category: "quickAccess")
    private static let dragThreshold: CGFloat = 3

    var image: NSImage?
    var makeFile: (() throws -> URL)?
    var onClick: (() -> Void)?
    var onDragEnded: ((_ dropped: Bool) -> Void)?

    private var mouseDownPoint: NSPoint?
    private var isDragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = mouseDownPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= Self.dragThreshold else { return }
        isDragging = true
        beginDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        if mouseDownPoint != nil, !isDragging { onClick?() }
    }

    private func beginDrag(with event: NSEvent) {
        guard let makeFile else { return }
        let url: URL
        do {
            url = try makeFile()
        } catch {
            Self.logger.error("Datei zum Ziehen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            isDragging = false
            onDragEnded?(false)
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    // MARK: - NSDraggingSource

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownPoint = nil
        onDragEnded?(!operation.intersection([.copy, .move, .generic]).isEmpty)
    }
}
