import Foundation
import MLXLMCommon

/// MCP-style lookup tools over the bundled offline health library
/// (`HealthCorpus` — MedlinePlus, NIH). The model can search it and read
/// topic summaries during text follow-ups, entirely on-device.
///
/// Reference only, by construction: these tools return encyclopedia text
/// and its attribution. They know nothing about the current verdict, and
/// the follow-up instructions tell the model the printed verdict always
/// wins over anything it reads here.
enum CorpusTools {

    // MARK: search_health_topics

    struct SearchInput: Codable {
        let query: String
    }
    struct SearchHit: Codable {
        let title: String
        let snippet: String
    }
    struct SearchOutput: Codable {
        let results: [SearchHit]
        let note: String
    }

    static let search = Tool<SearchInput, SearchOutput>(
        name: "search_health_topics",
        description:
            "Search the offline MedlinePlus (NIH) health reference library bundled on this phone. "
            + "Returns matching topic titles with a snippet. Use it to answer factual questions "
            + "about conditions, symptoms, treatments, or prevention. Reference only — it never "
            + "changes the triage verdict already shown.",
        parameters: [
            .required(
                "query", type: .string,
                description:
                    "Keywords for the condition, symptom, or question, e.g. 'ringworm treatment' or 'tick bite'."
            )
        ]
    ) { input in
        let hits = HealthCorpus.search(input.query, limit: 3)
        return SearchOutput(
            results: hits.map { SearchHit(title: $0.title, snippet: $0.snippet) },
            note: hits.isEmpty
                ? "No offline topic matched. Answer honestly that the library has nothing on this, and point to a clinician if it matters."
                : "Call get_health_topic with one of these titles to read its summary."
        )
    }

    // MARK: get_health_topic

    struct TopicInput: Codable {
        let title: String
    }
    struct TopicOutput: Codable {
        let title: String
        let summary: String
        let source: String
    }

    static let topic = Tool<TopicInput, TopicOutput>(
        name: "get_health_topic",
        description:
            "Read one topic's plain-language summary from the offline MedlinePlus (NIH) library. "
            + "Pass a title returned by search_health_topics, or a plain condition name.",
        parameters: [
            .required(
                "title", type: .string,
                description: "The topic title, e.g. 'Tinea Infections' or 'ringworm'.")
        ]
    ) { input in
        guard let found = HealthCorpus.topic(named: input.title) else {
            throw PhoneTools.ToolFailure.bad(
                "No topic named '\(input.title)' in the offline library. Try search_health_topics first."
            )
        }
        return TopicOutput(
            title: found.title,
            summary: found.summary,
            source: "MedlinePlus (NIH), \(found.url) — \(HealthCorpus.attribution)"
        )
    }

    // MARK: wiring

    static var specs: [ToolSpec] {
        [search.schema, topic.schema]
    }

    static func dispatch(_ call: ToolCall) async -> String? {
        do {
            switch call.function.name {
            case search.name: return try encode(await call.execute(with: search))
            case topic.name: return try encode(await call.execute(with: topic))
            default: return nil
            }
        } catch {
            return #"{"error": "\#(error.localizedDescription)"}"#
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        String(data: try JSONEncoder().encode(value), encoding: .utf8) ?? "{}"
    }
}
