import SwiftUI

/// Claude | GPT segmented switch.
struct ProviderSelector: View {
    @Binding var selection: ProviderKind
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ProviderKind.allCases) { kind in
                Button {
                    selection = kind
                } label: {
                    Text(kind.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selection == kind ? kind.accent : .white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if selection == kind {
                                Capsule()
                                    .fill(kind.accent.opacity(0.18))
                                    .matchedGeometryEffect(id: "selected", in: highlight)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.08)))
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: selection)
    }
}
