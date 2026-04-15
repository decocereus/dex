import SwiftUI
import WebKit

struct DexCompanionWebView: UIViewRepresentable {
    let session: DexCompanionBrowserSession

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear

        Task { @MainActor in
            await seedCookieAndLoad(webView: webView)
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    private func seedCookieAndLoad(webView: WKWebView) async {
        guard let baseUrl = URL(string: session.httpBaseUrl) else {
            return
        }
        let bootstrapPath = "api/auth/mobile/web-session"
        let desiredPath = normalizedInitialPath()
        guard var components = URLComponents(
            url: baseUrl.appending(path: bootstrapPath),
            resolvingAgainstBaseURL: false
        ) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "path", value: desiredPath)]
        guard let requestUrl = components.url else {
            return
        }

        var request = URLRequest(url: requestUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(session.bearerToken)", forHTTPHeaderField: "Authorization")
        webView.load(request)
    }

    private func normalizedInitialPath() -> String {
        if let initialPath = session.initialPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPath.isEmpty {
            return initialPath.hasPrefix("/") ? initialPath : "/\(initialPath)"
        }
        return "/_chat/"
    }
}

struct DexCompanionWebScreen: View {
    let session: DexCompanionBrowserSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            DexCompanionWebView(session: session)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(Color(.systemBackground).ignoresSafeArea())
                .navigationTitle(session.navigationTitle ?? session.serverLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundStyle(.tint)
                    }
                }
        }
    }
}
