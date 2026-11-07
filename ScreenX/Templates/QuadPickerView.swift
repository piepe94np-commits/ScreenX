import ScreenXCore
import SwiftUI

/// Inhalt des Fensters „Eigene Vorlage anlegen“: erst ein Ablagebereich, dann das eingepasste Bild, auf dem
/// die vier Ecken des Displays angeklickt und verschoben werden.
struct QuadPickerView: View {
    @Bindable var creator: CustomTemplateCreator
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if let loaded = creator.loaded {
                Text("Klicke die vier Ecken des Displays an (oben links beginnend, im Uhrzeigersinn)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
                QuadCanvas(image: loaded.image, points: $creator.points)
                Divider()
                bottomBar
            } else {
                dropZone
            }
        }
        .frame(minWidth: 560, minHeight: 440)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            creator.load(url: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert(String(localized: "Die Vorlage konnte nicht angelegt werden."), isPresented: Binding(
            get: { creator.errorMessage != nil },
            set: { if !$0 { creator.errorMessage = nil } }
        )) {
            Button(String(localized: "OK")) { creator.errorMessage = nil }
        } message: {
            Text(creator.errorMessage ?? "")
        }
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("PNG oder PDF hierher ziehen")
                .font(.headline)
            Button(String(localized: "Datei wählen …")) { creator.chooseFile() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.5),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
        }
        .padding(24)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button(String(localized: "Datei wählen …")) { creator.chooseFile() }
            Button(String(localized: "Zurücksetzen")) { creator.reset() }
                .disabled(creator.points.isEmpty)
            Spacer()
            TextField(String(localized: "Name"), text: $creator.name,
                      prompt: Text("Name der Vorlage"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            Button(String(localized: "Sichern")) { creator.save() }
                .keyboardShortcut(.defaultAction)
                .disabled(!creator.canSave)
        }
        .padding(12)
    }
}

/// Das eingepasste Bild mit den nummerierten Ecken. Ein Klick setzt die nächste Ecke (höchstens vier),
/// ein Zug an einer Ecke verschiebt sie; alle Punkte bleiben innerhalb des Bildes.
private struct QuadCanvas: View {
    let image: CGImage
    @Binding var points: [CGPoint]

    /// Index der gerade gezogenen Ecke; `nil`, wenn der Zug nichts bewegt.
    @State private var dragIndex: Int?
    @State private var isDragging = false

    private static let margin: CGFloat = 24
    private static let handleSize: CGFloat = 22

    var body: some View {
        GeometryReader { geometry in
            let imageSize = CGSize(width: image.width, height: image.height)
            let fit = QuadPicking.fittedRect(
                imageSize: imageSize,
                in: CGRect(origin: .zero, size: geometry.size).insetBy(dx: Self.margin, dy: Self.margin))
            let viewPoints = points.map { QuadPicking.toView($0, imageSize: imageSize, fittedRect: fit) }
            ZStack(alignment: .topLeading) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY)
                    .shadow(color: .black.opacity(0.15), radius: 4)
                if viewPoints.count > 1 {
                    Path { path in
                        path.addLines(viewPoints)
                        if viewPoints.count == 4 { path.closeSubpath() }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: viewPoints.count == 4 ? [] : [6, 4]))
                }
                ForEach(Array(viewPoints.enumerated()), id: \.offset) { index, point in
                    Text(verbatim: "\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: Self.handleSize, height: Self.handleSize)
                        .background(Circle().fill(Color.accentColor))
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .shadow(radius: 1)
                        .position(point)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            dragIndex = beginDrag(at: value.startLocation, viewPoints: viewPoints, fit: fit,
                                                  imageSize: imageSize)
                        }
                        guard let index = dragIndex, points.indices.contains(index) else { return }
                        points[index] = imagePoint(value.location, fit: fit, imageSize: imageSize)
                    }
                    .onEnded { _ in
                        isDragging = false
                        dragIndex = nil
                    })
        }
    }

    /// Trifft der Klick eine Ecke, wird sie gezogen; sonst setzt er (am bzw. knapp neben dem Bild) die nächste.
    private func beginDrag(at location: CGPoint, viewPoints: [CGPoint], fit: CGRect, imageSize: CGSize) -> Int? {
        if let hit = QuadPicking.hitIndex(at: location, in: viewPoints, tolerance: Self.handleSize / 2 + 2) {
            return hit
        }
        let reach = fit.insetBy(dx: -Self.handleSize / 2, dy: -Self.handleSize / 2)
        guard points.count < 4, reach.contains(location) else { return nil }
        points.append(imagePoint(location, fit: fit, imageSize: imageSize))
        return points.count - 1
    }

    private func imagePoint(_ location: CGPoint, fit: CGRect, imageSize: CGSize) -> CGPoint {
        QuadPicking.clamped(QuadPicking.toImage(location, imageSize: imageSize, fittedRect: fit), to: imageSize)
    }
}
