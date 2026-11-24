import Foundation
import Testing
@testable import ScreenXCore

struct RecordingNamingTests {
    private let date: Date = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 5, second: 7))!
    }()

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenXNaming-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ name: String, in directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name))
    }

    @Test func movNameFormat() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = RecordingNaming.movURL(in: directory, date: date, timeZone: .gmt)
        #expect(url.lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 09.05.07.mov")
        #expect(url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
        #expect(RecordingFinalizer.finalURL(for: url).lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 09.05.07.mp4")
    }

    @Test func existingMp4GetsCounter() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("ScreenX Aufnahme 2026-11-23 um 09.05.07.mp4", in: directory)
        let url = RecordingNaming.movURL(in: directory, date: date, timeZone: .gmt)
        #expect(url.lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 09.05.07 2.mov")
    }

    @Test func existingGifAndMovCountOn() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("ScreenX Aufnahme 2026-11-23 um 09.05.07.gif", in: directory)
        try touch("ScreenX Aufnahme 2026-11-23 um 09.05.07 2.mov", in: directory)
        let url = RecordingNaming.movURL(in: directory, date: date, timeZone: .gmt)
        #expect(url.lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 09.05.07 3.mov")
    }

    @Test func unrelatedFilesDoNotCount() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try touch("ScreenX Aufnahme 2026-11-23 um 09.05.07 gekürzt.mp4", in: directory)
        try touch("ScreenX 2026-11-23 um 09.05.07.png", in: directory)
        let url = RecordingNaming.movURL(in: directory, date: date, timeZone: .gmt)
        #expect(url.lastPathComponent == "ScreenX Aufnahme 2026-11-23 um 09.05.07.mov")
    }
}
