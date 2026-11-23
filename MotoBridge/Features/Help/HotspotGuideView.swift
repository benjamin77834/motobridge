import SwiftUI

/// Guía "Maximizar compatibilidad (hotspot)". Funciona sin red ni riders conectados.
struct HotspotGuideView: View {
    var body: some View {
        List {
            Section { Text(HotspotGuideContent.intro) }
            ForEach(HotspotGuideContent.sections) { section in
                Section(section.title) {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { _, step in
                        Text(step)
                            .accessibilityLabel(step)
                    }
                }
            }
        }
        .navigationTitle(HotspotGuideContent.entryTitle)
        .navigationBarTitleDisplayMode(.inline)
    }
}
