import SwiftUI
import UniformTypeIdentifiers

public struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var tutorialMode: AppMode = .booru
    @State private var addingServer = false
    @State private var validating: BooruServer?
    @State private var showFilePicker = false
    @State private var isImporting = false
    @State private var importStatus = ""
    @State private var importCompleted = false
    @State private var importSummary = ""
    public init() {}
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { index in
                            Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.18)).frame(height: 4)
                        }
                    }.padding(.top, 12)
                    if step == 0 { setup }
                    else if step == 1 { imports }
                    else { tutorial }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: next) {
                        Text(L10n.text(step == 2 ? "Get Started" : (step == 0 && env.booru.servers.isEmpty ? "Set Up Later" : "Continue"))).font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(isImporting)
                        .tint(step == 0 && env.booru.servers.isEmpty ? Color.secondary : Color.accentColor)
                        .accessibilityIdentifier("onboarding.continue")
                    if step == 0 {
                        NavigationLink { PrivacyPolicyView() } label: { Text(L10n.text("Privacy Policy")).font(.footnote) }
                            .accessibilityIdentifier("onboarding.privacy")
                    }
                    if step == 1 { Text(L10n.text("You can import your data later in Settings.")).font(.caption).foregroundStyle(.secondary) }
                }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
            .navigationTitle(L10n.text("Welcome")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 { Button { step -= 1 } label: { Image(systemName: "chevron.left") }.disabled(isImporting).accessibilityLabel(L10n.text("Back")) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if env.isOnboardingCompleted { Button(L10n.text("Done")) { dismiss() }.disabled(isImporting) }
                }
            }
            .sheet(item: $validating) { BooruValidationView(server: $0) }
            .sheet(isPresented: $addingServer) { BooruServerEditor(server: nil) }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: handleImport)
        }.environment(env.booru)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("Your Websites, Your Library")).font(.largeTitle.bold())
            Text(L10n.text("No websites are included. Add a website you use, or bring your servers and favorites from a backup."))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Label(L10n.text("Connect an Image Website"), systemImage: "link").font(.headline)
                Text(L10n.text("Have a website in mind? Copy its home address from your browser. We will recognize known server types for you."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { addingServer = true } label: {
                    Label(L10n.text("Enter Website Address"), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.addServer")
                ForEach(env.booru.servers) { server in
                    HStack {
                        Label(server.name, systemImage: "checkmark.circle.fill").font(.subheadline)
                        Spacer()
                        Button { validating = server } label: { Image(systemName: "checkmark.shield").frame(width: 36, height: 36) }
                            .accessibilityLabel(L10n.text("Validate Client") + " " + server.name)
                    }
                }
                Text(L10n.text("You can add a website later from Saved, Explore, or More > Servers."))
                    .font(.footnote).foregroundStyle(.secondary)
            }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Button { step = 1 } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("Bring your collection")).font(.headline)
                        Text("Anime Boxes · Violet").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("onboarding.chooseImport")
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.text("iCloud Sync"), isOn: Binding(get: { env.sync.enabled }, set: { env.sync.enabled = $0 }))
                Text(L10n.text("iCloud sync is optional and starts enabled. Your library and selected settings sync through your Apple account. You can change this in Settings."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var imports: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 42)).foregroundStyle(.tint)
            Text(L10n.text("Bring your collection")).font(.title.bold())
            Text(L10n.text("Import either library, or both. Your data stays in its own mode.")).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                Label("Violet → " + L10n.text("Comics"), systemImage: "book.fill").font(.headline)
                Text(L10n.text("In Files, open the Violet folder and choose user.db for your library, or data.db for metadata.")).font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.text("Choose a Violet Database"), systemImage: "doc.badge.plus") { showFilePicker = true }
                    .buttonStyle(.bordered).disabled(isImporting).accessibilityIdentifier("onboarding.violetImport")
                if isImporting { ProgressView(importStatus) }
                else if importCompleted { Label(importSummary, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if !importStatus.isEmpty { Text(importStatus).foregroundStyle(.red) }
            }.padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            NavigationLink { AnimeBoxesImportView() } label: {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Anime Boxes → " + L10n.text("Images"), systemImage: "shippingbox.fill").font(.headline)
                    Text(L10n.text("Move your servers, favorites and search history from Anime Boxes.")).font(.subheadline).foregroundStyle(.secondary)
                    Label(L10n.text("Import from Anime Boxes"), systemImage: "chevron.right").font(.subheadline.weight(.medium))
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.buttonStyle(.plain).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("onboarding.import")
        }
    }

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text("Switch from the top")).font(.largeTitle.bold())
            Text(L10n.text("Tap or slide the switch at the top of any tab to move between your books and images. Try it here."))
                .foregroundStyle(.secondary)
            VStack(spacing: 28) {
                HStack {
                    Text(L10n.text("Saved")).font(.headline)
                    Spacer()
                    AppModeSwitch(previewMode: $tutorialMode)
                    Spacer()
                    Image(systemName: "plus").frame(width: 32)
                }
                Image(systemName: tutorialMode == .hitomi ? "book.fill" : "photo.fill")
                    .font(.system(size: 64)).foregroundStyle(.tint).contentTransition(.symbolEffect(.replace))
                Text(tutorialMode.title).font(.title2.bold())
                Text(L10n.text(tutorialMode == .hitomi ? "Organize works, follow artists and read with image translation." : "Browse multiple image servers and collect favorites in folders."))
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(24).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            Text(L10n.text("Comics mode requires a website address. Select the book icon after setup to connect it. You will start in image mode."))
                .font(.subheadline).foregroundStyle(.secondary)
            Label(L10n.text("Each mode keeps its own library and settings."), systemImage: "square.stack.3d.up")
                .font(.footnote).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("onboarding.tutorial")
    }

    private func next() {
        if step == 0 {
            env.mode = .booru
            step = 1
        } else if step == 1 { step = 2 }
        else { env.mode = .booru; env.isOnboardingCompleted = true; dismiss() }
    }

    private func handleImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        isImporting = true
        importStatus = L10n.text("Checking file…")

        let importer = env.violetImporter
        let envRef = env

        Task.detached(priority: .userInitiated) {
            let hasAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
            }

            var readPath = url.path
            var tempURL: URL? = nil

            let isUser = VioletImportService.isUserDb(at: readPath)
            let isData = VioletImportService.isDataDb(at: readPath)

            if !isUser && !isData {
                let tempDir = FileManager.default.temporaryDirectory
                let copyUrl = tempDir.appendingPathComponent("\(UUID().uuidString)_\(url.lastPathComponent)")
                do {
                    try? FileManager.default.removeItem(at: copyUrl)
                    try FileManager.default.copyItem(at: url, to: copyUrl)
                    readPath = copyUrl.path
                    tempURL = copyUrl
                } catch {
                    await MainActor.run {
                        self.isImporting = false
                        self.importStatus = L10n.text("Unable to read file: %@", String(describing: error.localizedDescription))
                    }
                    return
                }
            }

            defer {
                if let tempURL {
                    try? FileManager.default.removeItem(at: tempURL)
                }
            }

            do {
                if VioletImportService.isUserDb(at: readPath) {
                    await MainActor.run { self.importStatus = L10n.text("Importing library from user.db…") }
                    let res = try importer.importUserDb(path: readPath)
                    await MainActor.run {
                        self.isImporting = false
                        self.importCompleted = true
                        self.importSummary = L10n.text("user.db imported!\n%@ folders, %@ works", String(describing: res.folders), String(describing: res.works))
                        envRef.startCoverQueue()
                    }
                } else if VioletImportService.isDataDb(at: readPath) {
                    await MainActor.run { self.importStatus = L10n.text("Matching data.db metadata…") }
                    let res = try importer.matchAndFillWorks(fromDataDb: readPath)
                    await MainActor.run {
                        self.isImporting = false
                        self.importCompleted = true
                        self.importSummary = L10n.text("data.db matched!\nUpdated %2$@ of %1$@ works", String(describing: res.totalWorks), String(describing: res.matched))
                    }
                } else {
                    await MainActor.run {
                        self.isImporting = false
                        self.importStatus = L10n.text("Unsupported database format. Select user.db or data.db.")
                    }
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.importStatus = L10n.text("Import error: %@", String(describing: error.localizedDescription))
                }
            }
        }
    }
}
