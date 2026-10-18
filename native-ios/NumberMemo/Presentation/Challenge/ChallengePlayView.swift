import SwiftUI

struct ChallengePlayHost: View {
    let game: ChallengeDefinition
    let store: ChallengeStore
    let source: any BooruProviding
    @Environment(\.dismiss) private var dismiss
    @State private var controller: ChallengeSessionController?
    @State private var error: String?
    var body: some View {
        Group {
            if let controller { ChallengePlayView(controller: controller, source: source) }
            else if let error { ContentUnavailableView(L10n.text("Unable to Continue"), systemImage: "exclamationmark.triangle", description: Text(error)) }
            else { ProgressView() }
        }
        .tint(.purple)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.text("Close")) { dismiss() }.accessibilityIdentifier("challenge.close") } }
        .task {
            guard controller == nil else { return }
            do { controller = try ChallengeSessionController(game: game, store: store) }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct ChallengePlayView: View {
    @Bindable var controller: ChallengeSessionController
    let source: any BooruProviding
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var restarting = false
    @State private var showingHelp = false
    var body: some View {
        Group {
            if controller.session.phase == .ended {
                ScrollView { VStack(spacing: 28) { ending }.frame(maxWidth: 640).padding(24).frame(maxWidth: .infinity) }
            } else {
                ChallengeReferenceView(controller: controller, source: source, header: AnyView(controls))
            }
        }.disabled(controller.unavailable)
        .modifier(ChallengeRevealModifier(controller: controller))
        .tint(.purple)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(controller.session.definition.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(L10n.text("How to Play"), systemImage: "text.book.closed") { showingHelp = true }
                    .accessibilityIdentifier("challenge.help")
                Button(L10n.text("Restart"), role: .destructive) { restarting = true }
            } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel(L10n.text("Challenge Settings")).accessibilityIdentifier("challenge.menu")
        } }
        .sheet(isPresented: $showingHelp) { ChallengeHelpView(game: controller.session.definition) }
        .alert(L10n.text("Restart Challenge?"), isPresented: $restarting) {
            Button(L10n.text("Restart"), role: .destructive) { controller.restart() }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .challengeError($controller.error)
    }
    private var controls: some View {
        Group {
            if sizeClass == .regular && !typeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 24) {
                    ChallengeReelsView(controller: controller).frame(maxWidth: .infinity)
                    VStack(spacing: 16) { mission; ChallengeSessionControls(controller: controller) }.frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 16) { ChallengeReelsView(controller: controller); mission; ChallengeSessionControls(controller: controller) }
            }
        }.padding(.top, 8)
    }
    @ViewBuilder private var mission: some View {
        if let mission = controller.session.mission, controller.session.phase != .spinning {
            VStack(alignment: .leading, spacing: 10) {
                Label(L10n.text("Current Mission"), systemImage: "sparkles").font(.subheadline.weight(.semibold)).foregroundStyle(.purple)
                Text(mission.text).font(.title3.weight(.medium)).accessibilityIdentifier("challenge.mission")
                if !mission.tags.isEmpty {
                    DisclosureGroup(L10n.text("Search Tags")) {
                        Text(mission.tags.joined(separator: " ")).font(.caption.monospaced()).foregroundStyle(.secondary)
                        Button(L10n.text("Copy Tags"), systemImage: "doc.on.doc") { UIPasteboard.general.string = mission.tags.joined(separator: " ") }
                    }.font(.caption)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding().background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }
    @ViewBuilder private var ending: some View {
        if let ending = controller.session.ending {
            ChallengeEndingReveal(ending: ending, choices: controller.session.definition.endings, instant: controller.session.spinSpeed == "instant")
            Button(L10n.text("Play Again"), systemImage: "arrow.clockwise") { controller.restart() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

struct ChallengeReelsView: View {
    let controller: ChallengeSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .caption) private var labelHeight = 44.0
    var body: some View {
        VStack(spacing: 22) {
            HStack(alignment: .firstTextBaseline) {
                Label(L10n.text("Progress"), systemImage: "flag.checkered").font(.headline).foregroundStyle(.secondary)
                Spacer()
                Text("\(controller.session.score) / \(controller.session.definition.target)")
                    .font(.system(.title, design: .rounded, weight: .bold)).monospacedDigit().accessibilityIdentifier("challenge.score")
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.purple.opacity(0.12))
                    Capsule().fill(LinearGradient(colors: [.purple.opacity(0.65), .purple], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * controller.session.progress)
                }
            }.frame(height: 12).accessibilityHidden(true)
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
            layout {
                ForEach(0..<3) { index in
                    let title = index < 2 ? controller.session.definition.reels[index].title : L10n.text("Goal")
                    let settled = controller.session.mission != nil && (controller.session.phase != .spinning || controller.stoppedReels > index || reduceMotion)
                    VStack(spacing: 10) {
                        Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                            .multilineTextAlignment(.center)
                            .frame(height: typeSize.isAccessibilitySize ? nil : labelHeight)
                        ChallengeReelStrip(finalValue: finalValue(index), options: options(index),
                            token: controller.session.mission?.id ?? "", spinning: controller.session.phase == .spinning && !reduceMotion && controller.session.spinSpeed != "instant",
                            duration: [2.0, 2.8, 3.6][index] * (controller.session.spinSpeed == "fast" ? 0.5 : 1))
                            .accessibilityLabel(title).accessibilityValue(settled ? finalValue(index) : L10n.text("Drawing Mission…"))
                            .accessibilityIdentifier("challenge.reel.\(index)")
                            .padding(10)
                            .foregroundStyle(settled ? Color.white : Color.primary)
                            .background {
                                RoundedRectangle(cornerRadius: 20).fill(settled ? Color.purple : Color(uiColor: .secondarySystemGroupedBackground))
                            }
                            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.purple.opacity(settled ? 0.9 : 0.3), lineWidth: 1.5))
                            .shadow(color: .purple.opacity(settled ? 0.25 : 0), radius: 12, y: 4)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: settled)
                    }.frame(maxWidth: .infinity)
                }
            }
            if [.idle, .spinning].contains(controller.session.phase) {
            Button(action: controller.draw) {
                Label(L10n.text("Draw Mission"), systemImage: "dice").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }.buttonStyle(.borderedProminent).tint(.purple).disabled(controller.session.phase != .idle)
                .accessibilityIdentifier("challenge.draw")
            }
        }
        .padding(20)
        .background(LinearGradient(colors: [.purple.opacity(0.08), .purple.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
    }
    private func finalValue(_ index: Int) -> String {
        guard let mission = controller.session.mission else { return "—" }
        return index < 2 ? mission.selections[index].text : mission.goalText
    }
    private func options(_ index: Int) -> [String] {
        if index < 2 { return controller.session.definition.reels[index].eligible.map(\.text) }
        let time = controller.session.mission?.kind == .time
        let range = time ? controller.session.definition.goal.time : controller.session.definition.goal.count
        let count = min(20, (range.maximum - range.minimum) / range.step + 1)
        return (0..<count).map { ChallengeMission.goalText(kind: time ? .time : .count, value: range.minimum + $0 * range.step) }
    }
}

private struct ChallengeReelStrip: View {
    let finalValue: String
    let options: [String]
    let token: String
    let spinning: Bool
    let duration: Double
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title3) private var rowHeight = 116.0
    @State private var offset = 0.0
    @State private var preparedToken = ""
    var body: some View {
        Group {
            if spinning && !typeSize.isAccessibilitySize {
                let items = [finalValue] + (0..<19).map { options.isEmpty ? "—" : options[$0 % options.count] }
                VStack(spacing: 0) {
                    ForEach(items.indices, id: \.self) { index in
                        Text(items[index]).font(.title3.bold()).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity).frame(height: rowHeight)
                    }
                }.offset(y: offset).frame(height: rowHeight, alignment: .top).clipped()
            } else {
                Text(spinning ? "…" : finalValue).font(.title3.bold()).multilineTextAlignment(.center)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 2).minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: rowHeight)
            }
        }.opacity(spinning && preparedToken != token ? 0 : 1)
        .accessibilityElement(children: .ignore)
        .task(id: token) {
            guard spinning else { offset = 0; return }
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { offset = -19 * rowHeight }
            do {
                try await Task.sleep(for: .milliseconds(30))
                preparedToken = token
                withAnimation(.timingCurve(0.1, 0.8, 0.1, 1, duration: duration)) { offset = 0 }
            } catch {}
        }
    }
}

struct ChallengeSessionControls: View {
    let controller: ChallengeSessionController
    var compact = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 12) {
            if let mission = controller.session.mission, [.active, .ready].contains(controller.session.phase) {
                if compact { Text(mission.text).font(.caption).lineLimit(3) }
                if mission.kind == .time {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let seconds = controller.seconds(at: context.date)
                        Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                            .font(compact ? .title3.monospacedDigit() : .largeTitle.monospacedDigit()).accessibilityIdentifier("challenge.timer")
                    }
                    let buttons = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout())
                    buttons {
                        Button(L10n.text(controller.session.deadline == nil ? "Start Timer" : "Pause Timer"), systemImage: controller.session.deadline == nil ? "play.fill" : "pause.fill", action: controller.toggleTimer)
                            .disabled(controller.session.phase == .ready).accessibilityIdentifier("challenge.timerToggle")
                        Button(L10n.text("Reset"), systemImage: "arrow.counterclockwise", action: controller.resetTimer)
                    }.buttonStyle(.bordered)
                } else {
                    HStack(spacing: 24) {
                        Button(action: { controller.adjust(-1) }) { Image(systemName: "minus.circle.fill").font(.title) }.accessibilityLabel(L10n.text("Decrease Count"))
                        Text("\(controller.session.count) / \(mission.goal)").font(.title.monospacedDigit()).accessibilityIdentifier("challenge.count")
                        Button(action: { controller.adjust(1) }) { Image(systemName: "plus.circle.fill").font(.title) }.accessibilityLabel(L10n.text("Increase Count")).accessibilityIdentifier("challenge.increment")
                    }
                }
                if controller.session.phase == .ready { Text(L10n.text("Goal Reached")).font(.headline).foregroundStyle(.purple) }
                Button(L10n.text("Complete Mission"), systemImage: "checkmark.circle.fill", action: controller.complete)
                    .buttonStyle(.borderedProminent).tint(.purple).disabled(controller.session.phase != .ready)
                    .accessibilityIdentifier("challenge.complete")
                if !compact { Button(L10n.text("Skip Without Points"), action: controller.skip).font(.footnote).accessibilityIdentifier("challenge.skip") }
            }
        }.frame(maxWidth: .infinity)
        .padding(compact || ![.active, .ready].contains(controller.session.phase) ? 0 : 20)
        .background { if !compact && [.active, .ready].contains(controller.session.phase) { RoundedRectangle(cornerRadius: 22).fill(Color(uiColor: .secondarySystemGroupedBackground)) } }
        .disabled(controller.unavailable)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                controller.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .onChange(of: controller.session.phase) { old, new in
            if !compact && old == .active && new == .ready {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: L10n.text("Goal Reached"))
            }
        }
    }
}

struct ChallengeViewerControls: View {
    let controller: ChallengeSessionController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false
    var body: some View {
        Group {
            if expanded {
                VStack(spacing: 12) {
                    Button { expanded = false } label: {
                        HStack {
                            Label(L10n.text("Current Mission"), systemImage: "sparkles").font(.subheadline.bold())
                            Spacer(); Image(systemName: "chevron.up")
                        }
                    }.accessibilityIdentifier("challenge.viewerPanel")
                    ChallengeSessionControls(controller: controller, compact: true)
                }.padding(16).frame(maxWidth: 420)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
            } else {
                ViewThatFits(in: .horizontal) {
                    capsule(actions: true)
                    capsule(actions: false)
                }
            }
        }.tint(.purple)
            .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: expanded)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 12).padding(.top, 24)
            .disabled(controller.unavailable)
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    controller.tick()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
    }
    private func capsule(actions: Bool) -> some View {
        HStack(spacing: 2) {
            Button { expanded = true } label: { Image(systemName: "chevron.down").frame(width: 36, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel(L10n.text("Current Mission")).accessibilityIdentifier("challenge.viewerPanel")
            if let mission = controller.session.mission {
                status(mission).padding(.trailing, 8)
                if actions {
                    if mission.kind == .time {
                        Button(action: controller.toggleTimer) {
                            Image(systemName: controller.session.deadline == nil ? "play.fill" : "pause.fill").frame(width: 36, height: 44).contentShape(Rectangle())
                        }.disabled(controller.session.phase == .ready)
                            .accessibilityLabel(L10n.text(controller.session.deadline == nil ? "Start Timer" : "Pause Timer"))
                            .accessibilityIdentifier("challenge.timerToggle")
                    } else {
                        Button(action: { controller.adjust(1) }) { Image(systemName: "plus").frame(width: 36, height: 44).contentShape(Rectangle()) }
                            .accessibilityLabel(L10n.text("Increase Count")).accessibilityIdentifier("challenge.increment")
                    }
                    Button(action: controller.complete) { Image(systemName: "checkmark.circle.fill").frame(width: 36, height: 44).contentShape(Rectangle()) }
                        .disabled(controller.session.phase != .ready)
                        .accessibilityLabel(L10n.text("Complete Mission")).accessibilityIdentifier("challenge.complete")
                }
            }
        }.font(.subheadline.weight(.semibold)).buttonStyle(.plain)
            .padding(.horizontal, 6).fixedSize(horizontal: true, vertical: false)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.purple.opacity(controller.session.phase == .ready ? 0.6 : 0.15)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("challenge.viewerCapsule")
    }
    @ViewBuilder private func status(_ mission: ChallengeMission) -> some View {
        if mission.kind == .time {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = controller.seconds(at: context.date)
                Text(String(format: "%02d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
                    .accessibilityLabel(L10n.text("Time")).accessibilityIdentifier("challenge.timer")
            }
        } else {
            Text("\(controller.session.count)/\(mission.goal)").monospacedDigit()
                .accessibilityLabel(L10n.text("Count")).accessibilityIdentifier("challenge.count")
        }
    }
}

struct ChallengeEndingCard: View {
    let ending: ChallengeEnding
    private var color: Color {
        switch ending.color { case "green": return .green; case "orange": return .orange; case "pink": return .pink; case "blue": return .blue; default: return .purple }
    }
    var body: some View {
        VStack(spacing: 12) {
            Text(ending.badge).font(.largeTitle)
            Text(ending.title).font(.title2.bold())
            Text(ending.detail).font(.body)
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(24)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(color.opacity(0.5)))
            .accessibilityIdentifier("challenge.ending")
    }
}

private struct ChallengeEndingReveal: View {
    let ending: ChallengeEnding
    let choices: [ChallengeEnding]
    let instant: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false
    @State private var position = 0.0
    @State private var celebration: Date?
    private let winningIndex = 24
    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "trophy.fill").font(.system(size: 46))
                    .foregroundStyle(.purple.gradient)
                    .padding(24).background(.purple.opacity(0.1), in: Circle())
                    .scaleEffect(revealed ? 1 : 0.85)
                Text(L10n.text("Challenge Complete")).font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(L10n.text(revealed ? "Your Final Result" : "Revealing Result"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }.multilineTextAlignment(.center)
            GeometryReader { proxy in
                let width = min(156.0, proxy.size.width * 0.44)
                ZStack(alignment: .leading) {
                    HStack(spacing: 14) {
                        ForEach(0..<(winningIndex + 4), id: \.self) { index in
                            let item = index == winningIndex ? ending : choices[index % choices.count]
                            VStack(spacing: 12) {
                                Text(item.badge).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.5)
                                Text(item.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center).lineLimit(3)
                            }.padding(12).frame(width: width, height: 156)
                                .background(.purple.opacity(index == winningIndex && revealed ? 0.3 : 0.08), in: RoundedRectangle(cornerRadius: 20))
                                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.purple.opacity(0.3)))
                        }
                    }.offset(x: (proxy.size.width - width) / 2 - position * (width + 14))
                    RoundedRectangle(cornerRadius: 22).stroke(.purple, lineWidth: 2.5)
                        .frame(width: width + 8, height: 166).position(x: proxy.size.width / 2, y: 90)
                        .shadow(color: .purple.opacity(revealed ? 0.6 : 0.2), radius: revealed ? 16 : 6)
                }.frame(height: 180).clipped()
            }.frame(height: 180).accessibilityHidden(true)
            if revealed {
                ChallengeEndingCard(ending: ending)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                ProgressView().tint(.purple).accessibilityLabel(L10n.text("Revealing Result"))
            }
        }.padding(.vertical, 20)
        .overlay { if let celebration, !reduceMotion { ChallengeCelebration(start: celebration).allowsHitTesting(false).accessibilityHidden(true) } }
        .task(id: ending.id) {
            if reduceMotion || instant { position = Double(winningIndex); revealed = true; return }
            do {
                try await Task.sleep(for: .milliseconds(80))
                withAnimation(.timingCurve(0.12, 0.75, 0.12, 1, duration: 3.6)) { position = Double(winningIndex) }
                try await Task.sleep(for: .seconds(3.7))
                withAnimation(.spring(response: 0.55, dampingFraction: 0.7)) { revealed = true }
                celebration = .now
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                UIAccessibility.post(notification: .announcement, argument: ending.title)
                try await Task.sleep(for: .seconds(2.2)); celebration = nil
            } catch { }
        }
    }
}

private struct ChallengeCelebration: View {
    let start: Date
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let progress = min(1, context.date.timeIntervalSince(start) / 2.2)
            Canvas { graphics, size in
                for index in 0..<32 {
                    let angle = Double(index) * 2.39996
                    let distance = (0.12 + progress * 0.7) * min(size.width, size.height)
                    let x = size.width / 2 + cos(angle) * distance
                    let y = size.height * 0.45 + sin(angle) * distance + progress * progress * 90
                    let rect = CGRect(x: x, y: y, width: index.isMultiple(of: 3) ? 7 : 4, height: 8)
                    graphics.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(.purple.opacity((1 - progress) * 0.8)))
                }
            }
        }
    }
}

struct ChallengePreviewView: View {
    @Bindable var controller: ChallengeSessionController
    @State private var showingHelp = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ChallengeReelsView(controller: controller)
                if let mission = controller.session.mission { Text(mission.text) }
                ChallengeSessionControls(controller: controller)
                if let ending = controller.session.ending { ChallengeEndingCard(ending: ending) }
                Button(L10n.text("Restart"), action: controller.restart)
                ForEach(controller.session.definition.endings) { ending in
                    DisclosureGroup(ending.title) { ChallengeEndingCard(ending: ending) }
                }
            }.padding()
        }.modifier(ChallengeRevealModifier(controller: controller))
        .navigationTitle(L10n.text("Preview Challenge"))
        .tint(.purple)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu { Button(L10n.text("How to Play")) { showingHelp = true }.accessibilityIdentifier("challenge.help") } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityIdentifier("challenge.menu").accessibilityLabel(L10n.text("Challenge Settings"))
            }
            ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } }
        }
        .sheet(isPresented: $showingHelp) { ChallengeHelpView(game: controller.session.definition) }
        .challengeError($controller.error)
    }
}

/// Only plain text is rendered; JSON help pages never execute markup or scripts.
struct ChallengeHelpView: View {
    let game: ChallengeDefinition
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?
    private var page: ChallengeHelpPage { game.instructionPages.first { $0.id == selected } ?? game.instructionPages[0] }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if game.instructionPages.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(game.instructionPages) { item in
                                Button { selected = item.id } label: {
                                    Text(item.title).font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 10)
                                        .foregroundStyle(page.id == item.id ? Color.white : Color.purple)
                                        .background(page.id == item.id ? Color.purple : Color.purple.opacity(0.08), in: Capsule())
                                }.accessibilityAddTraits(page.id == item.id ? .isSelected : [])
                                    .accessibilityIdentifier("challenge.helpTab.\(item.id)")
                            }
                        }.padding(16)
                    }.scrollIndicators(.hidden)
                    Divider()
                }
                ScrollView {
                    Text(page.body).font(.body).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                        .accessibilityIdentifier("challenge.gameDescription")
                }.id(page.id)
            }.navigationTitle(L10n.text("How to Play")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Done")) { dismiss() } } }
        }.tint(.purple)
    }
}


/// Keep the mission reveal alive when the feed's lazy header scrolls off screen.
private struct ChallengeRevealModifier: ViewModifier {
    let controller: ChallengeSessionController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.task(id: controller.session.mission?.id) {
            guard controller.session.phase == .spinning else { return }
            if reduceMotion || controller.session.spinSpeed == "instant" { controller.reveal(); return }
            let factor = controller.session.spinSpeed == "fast" ? 0.5 : 1.0
            do {
                for (index, delay) in [2.0, 0.8, 0.8].enumerated() {
                    try await Task.sleep(for: .seconds(delay * factor))
                    controller.stopReel(index + 1)
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }
                try await Task.sleep(for: .seconds(0.1 * factor)); controller.reveal()
            } catch { }
        }
    }
}
