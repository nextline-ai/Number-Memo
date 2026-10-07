import SwiftUI
import GRDB

struct TasteDashboard: View {
    let mode: TasteMode
    var comicLanguage: String = L10n.contentLanguage
    var isRoot = false
    var explore: (() -> Void)? = nil
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var bookmarks = Set<Int64>()
    @State private var saveFeedback: WorkSaveFeedback?
    @State private var opened: TasteRecommendation?
    @State private var detail: TasteTag?
    private var feed: TasteFeedState { env.taste.feed(mode) }
    private var columns: [GridItem] { WorkGridLayout.columns(typeSize.isAccessibilitySize ? 1 : env.gridColumns(for: mode == .booru ? .booru : .hitomi)) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                heading
                if !env.taste.control.enabled { paused }
                else {
                    if let failure = feed.error { message(failure, icon: "wifi.exclamationmark", action: "Try Again", perform: refresh) }
                    if let snapshot = feed.snapshot {
                        if snapshot.tags.isEmpty && feed.results.items.isEmpty { gettingStarted }
                        else {
                            if let report = feed.report, let insight = report.insights.first, let tag = snapshot.tags.first(where: { $0.id == insight.tagKey }) {
                                highlight(insight, tag: tag, report: report, snapshot: snapshot)
                            }
                            works
                        }
                    } else if feed.loading {
                        TasteSurface { HStack(spacing: 12) { ProgressView(); Text(L10n.text("Preparing your insights…")).font(.subheadline).foregroundStyle(.secondary) }.padding(.vertical, 24) }
                    }
                    about
                }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 32)
            .frame(maxWidth: 960).frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .tint(TastePresentation.accent)
        .navigationTitle(isRoot ? "" : L10n.text("Taste Analysis"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    NavigationLink { TasteSettingsView(mode: mode) } label: { Image(systemName: "slider.horizontal.3").frame(width: 36, height: 44) }.accessibilityLabel(L10n.text("Settings"))
                    Button(action: refresh) { Image(systemName: "arrow.clockwise").frame(width: 36, height: 44) }
                        .disabled(feed.loading || !env.taste.control.enabled)
                        .accessibilityLabel(L10n.text("Refresh recommendations")).accessibilityIdentifier("taste.refresh")
                }
            }
            if isRoot {
                ToolbarItem(placement: .topBarLeading) { LiquidGlassTitleCapsule("AI") }
                ToolbarItem(placement: .principal) { AppModeSwitch() }
            }
        }
        .accessibilityIdentifier("taste.dashboard")
        .task {
            let observation = ValueObservation.tracking { db in Set(try Int64.fetchAll(db, sql: "SELECT gallery_id FROM works")) }
            do { for try await ids in observation.values(in: env.database.dbWriter) { bookmarks = ids } } catch { }
        }
        .workSaveFeedback($saveFeedback, identifier: "taste.saveStatus")
        .onAppear { feed.ensureLoaded(mode: mode, env: env, language: comicLanguage) }
        .onChange(of: env.taste.control.enabled) { _, enabled in if enabled { feed.ensureLoaded(mode: mode, env: env, language: comicLanguage) } }
        .refreshable { refresh(); await feed.waitForRefresh() }
        .tasteWorkPresentation($opened) { .recommended($0.reason.name, session: feed.discoverySession) }
        .navigationDestination(item: $detail) { TasteTagDetail(tag: $0, mode: mode) }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("AI Recommendations")).font(.largeTitle.bold())
            Text(L10n.text("Inspired by what you love. Made for your next discovery.")).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
    private var gettingStarted: some View {
        TasteSurface {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "heart.text.clipboard").font(.system(size: 40)).foregroundStyle(TastePresentation.accent).padding(.top, 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("Start with something you love")).font(.title2.bold())
                    Text(L10n.text("Save a few works as you explore. Your recommendations and taste discoveries will grow from there.")).foregroundStyle(.secondary)
                }
                Label(L10n.text("Browse, save, discover"), systemImage: "sparkles").font(.subheadline.weight(.medium))
                if let explore {
                    Button(action: explore) { Text(L10n.text("Explore works")).frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.borderedProminent).tint(TastePresentation.accent).accessibilityIdentifier("taste.startExploring")
                }
            }.padding(4)
        }.accessibilityElement(children: .contain).accessibilityIdentifier("taste.empty")
    }
    private var paused: some View {
        message(L10n.text("Taste analysis is paused on your devices."), icon: "pause.circle", action: "Enable Taste Analysis") { env.taste.change { $0.enabled = true } }
    }
    private func message(_ text: String, icon: String, action: String, perform: @escaping () -> Void) -> some View {
        TasteSurface {
            VStack(alignment: .leading, spacing: 14) {
                Label(text, systemImage: icon).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L10n.text(action), action: perform).font(.subheadline.weight(.semibold)).buttonStyle(.bordered).tint(TastePresentation.accent)
            }
        }
    }
    private func highlight(_ insight: TasteInsight, tag: TasteTag, report: TasteReport, snapshot: TasteSnapshot) -> some View {
        Button { detail = tag } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(L10n.text(tag.discovery ? "A new side of your taste" : "A thread in your favorites"), systemImage: "sparkles").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }.foregroundStyle(TastePresentation.accent)
                Text(TastePresentation.name(tag.name)).font(.title2.bold()).foregroundStyle(.primary)
                Text(TastePresentation.explanation(insight, tag: tag, snapshot: snapshot)).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if report.generatedByAI { Label(L10n.text("On-device AI insights"), systemImage: "apple.intelligence").font(.caption2).foregroundStyle(.secondary) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [TastePresentation.accent.opacity(0.12), Color(uiColor: .secondarySystemGroupedBackground)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(TastePresentation.accent.opacity(0.13), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: 22))
        }.buttonStyle(.plain).accessibilityIdentifier("taste.highlight")
    }
    private var works: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    TasteSectionHeading(title: "Picked for you")
                    evidenceLink
                }
            } else {
                HStack { TasteSectionHeading(title: "Picked for you"); Spacer(); evidenceLink }
            }
            if !feed.results.items.isEmpty {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                    ForEach(feed.results.items) { item in
                        TasteRecommendationCard(item: item, open: { opened = item }, toggle: { toggle(item) }, isBookmarked: bookmarks.contains(item.item.id))
                            .onAppear {
                                if item.id == feed.results.items.last?.id && feed.results.failures.isEmpty {
                                    Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) }
                                }
                            }
                    }
                }
            } else if feed.loading {
                TasteSurface { HStack(spacing: 12) { ProgressView(); Text(L10n.text("Finding works for you…")).font(.subheadline).foregroundStyle(.secondary) } }
            } else if feed.results.failures.isEmpty && !feed.results.cursor.hasMore {
                message(L10n.text("You're all caught up. Explore more works or refresh for new recommendations."), icon: "checkmark.circle", action: explore == nil ? "Try Again" : "Explore works") { if let explore { explore() } else { refresh() } }
            }
            if feed.loading && !feed.results.items.isEmpty { ProgressView().frame(maxWidth: .infinity) }
            if feed.results.cursor.hasMore && !feed.loading && feed.snapshot != nil {
                if feed.results.failures.isEmpty {
                    Button {
                        Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) }
                    } label: {
                        Group { if feed.loadingMore { ProgressView() } else { Text(L10n.text("Continue browsing")) } }
                            .frame(maxWidth: .infinity).padding()
                    }.disabled(feed.loadingMore)
                        .accessibilityIdentifier("taste.loadMore")
                }
            } else if !feed.loading && !feed.results.items.isEmpty {
                Text(L10n.text("You've reached the end of these recommendations.")).font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding()
            }
            if !feed.results.failures.isEmpty {
                message(L10n.text("Some sources could not be loaded: %@", feed.results.failures.joined(separator: ", ")), icon: "wifi.exclamationmark", action: "Try Again") { Task { await feed.loadMore(mode: mode, env: env, language: comicLanguage) } }
            }
        }
    }
    private var evidenceLink: some View {
        NavigationLink { TasteTagList(tags: feed.snapshot?.tags ?? [], mode: mode) } label: {
            Label(L10n.text("Recommendation evidence"), systemImage: "arrow.up.right").font(.subheadline.weight(.medium))
        }.accessibilityIdentifier("taste.evidence")
    }
    private var about: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisclosureGroup(L10n.text("About your recommendations")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(OnDeviceInsightService.availabilityMessage)
                    Text(L10n.text("AI analyzes anonymous statistics on this device. Analysis records are kept until you delete them and sync through iCloud when enabled. You can change these options in Settings."))
                    Text(L10n.text("Recommendation searches send the selected tags to your connected websites. Your taste profile is not sent."))
                }.padding(.top, 8)
            }.font(.footnote).foregroundStyle(.secondary).tint(.secondary)
        }.padding(.horizontal, 4)
    }

    private func toggle(_ item: TasteRecommendation) {
        saveFeedback = .perform { try TasteRecommendationAction.toggle(item, env: env, session: feed.discoverySession) }
    }
    private func refresh() { feed.refresh(mode: mode, env: env, language: comicLanguage) }
}
