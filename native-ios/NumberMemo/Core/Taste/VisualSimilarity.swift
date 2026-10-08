import Foundation
import Vision
import ImageIO
import GRDB

/// Derived, device-local data. Neither images nor feature prints leave the device.
/// Revision 2 is pinned so distances are comparable on every supported OS version.
actor VisualFingerprintEngine {
    static let shared = VisualFingerprintEngine()
    static let revision = 2
    func make(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = Self.revision
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { throw CocoaError(.fileReadCorruptFile) }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
    func rank(seed: Data, candidates: [Int64: Data]) throws -> [(Int64, Float)] {
        guard let reference = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: seed) else { return [] }
        var result: [(Int64, Float)] = []
        for (id, data) in candidates {
            try Task.checkCancellation()
            guard let candidate = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data) else { continue }
            var distance: Float = 0
            guard (try? reference.computeDistance(&distance, to: candidate)) != nil, distance.isFinite else { continue }
            result.append((id, distance))
        }
        return result.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
    }
}
struct VisualFingerprintStore: Sendable {
    let database: any DatabaseWriter
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE visual_fingerprints (
                scope TEXT NOT NULL, item_id INTEGER NOT NULL, revision INTEGER NOT NULL,
                digest TEXT NOT NULL, payload BLOB NOT NULL,
                PRIMARY KEY(scope, item_id)
            );
            """)
    }
    static func installDeletionTrigger(_ db: Database) throws {
        if try db.tableExists("works") {
            try db.execute(sql: "CREATE TRIGGER IF NOT EXISTS remove_visual_fingerprint AFTER DELETE ON works BEGIN DELETE FROM visual_fingerprints WHERE scope = 'comics' AND item_id = OLD.gallery_id; END;")
        } else {
            try db.execute(sql: "CREATE TRIGGER IF NOT EXISTS remove_visual_fingerprint AFTER DELETE ON favorites BEGIN DELETE FROM visual_fingerprints WHERE scope = OLD.server_id AND item_id = OLD.post_id; END;")
        }
    }
    func all(scope: String) throws -> [Int64: Data] {
        try database.read { db in
            let join = scope == "comics" ? "JOIN works w ON w.gallery_id = f.item_id" : "JOIN favorites w ON w.post_id = f.item_id AND w.server_id = f.scope"
            let rows = try Row.fetchAll(db, sql: "SELECT f.item_id, f.payload FROM visual_fingerprints f \(join) WHERE f.scope = ? AND f.revision = ?", arguments: [scope, VisualFingerprintEngine.revision])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["item_id"] as Int64, $0["payload"] as Data) })
        }
    }
    func save(data: Data, scope: String, id: Int64) async throws -> Data {
        let digest = tasteDigest(data)
        if let cached = try await database.read({ try Data.fetchOne($0, sql: "SELECT payload FROM visual_fingerprints WHERE scope = ? AND item_id = ? AND revision = ? AND digest = ?", arguments: [scope, id, VisualFingerprintEngine.revision, digest]) }) { return cached }
        let fingerprint = try await VisualFingerprintEngine.shared.make(data)
        try Task.checkCancellation()
        try await database.write { db in
            let exists: Bool
            if scope == "comics" { exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM works WHERE gallery_id = ?)", arguments: [id]) ?? false }
            else { exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM favorites WHERE server_id = ? AND post_id = ?)", arguments: [scope, id]) ?? false }
            guard exists else { return }
            try db.execute(sql: "INSERT OR REPLACE INTO visual_fingerprints VALUES (?, ?, ?, ?, ?)", arguments: [scope, id, VisualFingerprintEngine.revision, digest, fingerprint])
        }
        return fingerprint
    }
}
