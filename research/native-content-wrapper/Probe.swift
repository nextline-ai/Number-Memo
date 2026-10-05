// Research-only macOS command-line probe. Not included in the iOS app target.
// Compile alongside the existing HitomiAPIClient.swift; see README.md.
// Requests one list slice and one gallery's metadata. Images use HEAD only.
// Remote JavaScript is inspected as text and is never executed.
import Foundation
import CryptoKit

private enum ProbeError: Error {
    case unexpectedResponse, unsupportedFormat
}

private struct Routing {
    let prefix: String
    let defaultValue: Int
    let alternateValue: Int
    let alternateBuckets: Set<Int>

    init(text: String) throws {
        // Accept only the observed data-table shape; stop on protocol changes.
        let pattern = #"(?s)^\s*'use strict';\s*gg\s*=\s*\{\s*m:\s*function\(g\)\s*\{\s*var o = ([01]);\s*switch \(g\) \{\s*((?:case \d+:\s*)+)o = ([01]); break;\s*\}\s*return o;\s*\},\s*s: function\(h\) \{ var m = /\(\.\.\)\(\.\)\$/.exec\(h\); return parseInt\(m\[2\]\+m\[1\], 16\).toString\(10\); \},\s*b: '([0-9]+/)'\s*\};\s*$"#
        let captures = try Self.captures(pattern, in: text)
        guard captures.count == 4,
              let initial = Int(captures[0]), let alternate = Int(captures[2]) else {
            throw ProbeError.unsupportedFormat
        }
        let regex = try NSRegularExpression(pattern: #"case (\d+):"#)
        let cases = captures[1] as NSString
        let values = regex.matches(in: captures[1], range: NSRange(location: 0, length: cases.length))
            .compactMap { Int(cases.substring(with: $0.range(at: 1))) }
        guard !values.isEmpty, values.allSatisfy({ (0..<4096).contains($0) }) else {
            throw ProbeError.unsupportedFormat
        }
        prefix = captures[3]
        defaultValue = initial
        alternateValue = alternate
        alternateBuckets = Set(values)
    }

    func imageURL(hash: String, format: String) throws -> URL {
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              ["webp", "avif"].contains(format),
              let bucket = Int(String(hash.suffix(1)) + String(hash.suffix(3).prefix(2)), radix: 16) else {
            throw ProbeError.unsupportedFormat
        }
        let shard = 1 + (alternateBuckets.contains(bucket) ? alternateValue : defaultValue)
        let family = format == "webp" ? "w" : "a"
        guard let url = URL(string: "https://\(family)\(shard).gold-usergeneratedcontent.net/\(prefix)\(bucket)/\(hash).\(format)") else {
            throw ProbeError.unsupportedFormat
        }
        return url
    }

    private static func captures(_ pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            throw ProbeError.unsupportedFormat
        }
        return (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
    }
}

@main
private struct Probe {
    static let base = "https://ltn.gold-usergeneratedcontent.net"
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }()

    static func request(_ url: URL, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://hitomi.la/", forHTTPHeaderField: "Referer")
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProbeError.unexpectedResponse }
        return (data, response)
    }

    static func main() async {
        var checks: [[String: Any]] = []
        var controls: [String: String] = [:]
        for name in ["common.js", "gg.js", "searchlib.js", "search.js"] {
            do {
                let (data, response) = try await request(URL(string: "\(base)/\(name)")!)
                let passed = response.statusCode == 200 && data.count < 500_000
                checks.append(["check": name, "passed": passed, "httpStatus": response.statusCode,
                               "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
                if passed { controls[name] = String(data: data, encoding: .utf8) }
            } catch { checks.append(failure(name, error)) }
        }

        do {
            let (data, response) = try await request(URL(string: "\(base)/index-korean.nozomi")!, range: "bytes=0-255")
            guard response.statusCode == 206, data.count == 256,
                  response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-255/") == true else {
                throw ProbeError.unexpectedResponse
            }
            let id = data.prefix(4).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            checks.append(["check": "listRange", "passed": true, "httpStatus": response.statusCode,
                           "bytes": data.count, "sampleCount": data.count / 4])

            // Exercise the app's existing client without persisting titles or identifiers.
            let info = try await HitomiAPIClient.fetchGalleryInfo(galleryId: id)
            let hashes = try await HitomiAPIClient.fetchGalleryFiles(galleryId: id)
            checks.append(["check": "existingAppMetadataClient", "passed": !hashes.isEmpty && info.hash == hashes.first,
                           "fileCount": hashes.count, "hasTitle": info.title?.isEmpty == false])

            guard let hash = hashes.first, let gg = controls["gg.js"],
                  let common = controls["common.js"],
                  common.contains("const domain2 = 'gold-usergeneratedcontent.net'"),
                  common.contains("return gg.b+gg.s(hash)+'/'+hash;") else {
                throw ProbeError.unsupportedFormat
            }
            let routing = try Routing(text: gg)
            checks.append(["check": "routingTableParse", "passed": true,
                           "alternateBucketCount": routing.alternateBuckets.count])
            for format in ["webp", "avif"] {
                do {
                    let (_, response) = try await request(routing.imageURL(hash: hash, format: format), method: "HEAD")
                    let type = response.value(forHTTPHeaderField: "Content-Type") ?? ""
                    checks.append(["check": "imageHEAD_\(format)", "passed": response.statusCode == 200 && type.hasPrefix("image/\(format)"),
                                   "httpStatus": response.statusCode, "contentType": type,
                                   "declaredBytes": response.value(forHTTPHeaderField: "Content-Length") ?? "unknown"])
                } catch { checks.append(failure("imageHEAD_\(format)", error)) }
            }
        } catch { checks.append(failure("listMetadataImagePipeline", error)) }

        do {
            let (versionData, versionResponse) = try await request(URL(string: "\(base)/galleriesindex/version")!)
            let version = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard versionResponse.statusCode == 200,
                  version.range(of: #"^[0-9]{1,20}$"#, options: .regularExpression) != nil else {
                throw ProbeError.unsupportedFormat
            }
            let (node, response) = try await request(URL(string: "\(base)/galleriesindex/galleries.\(version).index")!, range: "bytes=0-463")
            let valid = response.statusCode == 206 && node.count == 464
                && response.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-463/") == true
            checks.append(["check": "searchIndexRootRange", "passed": valid,
                           "httpStatus": response.statusCode, "bytes": node.count])
        } catch { checks.append(failure("searchIndexRootRange", error)) }

        // Diagnostic only: an old fallback host can fail independently of the current CDN.
        do {
            let (_, response) = try await request(URL(string: "https://ltn.hitomi.la/gg.js")!, method: "HEAD")
            checks.append(["check": "legacyHostDiagnostic", "httpStatus": response.statusCode])
        } catch {
            var result = failure("legacyHostDiagnostic", error)
            result.removeValue(forKey: "passed")
            checks.append(result)
        }
        let report: [String: Any] = [
            "observedAtUTC": ISO8601DateFormatter().string(from: Date()),
            "runtime": "macOS Foundation URLSession; not an iOS device test",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "scope": "Control files, 256-byte list slice, one gallery metadata sample, image HEAD only, search index root Range",
            "remoteJavaScriptExecuted": false,
            "imageBodiesDownloaded": false,
            "checks": checks
        ]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) { print(text) }
        if checks.contains(where: { ($0["passed"] as? Bool) == false }) { exit(1) }
    }

    static func failure(_ name: String, _ error: Error) -> [String: Any] {
        let error = error as NSError
        // Error domain and code only: no URLs, gallery IDs or content in the report.
        return ["check": name, "passed": false, "errorDomain": error.domain, "errorCode": error.code]
    }
}
