import SwiftUI

struct SessionListView: View {
    let sessions: [SessionInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("SESSIONS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)
                Spacer()
                Text("\(sessions.filter { $0.isRunning }.count) running · \(sessions.count) total")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)

            if sessions.isEmpty {
                Text("No sessions yet — start a `claude` session to begin tracking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(sessions.prefix(5)) { session in
                    SessionRowView(session: session)
                    if session.id != sessions.prefix(5).last?.id {
                        Divider().opacity(0.35)
                    }
                }
                if sessions.count > 5 {
                    Text("+ \(sessions.count - 5) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
        }
    }
}
