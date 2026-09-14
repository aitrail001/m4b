import Foundation

enum AppVersion {
    static var short: String { value("CFBundleShortVersionString") ?? "—" }
    static var build: String { value("CFBundleVersion") ?? "" }
    static var display: String { build.isEmpty ? short : "\(short) (\(build))" }
    static var badge: String { short == "—" ? "dev" : "v\(short)" }

    private static func value(_ key: String) -> String? {
        for url in candidatePlists where FileManager.default.fileExists(atPath: url.path) {
            if let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let s = dict[key] as? String, !s.isEmpty {
                return s
            }
        }
        if let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty, s != "1.0" {
            return s
        }
        return nil
    }

    private static var candidatePlists: [URL] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        return [
            contents.appendingPathComponent("Info.plist"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Info.plist")
        ]
    }
}
