import Foundation

struct SearchIndex {
    func filter(notes: [NoteRecord], query: String) -> [NoteRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return notes.sorted { $0.updatedAt > $1.updatedAt }
        }

        let lowered = trimmed.lowercased()
        return notes
            .filter {
                $0.title.lowercased().contains(lowered) ||
                $0.content.lowercased().contains(lowered)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
