import Foundation

struct CDNRouting: Sendable {
    let prefix: String
    let defaultValue: Int
    let alternateValue: Int
    let alternateBuckets: Set<Int>

    init(_ text: String) throws {
        let pattern = #"(?s)^\s*'use strict';\s*gg\s*=\s*\{\s*m:\s*function\(g\)\s*\{\s*var o = ([01]);\s*switch \(g\) \{\s*((?:case \d+:\s*)+)o = ([01]); break;\s*\}\s*return o;\s*\},\s*s: function\(h\) \{ var m = /\(\.\.\)\(\.\)\$/.exec\(h\); return parseInt\(m\[2\]\+m\[1\], 16\).toString\(10\); \},\s*b: '([0-9]+/)'\s*\};\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let source = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) else {
            throw ContentError.unsupportedFormat
        }
        let values = (1..<match.numberOfRanges).map { source.substring(with: match.range(at: $0)) }
        guard let initial = Int(values[0]), let alternate = Int(values[2]) else { throw ContentError.unsupportedFormat }
        let cases = values[1] as NSString
        let caseRegex = try NSRegularExpression(pattern: #"case (\d+):"#)
        let buckets = caseRegex.matches(in: values[1], range: NSRange(location: 0, length: cases.length))
            .compactMap { Int(cases.substring(with: $0.range(at: 1))) }
        guard buckets.allSatisfy({ (0..<4096).contains($0) }) else { throw ContentError.unsupportedFormat }
        prefix = values[3]
        defaultValue = initial
        alternateValue = alternate
        alternateBuckets = Set(buckets)
    }

    func url(hash: String, format: String, thumbnail: Bool) throws -> URL {
        guard hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              ["webp", "avif"].contains(format),
              let bucket = Int(String(hash.suffix(1)) + String(hash.suffix(3).prefix(2)), radix: 16) else {
            throw ContentError.unsupportedFormat
        }
        let alternate = alternateBuckets.contains(bucket) ? alternateValue : defaultValue
        let host = thumbnail ? (alternate == 0 ? "atn" : "btn") : "\(format == "webp" ? "w" : "a")\(1 + alternate)"
        let path = thumbnail
            ? "\(format)smalltn/\(hash.suffix(1))/\(hash.suffix(3).prefix(2))/\(hash).\(format)"
            : "\(prefix)\(bucket)/\(hash).\(format)"
        guard let url = URL(string: "https://\(host).gold-usergeneratedcontent.net/\(path)") else { throw ContentError.invalidResponse }
        return url
    }
}
