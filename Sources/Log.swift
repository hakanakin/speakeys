import Foundation

/// Appends problems to ~/Library/Logs/Speakeys.log. Never pass transcripts here.
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Speakeys.log")
    private static let queue = DispatchQueue(label: "Speakeys.Log", qos: .utility)

    static func error(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}
