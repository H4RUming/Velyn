import SwiftUI
import PhotosUI

/// Permission is requested only after the user chooses the photo library.
struct PhotoLibraryPicker: View {
    let completion: (Result<[String], Error>?) -> Void
    @State private var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var showAccessSelection = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if authorization == .authorized || authorization == .limited {
                VStack(spacing: 0) {
                    if authorization == .limited {
                        HStack {
                            Text("접근을 허용한 사진의 원본을 가져옵니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("접근할 사진 변경") { showAccessSelection = true }
                                .font(.caption).frame(minHeight: 44)
                        }.padding(.horizontal)
                    }
                    SystemPhotoPicker(completion: completion)
                }
            } else {
                NavigationStack {
                    VStack(spacing: 16) {
                        if authorization == .notDetermined {
                            ProgressView("사진 보관함 접근 확인 중")
                        } else {
                            Image(systemName: "photo.on.rectangle").font(.largeTitle)
                            Text("사진 보관함 접근이 필요합니다").font(.headline)
                            Text("RAW를 포함한 사진 원본을 가져오려면 사진 접근을 허용해 주세요. 파일에서 가져오기도 사용할 수 있습니다.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("설정 열기") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }.buttonStyle(.borderedProminent)
                        }
                    }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .navigationTitle("사진 보관함").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { completion(nil) } } }
                }
            }
        }
        .background(LibraryStyle.background).preferredColorScheme(.dark)
        .task {
            if authorization == .notDetermined {
                authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite) }
        }
        .sheet(isPresented: $showAccessSelection) {
            LimitedPhotoAccessPicker { showAccessSelection = false }
        }
    }
}

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    let completion: (Result<[String], Error>?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 0
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) { }
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let completion: (Result<[String], Error>?) -> Void
        private var finished = false
        init(completion: @escaping (Result<[String], Error>?) -> Void) { self.completion = completion }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !finished else { return }
            finished = true
            guard !results.isEmpty else { completion(nil); return }
            let identifiers = results.compactMap(\.assetIdentifier)
            guard identifiers.count == results.count else { completion(.failure(ImportFailure.photoNotAccessible)); return }
            completion(.success(identifiers))
        }
    }
}

struct LimitedPhotoAccessPicker: UIViewControllerRepresentable {
    let completion: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(completion: completion) }
    func updateUIViewController(_ controller: Controller, context: Context) { }

    final class Controller: UIViewController {
        let completion: () -> Void
        private var presented = false
        init(completion: @escaping () -> Void) { self.completion = completion; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presented else { return }
            presented = true
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                self?.completion()
            }
        }
    }
}
