import SwiftUI

struct TasteReportsView: View {
    @State private var mode: TasteMode
    let period: TastePeriod
    @Environment(AppEnvironment.self) private var env
    @State private var offset: Int
    @State private var snapshot: TasteSnapshot?
    @State private var failed = false
    @State private var report: TasteReport?
    @State private var displayedKey = ""
    private var card: Binding<Int> { Binding(get: { cards[displayedKey, default: 0] }, set: { cards[displayedKey] = $0 }) }
    @State private var loaded: [String: (TasteSnapshot, TasteReport?)] = [:]
    @State private var cards: [String: Int] = [:]
    private var requestKey: String { "\(mode.rawValue):\(offset):\(env.taste.control.analysisKey(mode))" }
    init(mode: TasteMode, period: TastePeriod) {
        _mode = State(initialValue: mode); self.period = period
        _offset = State(initialValue: period == .month ? -1 : 0)
    }
    var body: some View {
        VStack(spacing: 12) {
            TastePeriodNavigation(period: period, offset: $offset, timeZone: env.taste.control.timeZone, latestOffset: period == .month ? -1 : 0)
                .padding(.horizontal).fixedSize(horizontal: false, vertical: true)
            if !env.taste.control.enabled {
                ContentUnavailableView(L10n.text("Taste analysis is paused on your devices."), systemImage: "pause.circle")
            } else if let snapshot {
                if period == .month {
                    monthly(snapshot)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            TasteStatisticsView(snapshot: snapshot, period: period, timeZone: env.taste.control.timeZone)
                            if snapshot.saves == 0 { Text(L10n.text("No saved works in this period. Try the previous period to see earlier activity.")).foregroundStyle(.secondary) }
                            if let report, !report.insights.isEmpty {
                                TasteSectionHeading(title: "What stands out")
                                ForEach(report.insights) { insight in
                                    if let tag = snapshot.tags.first(where: { $0.id == insight.tagKey }) {
                                        NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: {
                                            TasteSurface {
                                                VStack(alignment: .leading, spacing: 10) {
                                                    Text(TastePresentation.name(tag.name)).font(.headline)
                                                    Text(TastePresentation.explanation(insight, tag: tag, snapshot: snapshot)).font(.subheadline).foregroundStyle(.secondary)
                                                    if report.generatedByAI { Label(L10n.text("On-device AI insights"), systemImage: "apple.intelligence").font(.caption).foregroundStyle(.secondary) }
                                                }
                                            }
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                            if !snapshot.tags.isEmpty {
                                NavigationLink { TasteTagList(tags: snapshot.tags, mode: mode) } label: { Label(L10n.text("Recommendation evidence"), systemImage: "arrow.up.right") }
                                ForEach(snapshot.tags.prefix(5)) { tag in
                                    NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: { TasteSurface { TasteTagRow(tag: tag) } }.buttonStyle(.plain)
                                }
                            }
                        }.padding().frame(maxWidth: 960).frame(maxWidth: .infinity)
                    }
                }
            } else if failed {
                ContentUnavailableView {
                    Label(L10n.text("Unable to update taste analysis."), systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                } actions: { Button(L10n.text("Try Again")) { Task { await load() } } }
            } else { Spacer(); ProgressView(); Spacer() }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(L10n.text(period == .month ? "Monthly Recap" : "Weekly statistics"))
        .navigationBarTitleDisplayMode(.inline)
        .tint(TastePresentation.accent)
        .accessibilityIdentifier(period == .month ? "taste.monthly" : "taste.weekly")
        .toolbar { ToolbarItem(placement: .principal) {
            AppModeSwitch(previewMode: Binding(get: { mode == .booru ? .booru : .hitomi }, set: { mode = $0 == .booru ? .booru : .comics }))
        } }
        .task(id: requestKey) { await load() }
    }
    private func monthly(_ snapshot: TasteSnapshot) -> some View {
        VStack(spacing: 12) {
            TabView(selection: card) {
                recapCard(0, colors: [.indigo, .purple]) {
                    Image(systemName: "apple.intelligence").font(.system(size: 42)).accessibilityHidden(true)
                    Text(L10n.text("A month of discoveries")).font(.largeTitle.bold())
                    Text(snapshot.saves.formatted()).font(.system(size: 84, weight: .bold, design: .rounded)).minimumScaleFactor(0.5).lineLimit(1)
                    Text(L10n.text("Newly saved works")).font(.title2)
                    if let previous = snapshot.previousSaves {
                        Text(L10n.text("%@ saved in the previous period", String(previous))).font(.subheadline).opacity(0.85)
                    }
                    if snapshot.saves == 0 { Text(L10n.text("No saved works in this period. Try the previous period to see earlier activity.")) }
                }.tag(0)
                recapCard(1, colors: [.blue, .indigo]) {
                    Text(L10n.text("The tags that defined your month")).font(.largeTitle.bold())
                    ForEach(Array(snapshot.tags.prefix(5).enumerated()), id: \.element.id) { rank, tag in
                        NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(String(rank + 1)).font(.title3.monospacedDigit()).opacity(0.65)
                                Text(TastePresentation.name(tag.name)).font(.title2.bold()).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(String(tag.count)).font(.headline.monospacedDigit())
                            }.padding(.vertical, 10)
                        }.buttonStyle(.plain)
                    }
                    if snapshot.tags.isEmpty { Text(L10n.text("More discoveries are waiting")) }
                }.tag(1)
                recapCard(2, colors: [.purple, .pink]) {
                    Image(systemName: "sparkles").font(.system(size: 42)).accessibilityHidden(true)
                    Text(L10n.text("A possible new favorite")).font(.largeTitle.bold())
                    if let tag = snapshot.tags.first(where: \.discovery) {
                        Text(TastePresentation.name(tag.name)).font(.largeTitle.bold())
                        Text(L10n.text("You saved %@ works with this tag without searching for it, across %@ sessions.", String(tag.hidden), String(tag.sessions.count))).font(.title3)
                        NavigationLink { TasteTagDetail(tag: tag, mode: mode) } label: { Label(L10n.text("Your evidence"), systemImage: "arrow.up.right").font(.headline) }.buttonStyle(.plain)
                    } else { Text(L10n.text("Your next hidden favorite is still taking shape. Keep saving what catches your eye.")).font(.title3) }
                    Text(L10n.text("Patterns describe your activity in this app. They are suggestions, not conclusions about you.")).font(.footnote).opacity(0.8)
                }.tag(2)
                recapCard(3, colors: [.teal, .blue]) {
                    Text(L10n.text("Your month in motion")).font(.largeTitle.bold())
                    recapMetric(snapshot.activity.count, title: "Active days")
                    recapMetric(snapshot.searches, title: "Searches")
                    if let busiest = snapshot.activity.max(by: { $0.value < $1.value }) {
                        Text(L10n.text("Your most active day")).font(.headline)
                        Text(busiest.key, format: .dateTime.month().day()).font(.title.bold())
                            .environment(\.timeZone, TimeZone(identifier: env.taste.control.timeZone) ?? .gmt)
                        Text(L10n.text("%@ saved works", String(busiest.value)))
                    }
                }.tag(3)
            }.tabViewStyle(.page(indexDisplayMode: .never)).frame(minHeight: 0, maxHeight: .infinity)
            HStack(spacing: 16) {
                Button { withAnimation { card.wrappedValue -= 1 } } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.disabled(card.wrappedValue == 0).accessibilityLabel(L10n.text("Previous card"))
                ForEach(0..<4) { index in
                    Capsule().fill(card.wrappedValue == index ? TastePresentation.accent : Color.secondary.opacity(0.2)).frame(width: card.wrappedValue == index ? 24 : 8, height: 8)
                }
                Button { withAnimation { card.wrappedValue += 1 } } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.disabled(card.wrappedValue == 3).accessibilityLabel(L10n.text("Next card"))
            }.fixedSize(horizontal: false, vertical: true).accessibilityElement(children: .contain).accessibilityValue("\(card.wrappedValue + 1) / 4")
        }.frame(maxWidth: 800).frame(maxWidth: .infinity)
    }
    private func recapMetric(_ value: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text(L10n.text(title)).font(.title3)
        }
    }
    private func recapCard<Content: View>(_ index: Int, colors: [Color], @ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(L10n.text(mode == .booru ? "Images" : "Comics").uppercased()).font(.caption.bold()).tracking(3).opacity(0.7)
                    content()
                    Spacer(minLength: 0)
                }.padding(28).frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
            }.foregroundStyle(.white)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .accessibilityIdentifier("taste.recap.card.\(index)")
        }.padding(.horizontal, 20)
    }
    @MainActor private func load() async {
        let key = requestKey
        displayedKey = key; failed = false
        guard env.taste.control.enabled else { snapshot = nil; report = nil; return }
        if let existing = loaded[key] { snapshot = existing.0; report = existing.1; return }
        snapshot = nil; report = nil
        do {
            let result = try await env.taste.snapshot(mode, period: period, offset: offset)
            try Task.checkCancellation(); snapshot = result
            loaded[key] = (result, nil)
            let control = env.taste.control
            let cached = try env.taste.store(mode).report(digest: result.digest, language: L10n.language, epoch: control.epoch)
            if let cached, cached.isValid(for: result), cached.generatedByAI && control.aiEnabled { report = cached }
            else {
                let generated = await OnDeviceInsightService.report(snapshot: result, control: control, language: L10n.language)
                try Task.checkCancellation()
                guard env.taste.control == control else { return }
                report = generated; try env.taste.store(mode).saveReport(generated)
            }
            loaded[key] = (result, report)
        } catch is CancellationError { }
        catch { failed = true }
    }
}

/// One banner above the shared tab container, with dismissal persisted per month.
struct TasteRecapBanner: View {
    let mode: TasteMode
    let date: Date
    let open: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 12) {
                    Image(systemName: "apple.intelligence").font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.text("Your monthly recap is ready")).font(.subheadline.bold())
                        Text(date, format: .dateTime.year().month(.wide)).font(.caption)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.bold())
                }.padding(.leading, 16).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("taste.recap.open")
            Button(action: dismiss) { Image(systemName: "xmark").font(.subheadline.bold()).frame(width: 44, height: 44) }
                .buttonStyle(.plain).accessibilityLabel(L10n.text("Dismiss recap banner")).accessibilityIdentifier("taste.recap.dismiss")
        }.foregroundStyle(.white)
            .background(LinearGradient(colors: [.indigo, .purple], startPoint: .leading, endPoint: .trailing), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16).padding(.vertical, 6)
    }
}
