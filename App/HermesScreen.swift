import RiptideCore
import SwiftUI
import WebKit

struct HermesScreen: View {
    let remote: RemoteProfile
    let credential: String
    let canContinue: () -> Bool
    let onContinue: () -> Void
    @State private var screen = ScreenConnection()
    @State private var showsPasswords = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let error = screen.error {
                    ContentUnavailableView {
                        Label("Browser unavailable", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Reconnect") { screen = ScreenConnection() }
                    }
                } else {
                    VStack(spacing: 0) {
                        Text(screen.isControlling ? "You’re in control" : screen.inUse ? "Someone else has control" : "Hermes is in control")
                            .font(.footnote.weight(.medium))
                            .padding(.vertical, 8)
                        HermesViewer(screen: screen)
                            .id(screen.id)
                            .accessibilityHidden(!screen.showsBrowser)
                            .allowsHitTesting(screen.showsBrowser)
                            .overlay {
                                if !screen.showsBrowser {
                                    ZStack {
                                        Color(uiColor: .systemBackground)
                                        if !screen.isReady {
                                            ProgressView("Opening browser…")
                                        } else if screen.isChangingControl {
                                            ProgressView()
                                        } else {
                                            ContentUnavailableView(
                                                "Browser is closed", systemImage: "safari",
                                                description: Text("Tap Take over to open Hermes’s browser.")
                                            )
                                        }
                                    }
                                }
                            }
                    }
                }
            }
            .navigationTitle("Hermes browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if screen.isControlling {
                        Button("Passwords", systemImage: "key") { showsPasswords = true }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("hermes-passwords")
                            .disabled(screen.isChangingControl)
                    } else {
                        Button("Close") { dismiss() }
                            .disabled(screen.isChangingControl)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if screen.isControlling {
                        Menu("Hand back") {
                            Button("Hand back") { screen.release() }
                                .accessibilityIdentifier("hermes-release-control")
                            Button("Hand back and continue in chat") {
                                screen.release {
                                    dismiss()
                                    onContinue()
                                }
                            }
                            .disabled(!canContinue())
                            .accessibilityIdentifier("hermes-release-and-continue")
                        }
                        .accessibilityIdentifier("hermes-hand-back")
                        .disabled(screen.isChangingControl)
                    } else {
                        Button("Take over") { screen.acquire() }
                            .accessibilityIdentifier("hermes-take-over")
                            .disabled(!screen.isReady || screen.isChangingControl)
                    }
                }
            }
        }
        .sheet(isPresented: $showsPasswords) {
            RemotePasswordEntry { await screen.typePassword($0) }
                .presentationDetents([.height(220), .medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .onChange(of: screen.isControlling) {
            if !screen.isControlling { showsPasswords = false }
        }
        .interactiveDismissDisabled(screen.isControlling || screen.isChangingControl)
        .task(id: screen.id) {
            guard let transport = remote.makeHermesScreenTransport(credential: credential) else {
                screen.fail("This Hermes workspace needs a paired SSH device key.")
                return
            }
            await screen.run(transport)
        }
    }
}

private struct RemotePasswordEntry: View {
    let send: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool
    @State private var password = ""
    @State private var sending = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .accessibilityIdentifier("hermes-remote-password")
                } footer: {
                    Text(failed ? "The browser couldn’t receive the password. Check that you still have control."
                         : "This enters the password in the focused field in the remote browser.")
                }
            }
            .navigationTitle("Passwords")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sending = true
                        Task {
                            let accepted = await send(password)
                            password = ""
                            sending = false
                            if accepted { dismiss() } else { failed = true }
                        }
                    }
                    .disabled(sending || password.isEmpty || password.utf8.count > 1024)
                    .accessibilityIdentifier("hermes-send-password")
                }
            }
        }
        .task { focused = true }
        .onDisappear { password = "" }
    }
}

@MainActor
@Observable
private final class ScreenConnection {
    let id = UUID()
    private(set) var isReady = false
    private(set) var isControlling = false
    private(set) var isChangingControl = false
    private(set) var inUse = false
    private(set) var error: String?
    var showsBrowser: Bool { isReady && !isChangingControl && browserVisible }
    private var browserVisible = true
    @ObservationIgnored private var waitsForFit = false
    @ObservationIgnored private var fitTimeout: Task<Void, Never>?
    @ObservationIgnored weak var view: WKWebView?
    @ObservationIgnored private var canFitWindow = false
    @ObservationIgnored private var viewerLoaded = false
    @ObservationIgnored private var continuation: (() -> Void)?
    @ObservationIgnored private var sender: AsyncStream<Command>.Continuation?

    struct Command: Encodable, Sendable {
        let command: String
        var data: String?
    }

    private struct Message: Decodable {
        let event: String
        let data: String?
        let held: Bool?
        let in_use: Bool?
        let browser_visible: Bool?
        let minimum_browser_width: Int?
        let message: String?
    }

    func run(_ transport: any JSONMessageTransport) async {
        let (commands, sender) = AsyncStream.makeStream(of: Command.self, bufferingPolicy: .bufferingOldest(256))
        self.sender = sender
        if viewerLoaded { send("open") }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.read(transport) }
            group.addTask { await self.write(commands, to: transport) }
            group.addTask {
                do { try await Task.sleep(for: .seconds(50)) } catch { return }
                await self.checkReadiness()
            }
            while await group.next() != nil {
                if error != nil || Task.isCancelled { group.cancelAll(); break }
            }
        }
        fitTimeout?.cancel()
        sender.finish()
        self.sender = nil
    }

    private func read(_ transport: any JSONMessageTransport) async {
        do {
            for try await message in transport.incoming {
                try await receive(JSONDecoder().decode(Message.self, from: message))
            }
            if !Task.isCancelled { fail("The Hermes screen disconnected.") }
        } catch {
            if !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private func write(_ commands: AsyncStream<Command>, to transport: any JSONMessageTransport) async {
        do {
            for await command in commands {
                try await transport.send(JSONEncoder().encode(command))
            }
        } catch {
            if !Task.isCancelled { fail(error.localizedDescription) }
        }
    }

    private func checkReadiness() {
        if !isReady { fail("Hermes did not open Bot Screen. Check the host setup and reconnect.") }
    }

    private func receive(_ message: Message) async throws {
        guard error == nil, let view else { return }
        switch message.event {
        case "opened":
            waitsForFit = message.browser_visible != nil
            browserVisible = message.browser_visible ?? true
            inUse = message.in_use == true
            _ = try await view.callAsyncJavaScript("hermesScreen.open()", contentWorld: .page)
        case "frame":
            guard let data = message.data else { return }
            _ = try await view.callAsyncJavaScript("hermesScreen.frame(data)", arguments: ["data": data], contentWorld: .page)
        case "control":
            isControlling = message.held == true
            inUse = message.in_use ?? isControlling
            let minimum = message.minimum_browser_width ?? 0
            canFitWindow = isControlling && (280...2_048).contains(minimum)
            if isControlling { browserVisible = true }
            if waitsForFit && isControlling {
                guard canFitWindow else {
                    fail("Hermes could not fit the browser to this screen.")
                    return
                }
                fitTimeout = Task {
                    do { try await Task.sleep(for: .seconds(8)) } catch { return }
                    fail("Hermes could not fit the browser to this screen.")
                }
            } else {
                isChangingControl = false
            }
            _ = try await view.callAsyncJavaScript(
                "hermesScreen.control(held, minimumWidth)",
                arguments: ["held": isControlling, "minimumWidth": canFitWindow ? minimum : 0], contentWorld: .page
            )
        case "fitted":
            fitTimeout?.cancel()
            fitTimeout = nil
            isChangingControl = false
        case "released":
            if let visible = message.browser_visible { browserVisible = visible }
            isControlling = false
            inUse = message.in_use == true
            _ = try await view.callAsyncJavaScript("hermesScreen.control(false)", contentWorld: .page)
            isChangingControl = false
            let action = continuation
            continuation = nil
            if !inUse { action?() }
        case "error":
            fail(message.message ?? "Could not connect to Bot Screen.")
        default:
            break
        }
    }

    func acquire() {
        guard isReady, !isChangingControl else { return }
        isChangingControl = true
        send("acquire")
    }

    func release(then: (() -> Void)? = nil) {
        guard isControlling, !isChangingControl else { return }
        continuation = then
        canFitWindow = false
        isChangingControl = true
        Task {
            if let view {
                _ = try? await view.callAsyncJavaScript("return await hermesScreen.prepareHandback()", contentWorld: .page)
            }
            guard error == nil, isControlling else { return }
            send("release")
        }
    }

    func typePassword(_ password: String) async -> Bool {
        guard isControlling, !isChangingControl, error == nil, let view,
              !password.isEmpty, password.utf8.count <= 1024,
              !password.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return false }
        let result = try? await view.callAsyncJavaScript("return hermesScreen.typeText(password)",
                                                        arguments: ["password": password], contentWorld: .page)
        return result as? Bool == true
    }

    func fail(_ message: String) {
        guard error == nil else { return }
        error = message
        fitTimeout?.cancel()
        fitTimeout = nil
        isReady = false
        isControlling = false
        isChangingControl = false
        continuation = nil
        sender?.finish()
    }

    func viewerMessage(_ body: Any) {
        guard error == nil else { return }
        switch body as? String {
        case "ready" where !viewerLoaded:
            viewerLoaded = true
            send("open")
        case "connected": isReady = true
        case "disconnected": fail("The Hermes screen disconnected.")
        case "fit" where canFitWindow && isControlling: send("fit")
        default:
            if let frame = (body as? [String: String])?["frame"], frame.utf8.count <= 16_384 {
                send("frame", data: frame)
            }
        }
    }

    private func send(_ name: String, data: String? = nil) {
        if case .dropped = sender?.yield(Command(command: name, data: data)) {
            fail("The connection is too slow to keep the browser in sync.")
        }
    }
}

private struct HermesViewer: UIViewRepresentable {
    let screen: ScreenConnection

    func makeCoordinator() -> Coordinator { Coordinator(screen) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "hermesScreen")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.accessibilityIdentifier = "hermes-screen-viewer"
        screen.view = view
        if let html = Bundle.main.url(forResource: "hermes-screen", withExtension: "html", subdirectory: "RichContent") {
            view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        } else {
            screen.fail("The bundled browser viewer is missing.")
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "hermesScreen")
        view.stopLoading()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var screen: ScreenConnection?

        init(_ screen: ScreenConnection) { self.screen = screen }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            screen?.viewerMessage(message.body)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.targetFrame?.isMainFrame == true && action.request.url?.isFileURL == true ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            screen?.fail("The browser viewer closed. Reconnect to regain control.")
        }
    }
}
