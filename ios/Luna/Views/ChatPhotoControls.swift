import SwiftUI
import PhotosUI
import AVFoundation

struct ChatPhotoControls: View {
    @Bindable var store: AppStore
    let sessionID: String
    @Binding var showingOptions: Bool
    @Binding var importing: Bool
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var cameraData: Data?
    @State private var capturedData: Data?
    @State private var photoError: String?
    @State private var visible = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .confirmationDialog("Add photos", isPresented: $showingOptions, titleVisibility: .visible) {
                Button("Take Photo") { Task { await openCamera() } }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                Button("Photo Library") { showingLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $showingLibrary, selection: $selection,
                          maxSelectionCount: max(1, ChatPhoto.maxCount - (store.photoDrafts[sessionID]?.count ?? 0)),
                          matching: .images, preferredItemEncoding: .compatible)
            .fullScreenCover(isPresented: $showingCamera, onDismiss: {
                cameraData = capturedData; capturedData = nil
            }) {
                CameraPicker { image in
                    showingCamera = false
                    if let image {
                        guard let data = image.jpegData(compressionQuality: 1) else {
                            photoError = "The camera photo couldn’t be opened. Try taking it again."; return
                        }
                        capturedData = data
                    }
                }.ignoresSafeArea()
            }
            .task(id: selection) {
                guard !selection.isEmpty else { return }
                importing = true
                defer { importing = false }
                for item in selection {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            throw ServiceError(message: "This photo couldn’t be downloaded. Try again when it’s available in Photos.")
                        }
                        try await attach(data)
                    } catch is CancellationError { return }
                    catch { photoError = error.localizedDescription }
                }
                selection = []
            }
            .task(id: cameraData) {
                guard let cameraData else { return }
                importing = true
                defer { importing = false; self.cameraData = nil }
                do { try await attach(cameraData) }
                catch is CancellationError {}
                catch { photoError = error.localizedDescription }
            }
            .alert("Couldn’t attach photo", isPresented: Binding(get: { photoError != nil }, set: { if !$0 { photoError = nil } })) {
                Button("OK", role: .cancel) { photoError = nil }
            } message: { Text(photoError ?? "") }
            .onAppear { visible = true }
            .onDisappear { visible = false }
    }

    @MainActor private func attach(_ data: Data) async throws {
        let photo = try await Task.detached(priority: .userInitiated) { try DraftPhoto.prepare(data) }.value
        try Task.checkCancellation()
        var photos = store.photoDrafts[sessionID] ?? []
        guard !photos.contains(where: { $0.id == photo.id }) else { return }
        guard photos.count < ChatPhoto.maxCount else { throw ServiceError(message: "Attach up to four photos per message.") }
        photos.append(photo)
        store.photoDrafts[sessionID] = photos
    }

    @MainActor private func openCamera() async {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        guard visible else { return }
        if allowed { showingCamera = true }
        else { photoError = "Allow Luna to use the camera in iPhone Settings, or choose a photo from your library." }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let completion: (UIImage?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let completion: (UIImage?) -> Void
        init(completion: @escaping (UIImage?) -> Void) { self.completion = completion }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { completion(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            completion(info[.originalImage] as? UIImage)
        }
    }
}

struct PhotoDraftStrip: View {
    let photos: [DraftPhoto]
    let disabled: Bool
    let remove: (String) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(photos) { photo in
                    if let image = UIImage(data: photo.jpeg) {
                        Image(uiImage: image).resizable().scaledToFill().frame(width: 76, height: 76)
                            .clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(alignment: .topTrailing) {
                                Button { remove(photo.id) } label: {
                                    Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .black).font(.title3).padding(3)
                                }.disabled(disabled).accessibilityLabel("Remove photo")
                            }.accessibilityLabel("Attached photo")
                    }
                }
            }.padding(.vertical, 4)
        }.scrollIndicators(.hidden)
    }
}

struct ChatPhotoView: View {
    let photo: ChatPhoto
    @State private var image: UIImage?
    @State private var showingPreview = false
    var body: some View {
        Group {
            if let image {
                Button { showingPreview = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 260, maxHeight: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain).accessibilityLabel("View attached photo")
            } else {
                Label("Photo unavailable", systemImage: "photo").font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .task(id: photo.id) {
            let data = await Task.detached { try? photo.data() }.value
            if let data, !Task.isCancelled { image = UIImage(data: data) }
        }
        .sheet(isPresented: $showingPreview) {
            NavigationStack {
                Group { if let image { Image(uiImage: image).resizable().scaledToFit() } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
                    .navigationTitle("Photo").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingPreview = false } } }
            }
        }
    }
}
