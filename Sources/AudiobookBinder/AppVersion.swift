import Foundation

enum AppVersion {
    static var short: String { value("CFBundleShortVersionString") ?? "—" }
    static var build: String { value("CFBundleVersion") ?? "" }

    static var display: String {
        build.isEmpty ? short : "\(short) (\(build))"
    }

    private static func value(_ key: String) -> String? {
        if let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty {
            return s
        }
        for url in candidatePlists where FileManager.default.fileExists(atPath: url.path) {
            if let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let s = dict[key] as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private static var candidatePlists: [URL] {
        var urls: [URL] = []
        let bundle = Bundle.main.bundleURL
        urls.append(bundle.appendingPathComponent("Contents/Info.plist"))
        urls.append(bundle.appendingPathComponent("Info.plist"))
        var dir = bundle.deletingLastPathComponent()
        for _ in 0..<8 {
            urls.append(dir.appendingPathComponent("Info.plist"))
            dir.deleteLastPathComponent()
        }
        return urls
    }
}
