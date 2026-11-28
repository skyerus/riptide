import CryptoKit
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class AgentAvatarStore {
    private struct Record: Codable {
        let jpeg: Data?
        let agentRevision: UUID?
    }

    private let directory: URL
    @ObservationIgnored private var loaded = Set<String>()
    @ObservationIgnored private var agentRevisions: [String: UUID] = [:]
    private var images: [String: UIImage] = [:]

    init(namespace: UUID?) {
        let folder = URL.applicationSupportDirectory.appending(path: "RiptideAgentAvatars", directoryHint: .isDirectory)
        directory = namespace.map { folder.appending(path: $0.uuidString, directoryHint: .isDirectory) } ?? folder
    }

    func image(for id: String) -> UIImage? { images[id] }

    func load(_ id: String) {
        guard !loaded.contains(id) else { return }
        do {
            let data = try Data(contentsOf: file(for: id, extension: "avatar"))
            let record = try PropertyListDecoder().decode(Record.self, from: data)
            images[id] = record.jpeg.flatMap(UIImage.init(data:))
            agentRevisions[id] = record.agentRevision
            loaded.insert(id)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            do {
                images[id] = UIImage(data: try Data(contentsOf: file(for: id, extension: "jpg")))
                loaded.insert(id)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                loaded.insert(id)
            } catch { }
        } catch {
            // Allow another read if the device is locked or the file is temporarily inaccessible.
        }
    }

    func setPhoto(_ data: Data, for id: String) async throws {
        let bytes = try await Task.detached(priority: .userInitiated) { try Self.avatarJPEG(from: data) }.value
        try Task.checkCancellation()
        load(id)
        try save(Record(jpeg: bytes, agentRevision: agentRevisions[id]), for: id)
    }

    func removePhoto(for id: String) throws {
        load(id)
        try save(Record(jpeg: nil, agentRevision: agentRevisions[id]), for: id)
    }

    func applyProfilePhoto(_ data: Data, revision: UUID, for id: String) async {
        load(id)
        guard agentRevisions[id] != revision else { return }
        do {
            let bytes = try await Task.detached(priority: .utility) {
                try Self.avatarJPEG(from: data, maxSourceEdge: 512)
            }.value
            try Task.checkCancellation()
            guard agentRevisions[id] != revision else { return }
            try save(Record(jpeg: bytes, agentRevision: revision), for: id)
        } catch { }
    }

    private func save(_ record: Record, for id: String) throws {
        let image = record.jpeg.flatMap(UIImage.init(data:))
        guard record.jpeg == nil || image != nil else { throw AvatarPhotoError.unreadable }
        let data = try PropertyListEncoder().encode(record)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(for: id, extension: "avatar"), options: [.atomic, .completeFileProtection])
        try? FileManager.default.removeItem(at: file(for: id, extension: "jpg"))
        loaded.insert(id)
        agentRevisions[id] = record.agentRevision
        images[id] = image
    }

    private func file(for id: String, extension pathExtension: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key).appendingPathExtension(pathExtension)
    }

    nonisolated private static func avatarJPEG(from data: Data, maxSourceEdge: Int? = nil) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw AvatarPhotoError.unreadable }
        if let maxSourceEdge {
            guard CGImageSourceGetType(source) == UTType.jpeg.identifier as CFString,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (1...maxSourceEdge).contains(width), (1...maxSourceEdge).contains(height) else {
                throw AvatarPhotoError.unreadable
            }
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AvatarPhotoError.unreadable
        }
        let edge = min(image.width, image.height)
        let bounds = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        let bytes = NSMutableData()
        guard let crop = image.cropping(to: bounds),
              let target = CGImageDestinationCreateWithData(bytes as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw AvatarPhotoError.unreadable
        }
        CGImageDestinationAddImage(target, crop, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(target) else { throw AvatarPhotoError.unreadable }
        return bytes as Data
    }
}

private enum AvatarPhotoError: Error { case unreadable }

struct AgentAvatar: View {
    let agent: WorkspaceAgent
    let size: CGFloat
    @Environment(WorkspaceState.self) private var workspace

    // Workspace IDs survive launch and reorder. Swift's hashValue is process-specific.
    private var gradient: LinearGradient {
        let seed = Array(SHA256.hash(data: Data(agent.id.utf8)).prefix(2))
        let hue = Double(seed[0]) / 256
        let shift = (Double(seed[1]) / 255 - 0.5) * 0.42
        let shadow = (1 + hue + shift).truncatingRemainder(dividingBy: 1)
        return LinearGradient(colors: [
            Color(hue: hue, saturation: 0.65, brightness: 0.8),
            Color(hue: shadow, saturation: 0.76, brightness: 0.42)
        ], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var initials: String {
        let words = agent.name.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
        return words.prefix(2).map { word in
            String(word.prefix(word.allSatisfy(\.isNumber) ? 2 : 1))
        }.joined().uppercased()
    }

    var body: some View {
        ZStack {
            if let photo = workspace.avatars.image(for: agent.id) {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                gradient
                Text(initials)
                    .font(.system(size: size * 0.33, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.horizontal, size * 0.14)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(.white.opacity(0.14)) }
        .task(id: agent.id) { workspace.avatars.load(agent.id) }
        .accessibilityHidden(true)
    }
}

struct AgentAvatarEditor: View {
    let agent: WorkspaceAgent
    @Environment(WorkspaceState.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var showingPhotoPicker = false
    @State private var selection: NSItemProvider?
    @State private var loading = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 10) {
                        AgentAvatar(agent: agent, size: 76)
                        Text(agent.name)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    VStack(spacing: 0) {
                        Button {
                            showingPhotoPicker = true
                        } label: {
                            AgentAvatarPhotoAction(title: hasPhoto ? "Change photo" : "Choose photo", symbol: "photo.on.rectangle")
                        }
                        .accessibilityIdentifier("choose-agent-photo")
                        if hasPhoto {
                            Divider().overlay(ChatTheme.sidebarDivider)
                                .padding(.leading, WorkspaceRow.textInset + 14)
                            Button {
                                do {
                                    try workspace.avatars.removePhoto(for: agent.id)
                                    issue = nil
                                } catch {
                                    issue = "Couldn’t remove this photo. Try again."
                                }
                            } label: {
                                AgentAvatarPhotoAction(title: "Use default avatar", symbol: "person.crop.circle")
                            }
                            .accessibilityIdentifier("reset-agent-photo")
                        }
                    }
                    .buttonStyle(.plain)
                    .background(ChatTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                    .opacity(loading ? 0.55 : 1)
                    .disabled(loading)
                    if loading { ProgressView("Saving photo…").font(.footnote) }
                    if let issue { Text(issue).font(.footnote).foregroundStyle(ChatTheme.warning) }
                }
                .frame(maxWidth: 360)
                .padding(.horizontal, ChatTheme.gutter)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .background(ChatTheme.background.ignoresSafeArea())
            .navigationTitle("Profile photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(loading)
                }
            }
        }
        .interactiveDismissDisabled(loading)
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showingPhotoPicker) {
            AgentPhotoPicker { provider in
                showingPhotoPicker = false
                selection = provider
            }
        }
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            issue = nil
            defer {
                loading = false
                self.selection = nil
            }
            do {
                guard let type = selection.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else {
                    throw AvatarPhotoError.unreadable
                }
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    selection.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: error ?? AvatarPhotoError.unreadable) }
                    }
                }
                try Task.checkCancellation()
                guard workspace.agent(agent.id) != nil else { return }
                try await workspace.avatars.setPhoto(data, for: agent.id)
            } catch is CancellationError {
                return
            } catch {
                issue = "Couldn’t use this photo. Choose another image or try again."
            }
        }
    }

    private var hasPhoto: Bool { workspace.avatars.image(for: agent.id) != nil }
}

private struct AgentPhotoPicker: UIViewControllerRepresentable {
    let finish: (NSItemProvider?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let finish: (NSItemProvider?) -> Void

        init(finish: @escaping (NSItemProvider?) -> Void) { self.finish = finish }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            finish(results.first?.itemProvider)
        }
    }
}

private struct AgentAvatarPhotoAction: View {
    let title: String
    let symbol: String

    var body: some View {
        WorkspaceRow(title: title, subtitle: "", symbol: symbol, color: ChatTheme.muted)
            .padding(.horizontal, 14)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
    }
}
