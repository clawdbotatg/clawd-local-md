import Foundation
import SQLite3

/// Read-only access to the bundled offline health reference library
/// (`HealthCorpus.db`, built by `tools/build_corpus.py` from MedlinePlus —
/// the NIH/NLM consumer-health encyclopedia). Full-text search runs on the
/// phone via SQLite FTS5; nothing here ever touches the network.
///
/// This is REFERENCE material for follow-up answers. It has no say in
/// triage: verdicts come from `TriageTable` and nothing the model reads
/// here may soften them (the follow-up instructions enforce that).
enum HealthCorpus {

    struct Hit {
        let title: String
        let snippet: String
    }

    struct Topic {
        let title: String
        let summary: String
        let url: String
    }

    /// How much of a topic summary a tool call returns. A 4B model with a
    /// small context doesn't benefit from a 12k-char treatise; it needs the
    /// core paragraphs.
    private static let summaryCap = 2400

    // MARK: queries

    /// Top matches for a free-text query, best first. Empty when the query
    /// has no usable words or nothing matches.
    static func search(_ query: String, limit: Int = 3) -> [Hit] {
        guard let match = ftsExpression(query) else { return [] }
        return withDatabase { db in
            let sql = """
                SELECT t.title, snippet(topics_fts, 2, '', '', ' … ', 14)
                FROM topics_fts JOIN topics t ON t.id = topics_fts.rowid
                WHERE topics_fts MATCH ?
                ORDER BY bm25(topics_fts, 8.0, 6.0, 1.0) LIMIT ?
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, match, -1, transient)
            sqlite3_bind_int(statement, 2, Int32(limit))
            var hits: [Hit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                hits.append(
                    Hit(
                        title: column(statement, 0),
                        snippet: column(statement, 1)
                    ))
            }
            return hits
        } ?? []
    }

    /// One topic by title — exact (case-insensitive) first, else the best
    /// full-text match, so the model can pass either a search result's title
    /// or a plain condition name.
    static func topic(named name: String) -> Topic? {
        if let exact = fetchTopic(where: "title = ? COLLATE NOCASE", bind: name) {
            return exact
        }
        guard let best = search(name, limit: 1).first else { return nil }
        return fetchTopic(where: "title = ? COLLATE NOCASE", bind: best.title)
    }

    /// The attribution line shown with every tool result — the library's
    /// provenance travels with its content.
    static var attribution: String {
        withDatabase { db in
            var statement: OpaquePointer?
            let sql = "SELECT value FROM meta WHERE key = 'attribution'"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            return sqlite3_step(statement) == SQLITE_ROW ? column(statement, 0) : nil
        } ?? "Reference content from MedlinePlus (medlineplus.gov). Not medical advice."
    }

    // MARK: internals

    private static func fetchTopic(where clause: String, bind value: String) -> Topic? {
        withDatabase { db in
            let sql = "SELECT title, body, url FROM topics WHERE \(clause) LIMIT 1"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, value, -1, transient)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return Topic(
                title: column(statement, 0),
                summary: truncate(column(statement, 1)),
                url: column(statement, 2)
            )
        } ?? nil
    }

    /// Free text -> an FTS5 MATCH expression that cannot be hijacked by
    /// query syntax: keep only alphanumeric words, quote each, OR them so a
    /// long natural-language question still ranks by how much it overlaps.
    private static func ftsExpression(_ query: String) -> String? {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.prefix(12).map { "\"\($0)\"" }.joined(separator: " OR ")
    }

    private static func truncate(_ text: String) -> String {
        guard text.count > summaryCap else { return text }
        let head = String(text.prefix(summaryCap))
        let cut = head.range(of: "\n", options: .backwards)?.lowerBound
            ?? head.range(of: ". ", options: .backwards)?.upperBound
            ?? head.endIndex
        return String(head[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines) + " …"
    }

    /// Open per call, read-only. The DB is a few MB and queries are rare
    /// (one per tool call), so a fresh connection is simpler than sharing
    /// one across the tool executor's threads.
    private static func withDatabase<T>(_ body: (OpaquePointer) -> T?) -> T? {
        guard let path = Bundle.main.url(forResource: "HealthCorpus", withExtension: "db")?.path
        else {
            DebugLog.log("HealthCorpus.db missing from bundle")
            return nil
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            DebugLog.log("HealthCorpus open failed")
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        return body(db)
    }

    private static func column(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    /// SQLITE_TRANSIENT: make SQLite copy bound strings — Swift's temporary
    /// C strings don't outlive the bind call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
