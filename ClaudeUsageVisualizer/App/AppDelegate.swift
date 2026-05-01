import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!

    let usageViewModel = UsageViewModel()
    let settingsViewModel = SettingsViewModel()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureStatusButton(state: .offline, title: nil)
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self

        popover = NSPopover()
        popover.contentSize = NSSize(width: Theme.popoverWidth, height: Theme.popoverHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(apply: usageViewModel.apply)
                .environmentObject(usageViewModel)
                .environmentObject(settingsViewModel)
        )

        // Reflect live state into the menu bar (icon-only, no text)
        usageViewModel.$statusIcon
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.configureStatusButton(state: state, title: nil)
            }
            .store(in: &cancellables)

        Task {
            await usageViewModel.start(settings: settingsViewModel)
        }
    }

    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func configureStatusButton(state: StatusIconState, title: String?) {
        guard let button = statusItem.button else { return }
        let (symbol, tint) = symbolAndTint(for: state)
        let config = NSImage.SymbolConfiguration(paletteColors: [tint])
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Claude Usage")?
            .withSymbolConfiguration(config) {
            button.image = image
        }
        button.imagePosition = title == nil ? .imageOnly : .imageLeading
        if let title {
            button.title = " \(title)"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else {
            button.title = ""
        }
    }

    private func symbolAndTint(for state: StatusIconState) -> (String, NSColor) {
        switch state {
        case .chill:    return ("terminal.fill", .systemGreen)
        case .warm:     return ("terminal.fill", .systemYellow)
        case .hot:      return ("terminal.fill", .systemOrange)
        case .critical: return ("terminal.fill", .systemRed)
        case .offline:  return ("terminal",      .tertiaryLabelColor)
        }
    }

    private func titleFor(state: StatusIconState, snapshot: UsageSnapshot, liveUsage: OAuthUsageSnapshot?) -> String? {
        // Use live utilization % when available (matches /usage exactly)
        let livePct: Int? = {
            guard let live = liveUsage, live.status == .live || live.status == .rateLimited else { return nil }
            return Int(live.fiveHour.utilization.rounded())
        }()

        switch state {
        case .offline: return nil
        case .chill:
            if let pct = livePct { return pct > 0 ? "\(pct)%" : nil }
            if let block = snapshot.currentBlock, block.messageCount > 0 {
                let tier = settingsViewModel.tier
                let pct = Int(Double(block.messageCount) / Double(max(tier.messagesPerBlock, 1)) * 100)
                return "\(pct)%"
            }
            return nil
        case .warm:
            if let pct = livePct { return "\(pct)%" }
            if let block = snapshot.currentBlock {
                let tier = settingsViewModel.tier
                let pct = Int(Double(block.messageCount) / Double(max(tier.messagesPerBlock, 1)) * 100)
                return "\(pct)%"
            }
            return nil
        case .hot:
            if let pct = livePct { return "\(pct)%" }
            return TokenFormatter.tokensPerMinute(snapshot.burn.tokensPerMinute)
        case .critical:
            // Show time-to-reset from live data; fall back to local block
            if let live = liveUsage, live.status == .live || live.status == .rateLimited {
                let remaining = max(0, live.fiveHour.resetsAt.timeIntervalSince(Date()))
                if remaining > 0 { return DurationFormatter.short(remaining) + " left" }
            }
            if let block = snapshot.currentBlock {
                let remaining = block.timeRemaining(now: snapshot.generatedAt)
                return DurationFormatter.short(remaining) + " left"
            }
            return nil
        }
    }
}
