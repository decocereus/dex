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
        guard let baseUrl = URL(string: session.httpBaseUrl),
              let host = baseUrl.host else {
            return
        }

        let cookieProperties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: "/",
            .name: session.sessionCookieName,
            .value: session.bearerToken,
            .secure: baseUrl.scheme?.lowercased() == "https",
            .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 30),
        ]

        if let cookie = HTTPCookie(properties: cookieProperties) {
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }

        let requestUrl: URL
        if let initialPath = session.initialPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !initialPath.isEmpty,
           var components = URLComponents(url: baseUrl, resolvingAgainstBaseURL: false) {
            components.path = initialPath.hasPrefix("/") ? initialPath : "/\(initialPath)"
            requestUrl = components.url ?? baseUrl
        } else {
            requestUrl = baseUrl
        }

        var request = URLRequest(url: requestUrl)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
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
