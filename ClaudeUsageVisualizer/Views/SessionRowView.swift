import SwiftUI

struct SessionRowView: View {
    let session: SessionInfo

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Running indicator
            Circle()
                .fill(session.isRunning ? Color.green : Color.secondary.opacity(0.25))
                .frame(width: 6, height: 6)

            // Context + time
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(contextSubtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 4)

            // Model badge
            Text(session.dominantModel.shortName)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(session.dominantModel.accentColor.opacity(0.15)))
                .foregroundStyle(session.dominantModel.accentColor)

            // Usage
            VStack(alignment: .trailing, spacing: 1) {
                Text(TokenFormatter.tokens(session.tokensInCurrentBlock))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                Text(TokenFormatter.usd(session.costInCurrentBlock))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 3)
    }

    private var contextSubtitle: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = session.cwd.hasPrefix(home)
            ? "~" + session.cwd.dropFirst(home.count)
            : session.cwd
        if let last = session.lastEventAt {
            let mins = Int(Date().timeIntervalSince(last) / 60)
            let timeStr = mins < 1 ? "just now" : "\(mins)m ago"
            return "\(path) · \(timeStr)"
        }
        return path
    }
}
