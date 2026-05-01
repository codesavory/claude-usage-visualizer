import SwiftUI

struct ApplyConfirmSheet: View {
    let patch: SettingsPatch
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2")
                    .imageScale(.large)
                Text(patch.title)
                    .font(.headline)
            }

            Text(patch.description)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Will write to ~/.claude/settings.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(patch.keyPath)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                    Text("=")
                        .foregroundStyle(.secondary)
                    Text(patch.newValueJSON)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tint)
                }
                if let prev = patch.previousValueJSON {
                    HStack(spacing: 4) {
                        Text("previously:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(prev)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Apply", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
            }
        }
        .padding(18)
        .frame(width: 360)
    }
}
