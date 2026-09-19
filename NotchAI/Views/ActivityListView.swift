import SwiftUI

/// Recent steps: ✓ for finished, → for the one in progress.
struct ActivityListView: View {
    let activities: [TaskActivity]
    let accent: Color
    var limit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(activities.suffix(limit)) { activity in
                HStack(spacing: 6) {
                    Image(systemName: activity.isDone ? "checkmark" : "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(activity.isDone ? .white.opacity(0.4) : accent)
                        .frame(width: 12)
                    Text(activity.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(activity.isDone ? 0.5 : 0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: activities)
    }
}
