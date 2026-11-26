import ImageIO
import PhotosUI
import RiptideCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerAttachmentPicker: View {
    @Binding var attachments: [ChatAttachment]
    @Binding var isImporting: Bool
    @Binding var clipboard: [NSItemProvider]
    let acceptsImages: Bool
    let byteLimit: Int
    let canAttach: Bool
    let privateFileTransfer: PrivateFileTransfer?

    @State private var showCamera = false
    @State private var showPhotos = false
    @State private var showFiles = false
    @State private var showPrivateFileTransfer = false
    @State private var photos: [PhotosPickerItem] = []
    @State private var importing: Task<Void, Never>?
    @State private var problem: String?

    private var canAddAttachment: Bool {
        canAttach && importing == nil && attachments.count < ChatAttachment.maxCount
    }

    var body: some View {
        Menu {
            if acceptsImages {
                Button("Camera", systemImage: "camera") {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        problem = "A camera is unavailable on this device."
                    }
                }.disabled(!canAddAttachment)
                Button("Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                    .disabled(!canAddAttachment)
            }
            Button("Files", systemImage: "paperclip") { showFiles = true }
                .disabled(!canAddAttachment)
            if privateFileTransfer != nil {
                Button("Send File to VPS", systemImage: "lock") { showPrivateFileTransfer = true }
            }
        } label: {
            Group {
                if importing != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "plus").font(.system(size: 18, weight: .medium))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .buttonStyle(.plain)
        .foregroundStyle(ChatTheme.ink)
        .disabled(!canAddAttachment && privateFileTransfer == nil)
        .accessibilityLabel("Add attachments")
        .accessibilityIdentifier("add-attachments")
        .photosPicker(isPresented: $showPhotos, selection: $photos,
                      maxSelectionCount: max(1, ChatAttachment.maxCount - attachments.count),
                      selectionBehavior: .ordered, matching: .images)
        .onChange(of: clipboard) { importClipboard() }
        .onChange(of: photos) {
            guard !photos.isEmpty else { return }
            let selected = photos
            photos = []
            let start = attachments.count
            let imageLimit = byteLimit / ChatAttachment.maxCount
            importItems(selected.enumerated().map { offset, item in
                Source(name: "Photo-\(start + offset + 1).jpg") {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw AttachmentImportError.unreadable
                    }
                    return try AttachmentImporter.photo(data, name: "Photo-\(start + offset + 1).jpg", maxBytes: imageLimit)
                }
            })
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { selection in
            switch selection {
            case .success(let urls):
                let acceptsImages = acceptsImages
                let byteLimit = byteLimit
                importItems(urls.map { url in
                    Source(name: url.lastPathComponent) {
                        try AttachmentImporter.file(url, acceptsImages: acceptsImages, byteLimit: byteLimit)
                    }
                })
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { problem = error.localizedDescription }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            ComposerCamera { data in
                showCamera = false
                if let data {
                    let imageLimit = byteLimit / ChatAttachment.maxCount
                    importItems([Source(name: "Camera.jpg") {
                        try AttachmentImporter.photo(data, name: "Camera.jpg", maxBytes: imageLimit)
                    }])
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showPrivateFileTransfer) {
            if let privateFileTransfer {
                PrivateFileTransferSheet(transfer: privateFileTransfer)
            }
        }
        .alert("Attachments", isPresented: Binding(
            get: { problem != nil }, set: { if !$0 { problem = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: { Text(problem ?? "") }
        .onDisappear {
            importing?.cancel()
            importing = nil
            isImporting = false
        }
    }

    private struct Source {
        let name: String
        let load: @MainActor () async throws -> ChatAttachment
    }

    private func importClipboard() {
        guard !clipboard.isEmpty, importing == nil else { return }
        let providers = clipboard
        clipboard = []
        importItems(providers.compactMap { provider in
            guard let type = ClipboardAttachment.type(in: provider) else { return nil }
            let name = ClipboardAttachment.filename(for: provider, type: type)
            return Source(name: name) {
                try await AttachmentImporter.clipboard(provider, type: type, name: name,
                                                       acceptsImages: acceptsImages, byteLimit: byteLimit)
            }
        })
    }

    private func importItems(_ sources: [Source]) {
        guard !sources.isEmpty, importing == nil else { return }
        isImporting = true
        importing = Task {
            defer {
                if !Task.isCancelled {
                    importing = nil
                    isImporting = false
                    importClipboard()
                }
            }
            var failures: [String] = []
            for item in sources {
                guard !Task.isCancelled else { return }
                guard attachments.count < ChatAttachment.maxCount else {
                    failures.append("A message can include up to four attachments.")
                    break
                }
                do {
                    let attachment = try await item.load()
                    guard !Task.isCancelled else { return }
                    let remaining = byteLimit - attachments.reduce(0, { $0 + $1.data.count })
                    guard attachment.data.count <= remaining else { throw AttachmentImportError.tooLarge(byteLimit) }
                    attachments.append(attachment)
                } catch {
                    failures.append("\(item.name): \(error.localizedDescription)")
                }
            }
            if !Task.isCancelled, !failures.isEmpty { problem = failures.joined(separator: "\n") }
        }
    }
}

struct ComposerAttachmentStrip: View {
    @Binding var attachments: [ChatAttachment]

    var body: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        HStack(spacing: 7) {
                            if attachment.imageMIMEType != nil, let image = UIImage(data: attachment.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 38, height: 38)
                                    .clipShape(.rect(cornerRadius: 5))
                                    .accessibilityHidden(true)
                            } else {
                                Image(systemName: "doc").accessibilityHidden(true)
                            }
                            Text(attachment.name).font(.caption.weight(.medium))
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: 140)
                            Button("Remove \(attachment.name)", systemImage: "xmark.circle.fill") {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                            .accessibilityIdentifier("remove-attachment")
                        }
                        .padding(.leading, 7)
                        .background(ChatTheme.raised, in: .rect(cornerRadius: 9))
                    }
                }
            }
            .scrollIndicators(.hidden)
            .padding(.bottom, 4)
            .accessibilityIdentifier("draft-attachments")
        }
    }
}

private enum AttachmentImportError: LocalizedError {
    case unreadable
    case tooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .unreadable: "This item couldn’t be read."
        case .tooLarge(let limit): "The attachment limit is \(limit / (1024 * 1024)) MB per message."
        }
    }
}

private enum AttachmentImporter {
    static func file(_ url: URL, name: String? = nil, acceptsImages: Bool, byteLimit: Int) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true else { throw AttachmentImportError.unreadable }
        let name = name ?? url.lastPathComponent
        if acceptsImages, values.contentType?.conforms(to: .image) == true,
           let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = try? photo(source, name: name, maxBytes: byteLimit / ChatAttachment.maxCount) {
            return image
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw AttachmentImportError.tooLarge(byteLimit) }
        return ChatAttachment(name: name, data: data)
    }

    @MainActor
    static func clipboard(_ provider: NSItemProvider, type: UTType, name: String,
                          acceptsImages: Bool, byteLimit: Int) async throws -> ChatAttachment {
        if type == .fileURL {
            let data = try await clipboardData(provider, type: type)
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw AttachmentImportError.unreadable
            }
            return try file(url, acceptsImages: acceptsImages, byteLimit: byteLimit)
        }
        if type.conforms(to: .image) {
            let data = try await clipboardData(provider, type: type)
            if acceptsImages {
                return try photo(data, name: name, maxBytes: byteLimit / ChatAttachment.maxCount)
            }
            guard data.count <= byteLimit else { throw AttachmentImportError.tooLarge(byteLimit) }
            return ChatAttachment(name: name, data: data)
        }
        let file: ChatAttachment? = try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                // NSItemProvider removes its temporary copy when this callback returns.
                continuation.resume(with: Result {
                    try Self.file(url, name: name, acceptsImages: acceptsImages, byteLimit: byteLimit)
                })
            }
        }
        if let file { return file }
        let data = try await clipboardData(provider, type: type)
        guard data.count <= byteLimit else { throw AttachmentImportError.tooLarge(byteLimit) }
        return ChatAttachment(name: name, data: data)
    }

    @MainActor
    private static func clipboardData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? AttachmentImportError.unreadable) }
            }
        }
    }

    static func photo(_ data: Data, name: String, maxBytes: Int) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw AttachmentImportError.unreadable
        }
        return try photo(source, name: name, maxBytes: maxBytes)
    }

    private static func photo(_ source: CGImageSource, name: String, maxBytes: Int) throws -> ChatAttachment {
        for size in [2048, 1440, 1024, 720, 480] {
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { break }
            let png = CGImageSourceGetType(source) == UTType.png.identifier as CFString
            if png, let data = encode(image, type: .png), data.count <= maxBytes {
                return .init(name: (name as NSString).deletingPathExtension + ".png", data: data, imageMIMEType: "image/png")
            }
            if let data = encode(image, type: .jpeg), data.count <= maxBytes {
                return .init(name: (name as NSString).deletingPathExtension + ".jpg", data: data, imageMIMEType: "image/jpeg")
            }
        }
        throw AttachmentImportError.unreadable
    }

    private static func encode(_ image: CGImage, type: UTType) -> Data? {
        let bytes = NSMutableData()
        guard let encoder = CGImageDestinationCreateWithData(bytes, type.identifier as CFString, 1, nil) else { return nil }
        let properties = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary : nil
        CGImageDestinationAddImage(encoder, image, properties)
        return CGImageDestinationFinalize(encoder) ? bytes as Data : nil
    }
}

private struct ComposerCamera: UIViewControllerRepresentable {
    let finish: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(finish: finish) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finish: (Data?) -> Void

        init(finish: @escaping (Data?) -> Void) { self.finish = finish }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finish(nil) }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finish((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.92))
        }
    }
}
