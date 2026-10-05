import SwiftUI

struct HitomiDefaultTagsSettings: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        @Bindable var env = env
        Section {
            NavigationLink {
                Form {
                    Section(L10n.text("Default Tags")) {
                        TextField("tag:scenery", text: $env.defaultTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("hitomi.defaultTags")
                    }
                    Section(L10n.text("Default Excluded Tags")) {
                        TextField("tag:spoilers", text: $env.defaultExcludedTags, axis: .vertical)
                            .lineLimit(3...6).accessibilityIdentifier("hitomi.defaultExcludedTags")
                    }
                    Section {
                        Text(L10n.text("Applied to every native Hitomi search, including artist pages. Separate tags with spaces; use underscores within a tag. Excluded tags are automatically prefixed with a minus sign."))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .navigationTitle(L10n.text("Default Search Tags")).navigationBarTitleDisplayMode(.inline)
            } label: { Label(L10n.text("Default Search Tags"), systemImage: "line.3.horizontal.decrease") }
                .accessibilityIdentifier("hitomi.defaultTagsSettings")
        } header: { Text(L10n.text("Search")) }
    }
}
