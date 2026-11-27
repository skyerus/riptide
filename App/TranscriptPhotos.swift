import ImageIO
import RiptideCore
import SwiftUI
import UIKit

struct TranscriptPhotoStrip: View {
    let photos: [TranscriptPhoto]
    var photoClient: CodexLiveClient? = nil
    @State private var preview: Preview?

    private struct Preview: Identifiable {
        let id: Int
    }

    var body: some View {
        if !photos.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(photos.indices, id: \.self) { index in
                        let photo = photos[index]
                        Button {
                            preview = Preview(id: index)
                        } label: {
                            TranscriptPhotoImage(photo: photo, client: photoClient, thumbnail: true)
                                .frame(width: 86, height: 78)
                                .background(ChatTheme.raised, in: .rect(cornerRadius: 11))
                                .clipShape(.rect(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open photo \(index + 1) of \(photos.count), \(photo.name)")
                        .accessibilityIdentifier("sent-photo-\(index)")
                    }
                }
            }
            .defaultScrollAnchor(.trailing, for: .alignment)
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("sent-photos")
            .sheet(item: $preview) { selected in
                TranscriptPhotoPreview(photos: photos, client: photoClient, selection: selected.id)
            }
        }
    }
}

private struct TranscriptPhotoPreview: View {
    let photos: [TranscriptPhoto]
    let client: CodexLiveClient?
    @State var selection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(photos.indices, id: \.self) { index in
                    TranscriptPhotoImage(photo: photos[index], client: client, thumbnail: false)
                        .padding(.horizontal, 12)
                        .padding(.bottom, photos.count > 1 ? 40 : 0)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .always : .never))
            .background(.black)
            .preferredColorScheme(.dark)
            .navigationTitle(photos[selection].name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .accessibilityIdentifier("sent-photo-preview")
        }
    }
}

private struct TranscriptPhotoImage: View {
    let photo: TranscriptPhoto
    let client: CodexLiveClient?
    let thumbnail: Bool
    @State private var image: UIImage?
    @State private var loading = true
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                if thumbnail {
                    Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                } else {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel(photo.name)
                        .accessibilityIdentifier("sent-photo-preview-image")
                }
            } else if loading {
                ProgressView()
            } else if thumbnail {
                Image(systemName: "photo").foregroundStyle(ChatTheme.muted)
                    .accessibilityHidden(true)
            } else {
                ContentUnavailableView("Photo unavailable", systemImage: "photo")
            }
        }
        .task(id: photo.source) {
            loading = true
            image = nil
            let data: Data? = switch photo.source {
            case .data(let bytes): bytes
            case .codexPath(let path): try? await client?.readTranscriptPhoto(at: path)
            case .unavailable: nil
            }
            if let data, !Task.isCancelled {
                if thumbnail {
                    let options = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(86 * displayScale)
                    ] as CFDictionary
                    if let source = CGImageSourceCreateWithData(data as CFData, nil),
                       let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options) {
                        image = UIImage(cgImage: thumb)
                    }
                } else {
                    image = UIImage(data: data)
                }
            }
            if !Task.isCancelled { loading = false }
        }
    }
}
