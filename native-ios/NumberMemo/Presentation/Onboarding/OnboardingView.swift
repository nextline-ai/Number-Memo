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
    private var hasConnection: Bool { env.isSiteVerified || !env.booru.servers.isEmpty }
    private let importsOnly: Bool
    public init(importsOnly: Bool = false) {
        self.importsOnly = importsOnly
        _step = State(initialValue: importsOnly ? 1 : 0)
    }
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !importsOnly {
                        HStack(spacing: 6) {
                            ForEach(0..<3) { index in
                                Capsule().fill(index <= step ? Color.accentColor : Color.secondary.opacity(0.18)).frame(height: 4)
                            }
                        }.padding(.top, 12)
                    }
                    if step == 0 { setup }
                    else if step == 1 { imports }
                    else { tutorial }
                }.padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button(action: next) {
                        Text(L10n.text(importsOnly ? "Done" : step == 2 ? "Get Started" : (step == 0 && !hasConnection ? "Set Up Later" : "Continue"))).font(.headline)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.borderedProminent).controlSize(.large).disabled(isImporting)
                        .tint(step == 0 && !hasConnection ? Color.secondary : Color.accentColor)
                        .accessibilityIdentifier("onboarding.continue")
                    if step == 0 {
                        NavigationLink { PrivacyPolicyView() } label: { Text(L10n.text("Privacy Policy")).font(.footnote) }
                            .accessibilityIdentifier("onboarding.privacy")
                    }
                }.padding(.horizontal, 24).padding(.vertical, 12).background(.bar)
            }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step > 0 && !importsOnly { Button { step -= 1 } label: { Image(systemName: "chevron.left") }.disabled(isImporting).accessibilityLabel(L10n.text("Back")) }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if env.isOnboardingCompleted { Button(L10n.text("Done")) { dismiss() }.disabled(isImporting) }
                }
            }
            .sheet(item: $validating) { BooruValidationView(server: $0) }
            .sheet(isPresented: $addingServer) { BooruServerEditor(server: nil, acceptsComics: true) }
            .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: handleImport)
        }.environment(env.booru)
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("Connect a Website")).font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 16) {
                Button { addingServer = true } label: {
                    Label(L10n.text("Enter Website Address"), systemImage: "plus.circle")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).accessibilityIdentifier("onboarding.addServer")
                if env.isSiteVerified {
                    Label(L10n.text("Comics Mode"), systemImage: "checkmark.circle.fill")
                        .font(.subheadline).accessibilityIdentifier("onboarding.comicsConnected")
                }
                ForEach(env.booru.servers) { server in
                    HStack {
                        Label(server.displayName, systemImage: "checkmark.circle.fill").font(.subheadline)
                        Spacer()
                        Button { validating = server } label: { Image(systemName: "checkmark.shield").frame(width: 36, height: 36) }
                            .accessibilityLabel(L10n.text("Validate Client") + " " + server.displayName)
                    }
                }
            }.padding(18).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            Button { step = 1 } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.and.arrow.down").font(.title2)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L10n.text("Import Data")).font(.headline)
                        Text("Anime Boxes · Violet").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .accessibilityIdentifier("onboarding.chooseImport")
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L10n.text("iCloud Sync"), isOn: Binding(get: { env.sync.enabled }, set: { env.sync.enabled = $0 }))
                Text(L10n.text("Sync saved items and settings across your devices."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var imports: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "square.and.arrow.down").font(.system(size: 42)).foregroundStyle(.tint)
            Text(L10n.text("Import Data")).font(.title.bold())
            VStack(alignment: .leading, spacing: 12) {
                Label("Violet", systemImage: "book.fill").font(.headline)
                Text("user.db · data.db").font(.subheadline).foregroundStyle(.secondary)
                Button(L10n.text("Choose File"), systemImage: "doc.badge.plus") { showFilePicker = true }
                    .buttonStyle(.bordered).disabled(isImporting).accessibilityIdentifier("onboarding.violetImport")
                if isImporting { ProgressView(importStatus) }
                else if importCompleted { Label(importSummary, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                else if !importStatus.isEmpty { Text(importStatus).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 12) {
                Label("Anime Boxes", systemImage: "shippingbox.fill").font(.headline)
                Text(".abbj").font(.subheadline).foregroundStyle(.secondary)
                NavigationLink { AnimeBoxesImportView() } label: {
                    Label(L10n.text("Import"), systemImage: "doc.badge.plus")
                }.buttonStyle(.bordered).accessibilityIdentifier("onboarding.import")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var tutorial: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.text("Switch Modes")).font(.largeTitle.bold())
            Text(L10n.text("Use the top switch for comics and images."))
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
            }.padding(24).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
            Label(L10n.text("Each mode keeps its own library and settings."), systemImage: "square.stack.3d.up")
                .font(.footnote).foregroundStyle(.secondary)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("onboarding.tutorial")
    }

    private func next() {
        if importsOnly { dismiss(); return }
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
