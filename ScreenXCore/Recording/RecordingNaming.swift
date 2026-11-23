import Foundation

/// File names of new recordings: `ScreenX Aufnahme JJJJ-MM-TT um HH.MM.SS.mov`.
public enum RecordingNaming {
    /// Extensions a recording with a given base name can end up with; a base name is free only if none exists.
    static let extensions = ["mov", "mp4", "gif"]

    /// The `.mov` for a recording started at `date` (local time by default) in `directory`. If a `.mov`,
    /// `.mp4` or `.gif` with that base name already exists, " 2", " 3", … is appended to the base name, so
    /// finalizing (`.mov` → `.mp4`) and the GIF conversion never meet an existing file.
    public static func movURL(in directory: URL, date: Date, timeZone: TimeZone = .current) -> URL {
        let base = RecordingFinalizer.filePrefix + timestamp(date: date, timeZone: timeZone)
        var name = base
        var counter = 2
        while extensions.contains(where: { ext in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + "." + ext).path)
        }) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return directory.appendingPathComponent(name + ".mov")
    }

    private static func timestamp(date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return formatter.string(from: date)
    }
}
