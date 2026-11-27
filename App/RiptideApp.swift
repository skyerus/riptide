import RiptideCore
import SwiftUI

@main
struct RiptideApp: App {
    @UIApplicationDelegateAdaptor(RiptideNotificationDelegate.self) private var notificationDelegate
    private let roster: [AgentChatModel]
    private let preferences: UserDefaults
    private let localCodex: CodexLocalEndpoint?
    private let remotes: RemoteStore
    @State private var workspace: WorkspaceState
    #if DEBUG
    @State private var seededBusyInbox = false
    #endif

    init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let namespace = environment["RIPTIDE_FIXTURE_NAMESPACE"].flatMap(UUID.init(uuidString:))
        let demos = environment["RIPTIDE_DEMO"] == "1" || (namespace != nil && environment["RIPTIDE_DEMO"] != "0")
        let historyDelay: Duration = environment["RIPTIDE_DELAYED_CHAT_HISTORY"] == "1" ? .seconds(14) : .zero
        let showGroupFixture = demos && namespace != nil && environment["RIPTIDE_HERMES_GROUP_FIXTURE"] == "1"
        var targets = AgentTarget.demos
        if showGroupFixture {
            targets.removeAll { $0.id == "hermes" }
            targets += [
                AgentTarget(id: "hermes", name: "Hermes VPS", mainSessionID: "demo-hermes-main", cwd: "/demo"),
                AgentTarget(id: "hermes-studio", name: "Hermes Studio", mainSessionID: "demo-studio-main", cwd: "/demo")
            ]
        }
        let base = demos ? targets.map { Self.makeDemo($0, namespace: namespace, historyDelay: historyDelay) } : []
        let busy = demos && namespace != nil && environment["RIPTIDE_BUSY_WORKSPACE"] == "1"
        roster = base + (busy ? (1...12).map { index in
            let id = "ops-\(index)"
            return Self.makeDemo(
                AgentTarget(id: id, name: "Ops \(index)", mainSessionID: "\(id)-main", cwd: "/demo/\(id)"),
                namespace: namespace,
                catalog: (1...24).map { "Incident \($0) review" })
        } : [])
        preferences = namespace.flatMap { UserDefaults(suiteName: "app.riptide.fixture.\($0.uuidString)") } ?? .standard
        localCodex = CodexLocalEndpoint(environment: environment)
        #else
        let namespace: UUID? = nil
        roster = []
        preferences = .standard
        localCodex = nil
        #endif
        remotes = RemoteStore(defaults: preferences)
        let state = WorkspaceState(roster: roster, localCodex: localCodex, remotes: remotes,
                                   defaults: preferences, avatarNamespace: namespace)
        #if DEBUG
        if let namespace, showGroupFixture {
            for source in ["hermes", "hermes-studio"] {
                let fixture = HermesGroupsFixture(namespace: namespace, source: source)
                state.groupFixtures[source] = HermesGroupsClient { try await fixture.exchange($0) }
            }
        }
        #endif
        _workspace = State(initialValue: state)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if workspace.needsFirstAgent {
                    FirstAgentOnboarding(remotes: remotes)
                } else {
                    WorkspaceNavigation(workspace: workspace)
                }
            }
            .defaultAppStorage(preferences)
            .preferredColorScheme(.dark)
            .tint(ChatTheme.accent)
            .task { await seedBusyInbox() }
        }
    }

    @MainActor
    private func seedBusyInbox() async {
        #if DEBUG
        guard !seededBusyInbox,
              ProcessInfo.processInfo.environment["RIPTIDE_BUSY_INBOX"] == "1" else { return }
        seededBusyInbox = true
        for model in roster where model.target.id.hasPrefix("ops-") {
            await model.showMain()
            model.submit("Show an approval")
        }
        #endif
    }

    #if DEBUG
    private static func makeDemo(_ target: AgentTarget, namespace: UUID?, catalog: [String] = [],
                                 historyDelay: Duration = .zero) -> AgentChatModel {
        var directory = URL.applicationSupportDirectory.appending(path: "RiptideFixtures", directoryHint: .isDirectory)
        if let id = namespace {
            directory.append(path: id.uuidString, directoryHint: .isDirectory)
        }
        let file = directory.appending(path: "\(target.id).json")
        do {
            let pairingDemo = target.id == "hermes" && AgentPairingFixture.isEnabled
            let progressDemo = ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_ASSISTANT_PROGRESS"] == "1"
            let observedTurnDemo = target.id == "hermes"
                && ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_OBSERVED_TURN"] == "1"
            let compactionDemo = target.id == "hermes"
                && ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_CONTEXT_COMPACTION"] == "1"
            let transport = try FixtureTransport(target: target, file: file, catalog: catalog,
                                                historyDelay: historyDelay, pairingDemo: pairingDemo,
                                                progressDemo: progressDemo, observedTurnDemo: observedTurnDemo,
                                                compactionDemo: compactionDemo,
                                                timeoutOnSteer: target.id == "hermes"
                                                    && ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_TIMEOUT_ON_STEER"] == "1")
            return AgentChatModel(target: target, client: ACPClient(transport: transport))
        } catch {
            return AgentChatModel(target: target, unavailable: "Saved demo chats could not be opened.")
        }
    }
    #endif
}

enum ChatTheme {
    static let background = Color(red: 15 / 255, green: 16 / 255, blue: 17 / 255)
    static let surface = Color(red: 24 / 255, green: 26 / 255, blue: 27 / 255)
    static let raised = Color(red: 35 / 255, green: 38 / 255, blue: 39 / 255)
    static let ink = Color(red: 241 / 255, green: 243 / 255, blue: 242 / 255)
    static let muted = Color(red: 166 / 255, green: 173 / 255, blue: 170 / 255)
    static let inset = Color.white.opacity(0.05)
    static let border = Color.white.opacity(0.13)
    static let accent = ink
    static let sidebarAccent = Color(red: 53 / 255, green: 239 / 255, blue: 164 / 255)
    static let sidebarDivider = Color.white.opacity(0.09)
    static let selected = raised
    static let warning = Color(red: 239 / 255, green: 183 / 255, blue: 191 / 255)
    static let attention = Color(red: 240 / 255, green: 199 / 255, blue: 139 / 255)
    static let gutter: CGFloat = 20
    static let readingWidth: CGFloat = 680
}
