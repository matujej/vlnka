import SwiftUI
import AppKit

// MARK: - Hlavní okno

struct ContentView: View {
    @EnvironmentObject var m: RadioModel
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if m.mini { MiniView() } else { FullView() }
        }
        .foregroundStyle(Theme.ink)
        .font(.ui(14))
        .background(Theme.bg.ignoresSafeArea())
        .background(WindowAccessor { w in
            window = w
            w?.titlebarAppearsTransparent = true
            w?.backgroundColor = NSColor(Theme.bg)
        })
        .onChange(of: m.pinned) { _, pinned in window?.level = pinned ? .floating : .normal }
        .sheet(item: $m.sheet) { kind in
            Group {
                switch kind {
                case .search(let slot): SearchSheet(slot: slot)
                case .edit(let slot): EditSheet(slot: slot, station: m.presets[slot])
                }
            }
            .environmentObject(m)
            .font(.ui(14))
            .tint(Theme.olive)
        }
        .tint(Theme.olive)
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { onWindow(v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct FullView: View {
    @EnvironmentObject var m: RadioModel
    var body: some View {
        VStack(spacing: 18) {
            Masthead()
            NowPlayingCard()
            PresetsSection()
            HStack {
                Text("Předvolby zůstávají uložené na tomto Macu.")
                    .font(.ui(12, italic: true))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Ukončit rádio") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.ui(12))
                    .foregroundStyle(Theme.olive)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: 560)
    }
}

/// Čistá hlavička v duchu aplikací Apple: značka vlevo, ovládání okna vpravo.
struct Masthead: View {
    @EnvironmentObject var m: RadioModel
    var body: some View {
        HStack(spacing: 12) {
            StationGlyph(size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("Vlnka").font(.system(size: 22, weight: .bold))
                Text("Rádio do dílny").font(.ui(12)).foregroundStyle(Theme.muted)
            }
            Spacer()
            IconButton(symbol: m.pinned ? "pin.fill" : "pin", on: m.pinned,
                       help: "Držet okno vždy navrchu (⇧⌘T)") { m.pinned.toggle() }
            IconButton(symbol: "arrow.down.right.and.arrow.up.left",
                       help: "Malé okno (⇧⌘M)") { m.mini = true }
        }
        .padding(.top, 10)
    }
}

// MARK: - Malé okno

struct MiniView: View {
    @EnvironmentObject var m: RadioModel
    var body: some View {
        HStack(spacing: 12) {
            StationGlyph(size: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.current?.name ?? "Zatím ticho").font(.ui(15, bold: true))
                Text(m.trackLine.isEmpty ? "Vyberte stanici" : m.trackLine)
                    .font(.ui(13, italic: true))
                    .foregroundStyle(m.state == .error ? .red : Theme.ink)
                Text(m.current?.subtitle ?? " ")
                    .font(.ui(11))
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            IconButton(symbol: "backward.fill", help: "Předchozí předvolba") { m.step(-1) }
            IconButton(symbol: m.isActive ? "pause.fill" : "play.fill", on: true,
                       help: m.isActive ? "Pozastavit" : "Přehrát") { m.togglePlayPause() }
            IconButton(symbol: "forward.fill", help: "Další předvolba") { m.step(1) }
            Circle().fill(m.state.color).frame(width: 6, height: 6).help(m.state.label)
                .padding(.horizontal, 4)
            IconButton(symbol: m.pinned ? "pin.fill" : "pin", on: m.pinned,
                       help: "Držet okno vždy navrchu") { m.pinned.toggle() }
            IconButton(symbol: "arrow.up.left.and.arrow.down.right",
                       help: "Velké okno") { m.mini = false }
        }
        .padding(14)
        .card()
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .frame(width: 500)
    }
}

// MARK: - Aplikace

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct VlnkaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = RadioModel()

    var body: some Scene {
        Window("Vlnka", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Přehrávání") {
                Button("Přehrát / Pozastavit") { model.togglePlayPause() }
                    .keyboardShortcut("p")
                Button("Zastavit") { model.stop() }
                    .keyboardShortcut(".")
                Button("Další předvolba") { model.step(1) }
                    .keyboardShortcut(.rightArrow)
                Button("Předchozí předvolba") { model.step(-1) }
                    .keyboardShortcut(.leftArrow)
                Divider()
                ForEach(0..<RadioModel.slotCount, id: \.self) { i in
                    Button(model.presets[i]?.name ?? "Předvolba \(i + 1)") { model.playSlot(i) }
                        .keyboardShortcut(KeyEquivalent(Character("\((i + 1) % 10)")))
                        .disabled(model.presets[i] == nil)
                }
                Divider()
                Button(model.mini ? "Plné okno" : "Minimalistické okno") { model.mini.toggle() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button(model.pinned ? "Nedržet navrchu" : "Držet vždy navrchu") { model.pinned.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
        }
    }
}
