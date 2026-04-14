import Foundation

struct AppThreadAssistantSnippetSnapshot: Equatable {
    let sourceItemId: String
    let snippet: String
}

extension AppThreadSnapshot {
    var displayTitle: String {
        let explicitTitle = info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicitTitle.isEmpty {
            return explicitTitle
        }

        let preview = info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !preview.isEmpty {
            return preview
        }

        return "Untitled session"
    }

    var hasPreviewOrTitle: Bool {
        let preview = info.preview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !preview.isEmpty || !title.isEmpty
    }

    var hasActiveTurn: Bool {
        if activeTurnId != nil {
            return true
        }
        if case .active = info.status {
            return true
        }
        return false
    }

    var resolvedModel: String {
        let direct = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !direct.isEmpty { return direct }
        let infoModel = info.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return infoModel
    }

    var resolvedPreview: String {
        displayTitle
    }

    var contextPercent: Int {
        guard let used = contextTokensUsed,
              let window = modelContextWindow,
              window > 0 else {
            return 0
        }
        return min(100, Int(Double(used) / Double(window) * 100))
    }

    var latestAssistantSnippet: String? {
        latestAssistantSnippetSnapshot?.snippet
    }

    var latestAssistantSnippetSnapshot: AppThreadAssistantSnippetSnapshot? {
        for item in hydratedConversationItems.reversed() {
            switch item.content {
            case .assistant(let data):
                if let snippet = Self.normalizedAssistantSnippet(from: data.text) {
                    return AppThreadAssistantSnippetSnapshot(
                        sourceItemId: item.id,
                        snippet: snippet
                    )
                }
            case .codeReview(let data):
                if let snippet = Self.normalizedAssistantSnippet(from: data.findings.first?.title) {
                    return AppThreadAssistantSnippetSnapshot(
                        sourceItemId: item.id,
                        snippet: snippet
                    )
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func normalizedAssistantSnippet(from text: String?) -> String? {
        guard let text else { return nil }
        let snippet = String(text.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? nil : snippet
    }
}
