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
                                    Text(server.displayName).foregroundStyle(.primary)
                                    Text(server.baseURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { editing = .init(server: server) } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Edit") + " " + server.displayName)
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
    var acceptsComics = false
    @Environment(AppEnvironment.self) private var env
    private var isComicsAddress: Bool { acceptsComics && AppEnvironment.supportsComicsAddress(address) }
    @Environment(BooruStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var engineChoice: BooruEngine?
    @State private var showOptions = false
    private var addressURL: URL? { try? BooruServer.validatedURL(address) }
    private var engine: BooruEngine? { engineChoice ?? addressURL.flatMap(BooruEngine.suggested) }
    @State private var account = ""
    @State private var apiKey = ""
    @State private var error: String?
    @State private var initialized = false
    @State private var validating = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com", text: $address).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(server != nil).accessibilityIdentifier("booru.serverURL")
                        .accessibilityLabel(L10n.text("Website Address"))
                    if server == nil { WebsiteAddressSuggestions(address: $address, includesComics: acceptsComics) }
                } header: { Text(L10n.text("Website Address")) } footer: {
                    Text(L10n.text("Enter the website’s home address."))
                }
                if isComicsAddress {
                    Section {
                        Label(L10n.text("Comics Mode"), systemImage: "book")
                    }
                } else {
                    Section {
                        Picker(L10n.text("Server Type"), selection: $engineChoice) {
                            Text(L10n.text("Automatic")).tag(nil as BooruEngine?)
                            ForEach(BooruEngine.allCases) { Text($0.title).tag(Optional($0)) }
                        }.accessibilityIdentifier("booru.serverEngine")
                        if let engine {
                            Label(engine.title, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else if !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(L10n.text("Select the server type for this address."))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: { Text(L10n.text("Connection")) }
                    Section {
                        DisclosureGroup(isExpanded: $showOptions) {
                            TextField(L10n.text("Name (Optional)"), text: $name).accessibilityIdentifier("booru.serverName")
                            if engine != .oldGelbooru {
                                TextField(L10n.text(engine == .gelbooru ? "User ID" : "Username"), text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                                SecureField(L10n.text(engine == .moebooru ? "Password Hash" : "API Key"), text: $apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                                Text(L10n.text("Use credentials from your server account settings. They are stored securely in Keychain."))
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        } label: {
                            Text(L10n.text("Additional Options")).accessibilityIdentifier("booru.serverOptions")
                        }
                    }
                }
                if let server {
                    Section {
                        Button(L10n.text("Validate Client"), systemImage: "checkmark.shield") { validating = true }
                        NavigationLink { BooruCookiesView(server: server) } label: { Label(L10n.text("Cookies"), systemImage: "network.badge.shield.half.filled") }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }.navigationTitle(L10n.text(acceptsComics ? "Connect a Website" : (server == nil ? "Add a Server" : "Edit Server")))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Save"), action: save).disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!isComicsAddress && engine == nil)).accessibilityIdentifier("booru.serverSave") }
                }
                .sheet(isPresented: $validating) { if let server { BooruValidationView(server: server) } }
                .onAppear {
                    guard !initialized else { return }; initialized = true
                    guard let server else { return }
                    name = server.displayName; address = server.baseURL.absoluteString; engineChoice = server.engine; showOptions = true
                    do { let credentials = try BooruKeychain.read(serverID: server.id); account = credentials.account; apiKey = credentials.apiKey }
                    catch { self.error = error.localizedDescription }
                }
        }
    }
    private func save() {
        if isComicsAddress {
            if env.verifySite(input: address) { dismiss() }
            return
        }
        do {
            let url = try BooruServer.validatedURL(address)
            guard let engine else { return }
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = BooruServer(id: server?.id ?? UUID().uuidString, name: displayName.isEmpty ? (url.host ?? url.absoluteString) : displayName, baseURL: url, engine: engine)
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
        }.navigationTitle(server.displayName).navigationBarTitleDisplayMode(.inline)
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
                Text(store.selectedServers.map(\.displayName).joined(separator: " · "))
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
                        ForEach(store.servers) { Text($0.displayName).tag($0.id) }
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
                NavigationLink { BooruBackupView() } label: { Label(L10n.text("Library Management"), systemImage: "externaldrive") }
                    .accessibilityIdentifier("booru.libraryManagement")
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

/// Suggestions only appear after typing; choosing one never connects automatically.
struct WebsiteAddressSuggestion: Identifiable, Equatable {
    let host: String
    let name: String
    let comics: Bool
    var id: String { host }
    static let sites: [Self] = [
        .init(host: "safebooru.org", name: "Safebooru", comics: false),
        .init(host: "danbooru.donmai.us", name: "Danbooru", comics: false),
        .init(host: "gelbooru.com", name: "Gelbooru", comics: false),
        .init(host: "safebooru.donmai.us", name: "Safebooru Danbooru", comics: false),
        .init(host: "yande.re", name: "Yande.re", comics: false),
        .init(host: "konachan.com", name: "Konachan", comics: false),
        .init(host: "rule34.xxx", name: "Rule34", comics: false),
        .init(host: "hitomi.la", name: "Hitomi", comics: true)
    ]
    static func matches(_ input: String, includesComics: Bool, comicsOnly: Bool = false) -> [Self] {
        var prefix = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where prefix.hasPrefix(scheme) { prefix.removeFirst(scheme.count) }
        if prefix.hasPrefix("www.") { prefix.removeFirst(4) }
        guard !prefix.isEmpty else { return [] }
        return sites.filter {
            (!$0.comics || includesComics) && (!comicsOnly || $0.comics) &&
            $0.host != prefix && ($0.host.hasPrefix(prefix) || $0.name.lowercased().hasPrefix(prefix))
        }
    }
}

struct WebsiteAddressSuggestions: View {
    @Binding var address: String
    var includesComics = false
    var comicsOnly = false
    var body: some View {
        ForEach(WebsiteAddressSuggestion.matches(address, includesComics: includesComics, comicsOnly: comicsOnly)) { site in
            Button { address = "https://" + site.host } label: {
                HStack {
                    Image(systemName: site.comics ? "book" : "globe")
                    Text(site.host)
                    Spacer()
                    Image(systemName: "arrow.up.left").font(.caption)
                }.font(.subheadline)
            }.accessibilityIdentifier("website.suggestion." + site.host)
        }
    }
}
