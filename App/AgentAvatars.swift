import CryptoKit
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor @Observable
final class AgentAvatarStore {
    private let directory: URL
    @ObservationIgnored private var loaded = Set<String>()
    private var images: [String: UIImage] = [:]

    init(namespace: UUID?) {
        let folder = URL.applicationSupportDirectory.appending(path: "RiptideAgentAvatars", directoryHint: .isDirectory)
        directory = namespace.map { folder.appending(path: $0.uuidString, directoryHint: .isDirectory) } ?? folder
    }

    func image(for id: String) -> UIImage? { images[id] }

    func load(_ id: String) {
        guard !loaded.contains(id) else { return }
        do {
            let data = try Data(contentsOf: file(for: id))
            images[id] = UIImage(data: data)
            loaded.insert(id)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            loaded.insert(id)
        } catch {
            // Allow another read if the device is locked or the file is temporarily inaccessible.
        }
    }

    func setPhoto(_ data: Data, for id: String) async throws {
        let bytes = try await Task.detached(priority: .userInitiated) { try Self.avatarJPEG(from: data) }.value
        try Task.checkCancellation()
        guard let image = UIImage(data: bytes) else { throw AvatarPhotoError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try bytes.write(to: file(for: id), options: [.atomic, .completeFileProtection])
        loaded.insert(id)
        images[id] = image
    }

    func removePhoto(for id: String) throws {
        do { try FileManager.default.removeItem(at: file(for: id)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        loaded.insert(id)
        images[id] = nil
    }

    private func file(for id: String) -> URL {
        let key = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: key).appendingPathExtension("jpg")
    }

    nonisolated private static func avatarJPEG(from data: Data) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
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
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var issue: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    AgentAvatar(agent: agent, size: 108)
                    Text(agent.name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    PhotosPicker(selection: $selection, matching: .images) {
                        Label(hasPhoto ? "Change photo" : "Choose photo", systemImage: "photo.on.rectangle")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(ChatTheme.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(ChatTheme.ink, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .opacity(loading ? 0.55 : 1)
                    .disabled(loading)
                    .accessibilityIdentifier("choose-agent-photo")
                    if hasPhoto {
                        Button("Use default avatar", systemImage: "person.crop.circle") {
                            do {
                                try workspace.avatars.removePhoto(for: agent.id)
                                issue = nil
                            } catch {
                                issue = "Couldn’t remove this photo. Try again."
                            }
                        }
                        .disabled(loading)
                        .accessibilityIdentifier("reset-agent-photo")
                    }
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
        .task(id: selection) {
            guard let selection else { return }
            loading = true
            issue = nil
            defer {
                loading = false
                self.selection = nil
            }
            do {
                guard let data = try await selection.loadTransferable(type: Data.self) else {
                    throw AvatarPhotoError.unreadable
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
