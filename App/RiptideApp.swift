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
    @State private var seededBusyInbox = false

    private static var fixtureNamespace: UUID? {
        ProcessInfo.processInfo.environment["RIPTIDE_FIXTURE_NAMESPACE"].flatMap(UUID.init(uuidString:))
    }

    init() {
        let base = AgentTarget.demos.map { Self.makeDemo($0) }
        #if DEBUG
        let busy = Self.fixtureNamespace != nil && ProcessInfo.processInfo.environment["RIPTIDE_BUSY_WORKSPACE"] == "1"
        roster = base + (busy ? (1...12).map { index in
            let id = "ops-\(index)"
            return Self.makeDemo(
                AgentTarget(id: id, name: "Ops \(index)", mainSessionID: "\(id)-main", cwd: "/demo/\(id)"),
                catalog: (1...24).map { "Incident \($0) review" })
        } : [])
        #else
        roster = base
        #endif
        preferences = Self.fixtureNamespace.flatMap { UserDefaults(suiteName: "app.riptide.fixture.\($0.uuidString)") }
            ?? .standard
        remotes = RemoteStore(defaults: preferences)
        #if DEBUG
        localCodex = CodexLocalEndpoint(environment: ProcessInfo.processInfo.environment)
        #else
        localCodex = nil
        #endif
        _workspace = State(initialValue: WorkspaceState(roster: roster, localCodex: localCodex,
                                                        remotes: remotes, defaults: preferences))
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceNavigation(workspace: workspace)
            .defaultAppStorage(preferences)
            .preferredColorScheme(.dark)
            .tint(ChatTheme.accent)
            .task { await seedBusyInbox() }
        }
    }

    @MainActor
    private func seedBusyInbox() async {
        #if DEBUG
        guard Self.fixtureNamespace != nil, !seededBusyInbox,
              ProcessInfo.processInfo.environment["RIPTIDE_BUSY_INBOX"] == "1" else { return }
        seededBusyInbox = true
        for model in roster where model.target.id.hasPrefix("ops-") {
            await model.showMain()
            model.submit("Show an approval")
        }
        #endif
    }

    private static func makeDemo(_ target: AgentTarget, catalog: [String] = []) -> AgentChatModel {
        var directory = URL.applicationSupportDirectory.appending(path: "RiptideFixtures", directoryHint: .isDirectory)
        if let id = fixtureNamespace {
            directory.append(path: id.uuidString, directoryHint: .isDirectory)
        }
        let file = directory.appending(path: "\(target.id).json")
        do {
            let transport = try FixtureTransport(target: target, file: file, catalog: catalog)
            return AgentChatModel(target: target, client: ACPClient(transport: transport))
        } catch {
            return AgentChatModel(target: target, unavailable: "Saved demo chats could not be opened.")
        }
    }
}

enum ChatTheme {
    static let background = Color(red: 16 / 255, green: 16 / 255, blue: 17 / 255)
    static let surface = Color(red: 29 / 255, green: 28 / 255, blue: 30 / 255)
    static let raised = Color(red: 38 / 255, green: 37 / 255, blue: 39 / 255)
    static let ink = Color(red: 242 / 255, green: 240 / 255, blue: 241 / 255)
    static let muted = Color(red: 174 / 255, green: 169 / 255, blue: 177 / 255)
    static let inset = Color.white.opacity(0.05)
    static let border = Color.white.opacity(0.13)
    static let accent = ink
    static let sidebarAccent = Color(red: 53 / 255, green: 239 / 255, blue: 164 / 255)
    static let sidebarDivider = Color.white.opacity(0.10)
    static let selected = raised
    static let warning = Color(red: 239 / 255, green: 183 / 255, blue: 191 / 255)
    static let gutter: CGFloat = 20
    static let readingWidth: CGFloat = 680
}
