import Foundation

enum AppVersion {
    static var short: String { value("CFBundleShortVersionString") ?? "—" }
    static var build: String { value("CFBundleVersion") ?? "" }

    static var display: String {
        build.isEmpty ? short : "\(short) (\(build))"
    }

    static var badge: String {
        short == "—" ? "dev" : "v\(short)"
    }

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
        var urls: [URL] = []
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // AudiobookBinder.app/Contents/MacOS/AudiobookBinder → Contents/Info.plist
        let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
        urls.append(contents.appendingPathComponent("Info.plist"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
        urls.append(Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<10 {
            urls.append(dir.appendingPathComponent("Info.plist"))
            dir.deleteLastPathComponent()
        }
        return urls
    }
}
