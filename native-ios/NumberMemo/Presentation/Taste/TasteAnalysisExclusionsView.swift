import SwiftUI

struct TasteAnalysisExclusionsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var mode: TasteMode
    @State private var input = ""
    @State private var selectedSource = ""
    private var source: String { mode == .comics ? "https://hitomi.la" : (env.booru.servers.first { $0.canonicalAddress == selectedSource } ?? env.booru.selectedServer ?? env.booru.servers.first)?.canonicalAddress ?? "" }
    init(mode: TasteMode, source: String = "") { _mode = State(initialValue: mode); _selectedSource = State(initialValue: source) }
    private var tags: [String] { env.taste.control.analysisExcluded(mode, source: source).sorted() }
    var body: some View {
        Form {
            Section {
                Picker(L10n.text("Mode"), selection: $mode) {
                    Text(L10n.text("Images")).tag(TasteMode.booru)
                    Text(L10n.text("Comics")).tag(TasteMode.comics)
                }.pickerStyle(.segmented).accessibilityIdentifier("taste.exclusions.mode")
            }
            if mode == .booru {
                Picker(L10n.text("Server"), selection: Binding(get: { source }, set: { selectedSource = $0 })) {
                    ForEach(env.booru.servers) { Text($0.displayName).tag($0.canonicalAddress) }
                }
            }
            Section {
                HStack {
                    TextField(L10n.text("Tag to exclude"), text: $input).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done).onSubmit(add).accessibilityIdentifier("taste.exclusions.input")
                    Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2).frame(width: 44, height: 44) }
                        .disabled(TasteControl.normalizeExclusion(input).isEmpty).accessibilityLabel(L10n.text("Add tag"))
                        .accessibilityIdentifier("taste.exclusions.add")
                }
                ForEach(tags, id: \.self) { tag in
                    HStack {
                        Text(tag).textSelection(.enabled)
                        Spacer()
                        Button { remove(tag) } label: { Image(systemName: "minus.circle").frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel(L10n.text("Remove") + " " + tag)
                    }
                }.onDelete { offsets in let removed = offsets.map { tags[$0] }; env.taste.change { $0.setAnalysisExcluded(Set(tags).subtracting(removed), mode: mode, source: source) } }
            } footer: {
                Text(L10n.text("Excluded tags are removed from taste evidence immediately. Your current works stay in place; refresh to find new recommendations. Original tags and search filters stay available."))
            }.disabled(source.isEmpty)
        }.navigationTitle(L10n.text("Analysis excluded tags"))
            .navigationBarTitleDisplayMode(.inline)
    }
    private func add() {
        let value = TasteControl.normalizeExclusion(input)
        guard !source.isEmpty, !value.isEmpty else { return }
        env.taste.change { $0.setAnalysisExcluded(Set(tags).union([value]), mode: mode, source: source) }; input = ""
    }
    private func remove(_ tag: String) { env.taste.change { $0.setAnalysisExcluded(Set(tags).subtracting([tag]), mode: mode, source: source) } }
}
