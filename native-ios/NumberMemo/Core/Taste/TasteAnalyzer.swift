import Foundation
import GRDB

/// Pure, deterministic statistics. No language model sees tags or computes numbers.
enum TasteAnalyzer {
    static let version = 4
    static func analyze(_ input: [TasteEvent], control: TasteControl, period: DateInterval? = nil, previous: DateInterval? = nil, savedKeys: Set<String>? = nil, mode: TasteMode = .booru) -> TasteSnapshot {
        let events = Dictionary(input.filter { $0.epoch == control.epoch }.map { ($0.id, $0) }, uniquingKeysWith: { a, b in TasteEvent.ordered(a, b) ? b : a }).values.sorted(by: TasteEvent.ordered)
        var metadataBySource: [String: Set<String>] = [:]
        for event in events { metadataBySource[event.item.source, default: []].formUnion(event.item.metadata.map(TasteTagPolicy.normalize)) }
        func eligibleTags(_ item: TasteItem) -> [String] { TasteTagPolicy.filter(item.tags, metadata: Array(metadataBySource[item.source, default: []])).filter { control.allows($0, source: item.source, mode: mode) } }
        var active: [String: TasteEvent] = [:]
        var latestMetadata: [String: TasteItem] = [:]
        var searched: Set<String> = []
        var observed: [String: TasteItem] = [:]
        var chosen: [String: TasteEvent] = [:]
        var searches: [String: Int] = [:]
        var activity: [Date: Int] = [:]
        var previousWorks = Set<String>()
        var previousTags: [String: Set<String>] = [:]
        var searchCount = 0
        var searchSessions = Set<String>()
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: control.timeZone) ?? .gmt
        func within(_ e: TasteEvent) -> Bool { period.map { e.at >= $0.start.timeIntervalSince1970 && e.at < $0.end.timeIntervalSince1970 } ?? true }
        for event in events {
            let item = event.item
            let eligible = eligibleTags(item)
            if event.kind == .search && event.context.origin == .search {
                for tag in eligible { searched.insert(TasteControl.tagKey(source: item.source, tag: tag)) }
                if within(event) {
                    if searchSessions.insert(event.context.session).inserted { searchCount += 1 }
                    for tag in eligible { searches[TasteControl.tagKey(source: item.source, tag: tag), default: 0] += 1 }
                }
            }
            if event.kind == .metadata { latestMetadata[item.key] = item }
            if event.kind == .save || event.kind == .seed || event.kind == .imported { active[item.key] = event; latestMetadata.removeValue(forKey: item.key) }
            if event.kind == .remove { active.removeValue(forKey: item.key) }
            if event.kind == .save && event.context.organic {
                for tag in eligible where event.context.included.contains(tag) {
                    searched.insert(TasteControl.tagKey(source: item.source, tag: tag))
                }
            }
            if within(event) {
                if (event.kind == .open || event.kind == .save) && event.context.organic { observed[item.key] = item }
                if event.kind == .save && chosen[item.key] == nil {
                    chosen[item.key] = event
                    activity[calendar.startOfDay(for: Date(timeIntervalSince1970: event.at)), default: 0] += 1
                }
            }
            if let previous, event.kind == .save, event.at >= previous.start.timeIntervalSince1970, event.at < previous.end.timeIntervalSince1970 {
                previousWorks.insert(item.key)
                for tag in eligible { previousTags[TasteControl.tagKey(source: item.source, tag: tag), default: []].insert(item.key) }
            }
        }
        if period == nil, let savedKeys { active = active.filter { savedKeys.contains($0.key) } }
        // Historical periods describe activity then. The live profile describes current saved items.
        var evidence = period == nil ? active : chosen
        for (key, var event) in evidence {
            if let metadata = latestMetadata[key] { event.item = metadata; evidence[key] = event }
        }
        for (key, item) in latestMetadata where observed[key] != nil { observed[key] = item }
        var tags: [String: TasteTag] = [:]
        var savedPerSource: [String: Int] = [:]
        var organicSavedTags: [String: Int] = [:]
        var openedPerSource: [String: Int] = [:]
        func allowed(_ name: String, source: String) -> Bool { !control.excluded.contains(TasteControl.tagKey(source: source, tag: name)) }
        for item in observed.values {
            openedPerSource[item.source, default: 0] += 1
            for name in eligibleTags(item) where allowed(name, source: item.source) {
                let key = TasteControl.tagKey(source: item.source, tag: name)
                var tag = tags[key] ?? TasteTag(source: item.source, name: name)
                tag.opened += 1; tags[key] = tag
            }
        }
        for event in evidence.values {
            let item = event.item
            if event.context.organic { savedPerSource[item.source, default: 0] += 1 }
            for name in eligibleTags(item) where allowed(name, source: item.source) && (!event.context.constraints.contains(name) || event.context.included.contains(name)) {
                let key = TasteControl.tagKey(source: item.source, tag: name)
                var tag = tags[key] ?? TasteTag(source: item.source, name: name)
                if event.context.preferenceAction {
                    if event.context.organic { organicSavedTags[key, default: 0] += 1 }
                    if event.context.chosenTags.contains(name) { tag.confirmed += 1 }
                    else { tag.hidden += 1; tag.sessions.insert(event.context.session) }
                } else { tag.general += 1 }
                tag.works.append(item); tags[key] = tag
            }
        }
        for (key, count) in searches {
            guard !control.excluded.contains(key), let split = key.firstIndex(of: "\n") else { continue }
            let source = String(key[..<split]), name = String(key[key.index(after: split)...])
            var tag = tags[key] ?? TasteTag(source: source, name: name)
            tag.searches = count; tags[key] = tag
        }
        for (key, var tag) in tags {
            tag.previouslySearched = searched.contains(key) || tag.confirmed > 0
            let opened = openedPerSource[tag.source, default: 0], saved = savedPerSource[tag.source, default: 0]
            if opened >= 30, saved >= 10 {
                let selectedRate = Double(organicSavedTags[key, default: 0] + 1) / Double(saved + 2)
                let baselineRate = Double(tag.opened + 1) / Double(opened + 2)
                tag.lift = selectedRate / baselineRate
            }
            tag.works.sort { $0.key < $1.key }; tags[key] = tag
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digestData = (try? encoder.encode(events)) ?? Data()
        let controlData = (try? encoder.encode(control.excluded.sorted() + control.analysisExcluded(mode).sorted())) ?? Data()
        let signature = Data("\(version):\(TasteTagPolicy.version):\(control.timeZone):\(period?.start.timeIntervalSince1970 ?? -1):\(period?.end.timeIntervalSince1970 ?? -1):\(previous?.start.timeIntervalSince1970 ?? -1):\(previous?.end.timeIntervalSince1970 ?? -1)".utf8) + ((try? encoder.encode(evidence.keys.sorted())) ?? Data())
        return .init(tags: tags.values.filter { $0.count > 0 || $0.searches > 0 }.sorted { $0.weight == $1.weight ? $0.id < $1.id : $0.weight > $1.weight }, saves: chosen.count, opens: observed.count, searches: searchCount, activity: activity, digest: tasteDigest(digestData + controlData + signature), period: period, previousSaves: previous == nil ? nil : previousWorks.count, previousTagCounts: previousTags.mapValues(\.count))
    }
}

actor TasteAnalysisCache {
    private struct Entry { var rowID: Int64 = 0; var count = 0; var epoch = ""; var events: [TasteEvent] = [] }
    private var entries: [TasteMode: Entry] = [:]
    func snapshot(store: TasteStore, control: TasteControl, period: DateInterval?, previous: DateInterval?, savedKeys: Set<String>? = nil) throws -> TasteSnapshot {
        var entry = entries[store.mode] ?? Entry()
        let count = try store.database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM taste_events") ?? 0 }
        if entry.epoch != control.epoch || count < entry.count { entry = Entry(); entry.epoch = control.epoch }
        let after = entry.rowID
        let new = try store.database.read { db in
            try Row.fetchAll(db, sql: "SELECT rowid, payload FROM taste_events WHERE rowid > ? ORDER BY rowid", arguments: [after]).map { row in
                (row["rowid"] as Int64, try JSONDecoder().decode(TasteEvent.self, from: row["payload"] as Data))
            }
        }
        entry.events += new.map(\.1); entry.rowID = new.last?.0 ?? entry.rowID; entry.count = count
        entries[store.mode] = entry
        return TasteAnalyzer.analyze(entry.events, control: control, period: period, previous: previous, savedKeys: savedKeys, mode: store.mode)
    }
    func invalidate() { entries.removeAll() }
}
