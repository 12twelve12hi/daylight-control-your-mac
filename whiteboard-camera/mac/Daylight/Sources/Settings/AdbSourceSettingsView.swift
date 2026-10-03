import DaylightKit
import Foundation
import SwiftUI

/// Settings > Mirror > "adb source" (LOOSE_ENDS H1): the picker, the one-time Android SDK License gate for Download on
/// first use, the download itself, and the path and version each source resolves to. Work runs on a utility queue;
/// published state changes on main.
final class AdbSourceModel: ObservableObject {
    @Published var located: AdbLocation?
    @Published var failure: String?
    @Published var downloading = false
    @Published var showTerms = false

    let bundledAvailable: Bool
    let downloader: AdbDownloader
    let vendorDirectory: URL
    private let queue = DispatchQueue(label: "com.twelve.daylight.adb.settings", qos: .utility)

    init(bundledAvailable: Bool = AdbSourceRequest.bundleShipsAdb(), downloader: AdbDownloader = AdbDownloader(),
         vendorDirectory: URL = Bundle.main.resourceURL?.appendingPathComponent("Vendor") ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Vendor")) {
        self.bundledAvailable = bundledAvailable
        self.downloader = downloader
        self.vendorDirectory = vendorDirectory
    }

    /// The choices the picker offers: Bundled is hidden on a build without the bundled adb.
    var choices: [AdbSource] {
        return AdbSource.allCases.filter { $0 != .bundled || bundledAvailable }
    }

    func refresh(_ settings: Settings) {
        let request = AdbSourceRequest(source: settings.adbSource, bundledAvailable: bundledAvailable,
                                       termsAcceptedVersion: settings.adbTermsAcceptedVersion,
                                       vendorDirectory: vendorDirectory, downloader: downloader)
        queue.async {
            let result = AdbClient.locateExecutable(request, recordStatus: false)
            DispatchQueue.main.async {
                switch result {
                case let .success(location): self.located = location; self.failure = nil
                case let .failure(error):
                    self.located = nil
                    // Not downloaded yet is the normal state before the first download, not a failure.
                    if case .notDownloaded = error { self.failure = nil } else { self.failure = error.sentence }
                }
            }
        }
    }

    func download(_ store: SettingsStore) {
        downloading = true
        failure = nil
        downloader.ensure { result in
            DispatchQueue.main.async {
                self.downloading = false
                switch result {
                case let .success(location): self.located = location
                case let .failure(error): self.located = nil; self.failure = error.sentence
                }
                self.refresh(store.settings)
            }
        }
    }

    /// The picker's setter: choosing Download before the pinned version's terms were accepted opens the terms first.
    func choose(_ source: AdbSource, store: SettingsStore) {
        if source == .download && store.settings.adbTermsAcceptedVersion != downloader.pins.version {
            showTerms = true
            return
        }
        store.settings.adbSource = source
        refresh(store.settings)
        if source == .download, case .failure = downloader.locateInstalled() { download(store) }
    }

    func acceptTerms(_ store: SettingsStore) {
        store.settings.adbTermsAcceptedVersion = downloader.pins.version
        store.settings.adbSource = .download
        download(store)
    }

    func declineTerms() {
        failure = FailureText.sentence(.adbTermsDeclined)
    }

    static let termsMessage = "Daylight downloads adb from Google (platform-tools \(AdbPins.platformToolsVersion), about 15 MB) into ~/Library/Application Support/Daylight/platform-tools and checks its SHA-256 before use. The download is covered by the Android Software Development Kit License Agreement: \(AdbPins.termsURL.absoluteString). Choose Accept to agree to it and download now."
}

struct AdbSourceSection: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var model: AdbSourceModel

    var body: some View {
        let effective = store.settings.adbSource.effective(bundledAvailable: model.bundledAvailable)
        VStack(alignment: .leading, spacing: 6) {
            Picker("adb source", selection: Binding(get: { effective }, set: { model.choose($0, store: store) })) {
                ForEach(model.choices, id: \.self) { source in Text(source.label).tag(source) }
            }
            if model.downloading {
                HStack { ProgressView().controlSize(.small); Text("Downloading adb...").font(.footnote) }
            } else if let location = model.located {
                Text("\(location.url.path), \(location.version ?? "version not checked")").font(.footnote).foregroundColor(.secondary)
            } else if effective == .download && model.failure == nil {
                Button("Download adb") { model.choose(.download, store: store) }
            }
            if let failure = model.failure {
                Text(failure).font(.footnote).foregroundColor(.red)
                HStack {
                    if effective == .download && store.settings.adbTermsAcceptedVersion == model.downloader.pins.version {
                        Button("Try again") { model.download(store) }
                    }
                    if model.bundledAvailable && effective != .bundled {
                        Button("Use bundled") { model.choose(.bundled, store: store) }
                    }
                }
            }
            if effective == .download {
                Link("Android SDK License", destination: AdbPins.termsURL).font(.footnote)
            }
            Text("A new adb source applies the next time Daylight starts.").font(.footnote).foregroundColor(.secondary)
        }
        .onAppear { model.refresh(store.settings) }
        .alert(isPresented: $model.showTerms) {
            Alert(title: Text("Download adb from Google?"), message: Text(AdbSourceModel.termsMessage),
                  primaryButton: .default(Text("Accept")) { model.acceptTerms(store) },
                  secondaryButton: .cancel { model.declineTerms() })
        }
    }
}
