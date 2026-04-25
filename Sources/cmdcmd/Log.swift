import Foundation

enum Log {
    static let path = "/tmp/cmdcmd.log"
    private static let handle: FileHandle? = {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        try? h?.seekToEnd()
        return h
    }()

    static func write(_ msg: String) {
        let line = "[\(Date().timeIntervalSince1970)] \(msg)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        if let data = line.data(using: .utf8) { handle?.write(data) }
    }
}
