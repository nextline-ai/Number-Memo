import SwiftUI

private struct ServerEdit: Identifiable {
    let id = UUID()
    var server: BooruServer?
}

struct BooruServersView: View {
    @Environment(BooruStore.self) private var store
    @State private var editing: ServerEdit?
    @State private var deleting: BooruServer?
    var body: some View {
        List {
            Section {
                ForEach(store.servers) { server in
                    HStack {
                        Button { store.perform { try store.toggleServer(server) } } label: {
                            HStack(spacing: 12) {
                                Image(systemName: store.selectedServerIDs.contains(server.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(server.name).foregroundStyle(.primary)
                                    Text(server.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { editing = .init(server: server) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Edit") + " " + server.name)
                    }.padding(.vertical, 4).swipeActions {
                        Button(L10n.text("Delete"), role: .destructive) { deleting = server }
                    }
                }
                Button(L10n.text("Add a Server"), systemImage: "plus") { editing = .init() }.accessibilityIdentifier("booru.addServer")
            } header: { Text(L10n.text("Servers")) } footer: { Text(L10n.text("Danbooru, Gelbooru, Old Gelbooru (v0.1.11) and Moebooru compatible servers are supported.")) }
        }.navigationTitle(L10n.text("Servers")).navigationBarTitleDisplayMode(.inline)
            .sheet(item: $editing) { item in BooruServerEditor(server: item.server) }
            .confirmationDialog(L10n.text("Delete Server?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button(L10n.text("Delete"), role: .destructive) { if let deleting { store.perform { try store.deleteServer(deleting); Task { await BooruBrowserSession.reset(deleting) } } }; deleting = nil }
            } message: { Text(L10n.text("This removes the server and its Booru favorites, saved tags, artists, history and blacklist from this device.")) }
    }
}

struct BooruServerEditor: View {
    let server: BooruServer?
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var engine: BooruEngine = .danbooru
    @State private var account = ""
    @State private var apiKey = ""
    @State private var error: String?
    @State private var initialized = false
    @State private var validating = false
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.text("Server")) {
                    TextField(L10n.text("Name"), text: $name).accessibilityIdentifier("booru.serverName")
                    TextField("https://example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(server != nil).accessibilityIdentifier("booru.serverURL")
                        .onChange(of: address) { _, value in
                            if server == nil, (try? BooruServer.validatedURL(value))?.host?.hasSuffix(".booru.org") == true { engine = .oldGelbooru }
                        }
                    Picker(L10n.text("Server Type"), selection: $engine) { ForEach(BooruEngine.allCases) { Text($0.title).tag($0) } }
                }
                if engine != .oldGelbooru { Section {
                    TextField(L10n.text(engine == .gelbooru ? "User ID" : "Username"), text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField(L10n.text(engine == .moebooru ? "Password Hash" : "API Key"), text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                } header: { Text(L10n.text("API Access (Optional)")) } footer: {
                    Text(L10n.text("Use credentials from your server account settings. They are stored securely in Keychain."))
                } }
                if let server {
                    Section {
                        Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = true }
                        NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle(L10n.text(server == nil ? "Add a Server" : "Edit Server"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Save"), action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty).accessibilityIdentifier("booru.serverSave") }
                }
                .sheet(isPresented: $validating) { if let server { BooruValidationView(server: server) } }
                .onAppear {
                    guard !initialized else { return }; initialized = true
                    guard let server else { return }
                    name = server.name; address = server.baseURL.absoluteString; engine = server.engine
                    do { let credentials = try BooruKeychain.read(serverID: server.id); account = credentials.account; apiKey = credentials.apiKey }
                    catch { self.error = error.localizedDescription }
                }
        }
    }
    private func save() {
        do {
            let url = try BooruServer.validatedURL(address)
            let value = BooruServer(id: server?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: url, engine: engine)
            guard !store.servers.contains(where: { $0.id != value.id && $0.baseURL == url }) else { throw BooruError.duplicateServer }
            let credentials = BooruCredentials(account: account.trimmingCharacters(in: .whitespacesAndNewlines), apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            guard credentials.account.isEmpty == credentials.apiKey.isEmpty else { throw BooruError.authentication }
            try BooruKeychain.save(credentials, serverID: value.id)
            try store.saveServer(value)
            if server == nil { try store.setSelectedServers(store.selectedServerIDs + [value.id]) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct BooruBlacklistView: View {
    let server: BooruServer
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    var body: some View {
        Form {
            Section {
                TextEditor(text: $text).frame(minHeight: 240).font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("booru.blacklistText")
            } header: { Text(L10n.text("Tag Blacklist")) } footer: {
                Text(L10n.text("One rule per line. Use tags, rating:explicit, id:123, or artist:name. Remove a rule to unblock content."))
            }
            Section(L10n.text("Example")) { Text("spoilers\ngore -scenery\nrating:explicit\nartist_*").font(.footnote.monospaced()).foregroundStyle(.secondary) }
        }.navigationTitle(server.name).navigationBarTitleDisplayMode(.inline)
            .onAppear { text = store.blacklist(serverID: server.id) }
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button(L10n.text("Save")) {
                    do { try store.setBlacklist(text, serverID: server.id); dismiss() }
                    catch { store.error = error.localizedDescription }
                }.accessibilityIdentifier("booru.blacklistSave")
            } }
    }
}

struct BooruMoreView: View {
    let source: any BooruProviding
    @Environment(AppEnvironment.self) private var env
    @Environment(BooruStore.self) private var store
    @State private var showOnboarding = false
    @State private var showReader = false
    @State private var settingsServerID = ""
    private var settingsServer: BooruServer? { store.servers.first { $0.id == settingsServerID } ?? store.selectedServer }
    @State private var validating: BooruServer?
    @State private var cacheCleared = false
    @State private var confirmClearCache = false
    @SwiftUI.AppStorage("booru.autoLoad", store: ReaderPreferences.booruDefaults) private var autoLoad = false
    @SwiftUI.AppStorage("booru.fitThumbnails", store: ReaderPreferences.booruDefaults) private var fitThumbnails = false
    @SwiftUI.AppStorage("booru.useEmbeddedBrowser", store: ReaderPreferences.booruDefaults) private var useEmbeddedBrowser = false
    var body: some View {
        Form {
            Section {
                NavigationLink { BooruServersView() } label: { Label(L10n.text("Servers"), systemImage: "server.rack") }
                    .accessibilityIdentifier("booru.serversLink")
                if !store.servers.isEmpty {
                    NavigationLink {
                        if store.selectedServers.count == 1, let server = store.selectedServer { BooruPoolsView(server: server, source: source) }
                        else { BooruPoolServersView(source: source) }
                    } label: { Label(L10n.text("Pools"), systemImage: "rectangle.stack") }
                        .accessibilityIdentifier("booru.poolsLink")
                }
            } footer: {
                Text(store.selectedServers.map(\.name).joined(separator: " · "))
            }

            ModeAppearanceSettings()
            LanguageSettingsSection(booru: true)
            Section {
                Toggle(L10n.text("Use Embedded Browser"), isOn: $useEmbeddedBrowser).accessibilityIdentifier("booru.browserToggle")
                Toggle(L10n.text("Fit Entire Thumbnails"), isOn: $fitThumbnails)
                Toggle(L10n.text("Load Next Page Automatically"), isOn: $autoLoad)
            } header: { Text(L10n.text("Browsing")) } footer: {
                Text(L10n.text("Use the website if the native viewer stops working. Turn off to return to the native viewer."))
            }
            if let server = settingsServer {
                Section(L10n.text("Connection & Filters")) {
                    Picker(L10n.text("Server"), selection: Binding(get: { server.id }, set: { settingsServerID = $0 })) {
                        ForEach(store.servers) { Text($0.name).tag($0.id) }
                    }
                    NavigationLink { BooruBlacklistView(server: server) } label: { Label(L10n.text("Tag Blacklist"), systemImage: "eye.slash") }.accessibilityIdentifier("booru.blacklist")
                    Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = server }.accessibilityIdentifier("booru.validate")
                    NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }.accessibilityIdentifier("booru.cookies")
                }
            }
            ReaderSettingsSection(booru: true, isPresented: $showReader)
            SearchHistorySettings(booru: true)
            CloudSyncSection()
            Section {
                NavigationLink { AnimeBoxesImportView() } label: { Label(L10n.text("Import from Anime Boxes"), systemImage: "shippingbox") }
                    .accessibilityIdentifier("booru.importLink")
                Button(L10n.text(cacheCleared ? "Image Cache Cleared" : "Clear Image Cache")) {
                    confirmClearCache = true
                }.accessibilityIdentifier("settings.clearCache")
            } header: { Text(L10n.text("Data & Storage")) } footer: { Text(L10n.text("Booru favorites, tags, artists and history are stored separately from Hitomi, and separately for each server.")) }
            SettingsSupportSection(showOnboarding: $showOnboarding)
            DeveloperInfoSection()
        }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { BooruServerMenu() } }
        .alert(L10n.text("Clear Image Cache?"), isPresented: $confirmClearCache) {
            Button(L10n.text("Clear Image Cache"), role: .destructive) { Task { await BooruThumbnailCache.shared.clear(); cacheCleared = true } }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: { Text(L10n.text("Saved favorites are kept. Images will be downloaded again when needed.")) }
        .sheet(isPresented: $showReader) { ReaderSettingsView(booru: true) }
        .fullScreenCover(isPresented: $showOnboarding) { OnboardingView().environment(env) }
        .sheet(item: $validating) { BooruValidationView(server: $0) }

    }
}
