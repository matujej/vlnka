// Vlnka – lehké internetové rádio (sdílené jádro pro macOS a iOS)
import SwiftUI
import AVFoundation
import MediaPlayer
import Network
#if os(macOS)
import AppKit
typealias PColor = NSColor
#else
import UIKit
typealias PColor = UIColor
#endif

// MARK: - Model

struct Station: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var country: String
    var codec: String
    var bitrate: Int
    var url: String

    var subtitle: String {
        var parts: [String] = []
        if !country.isEmpty { parts.append(country) }
        if !codec.isEmpty { parts.append(codec.uppercased()) }
        if bitrate > 0 { parts.append("\(bitrate) kb/s") }
        return parts.isEmpty ? "Vlastní stream" : parts.joined(separator: " · ")
    }
}

enum DefaultStations {
    static let all: [Station?] = [
        Station(name: "BBC Radio 6 Music", country: "Velká Británie", codec: "AAC", bitrate: 96,
                url: "https://as-hls-ww-live.akamaized.net/pool_81827798/live/ww/bbc_6music/bbc_6music.isml/bbc_6music-audio%3d96000.norewind.m3u8"),
        Station(name: "FM4", country: "Rakousko", codec: "MP3", bitrate: 192,
                url: "https://orf-live.ors-shoutcast.at/fm4-q2a"),
        Station(name: "Lounge Radio", country: "Švýcarsko", codec: "MP3", bitrate: 128,
                url: "https://fr1.streamhosting.ch/lounge128.mp3"),
        Station(name: "Radio Paradise", country: "USA", codec: "AAC", bitrate: 128,
                url: "https://stream.radioparadise.com/aac-128"),
        Station(name: "FIP", country: "Francie", codec: "AAC", bitrate: 192,
                url: "https://icecast.radiofrance.fr/fip-hifi.aac"),
        Station(name: "FIP Groove", country: "Francie", codec: "AAC", bitrate: 192,
                url: "https://icecast.radiofrance.fr/fipgroove-hifi.aac"),
        Station(name: "KEXP 90.3 Seattle", country: "USA", codec: "AAC", bitrate: 160,
                url: "https://kexp.streamguys1.com/kexp160.aac"),
        Station(name: "ČRo Radio Wave", country: "Česko", codec: "MP3", bitrate: 128,
                url: "https://rozhlas.stream/wave_mp3_128.mp3"),
        Station(name: "FluxFM", country: "Německo", codec: "MP3", bitrate: 320,
                url: "https://streams.fluxfm.de/live/mp3-320/audio/"),
        nil,
    ]
}

/// Epizoda z archivu FM4 (ORF ji nabízí 7 dní po odvysílání).
struct Episode: Identifiable, Hashable {
    var id: String { url }
    let show: String
    let start: Date
    let duration: Double
    let url: String

    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "EEEEEE d. M."
        return f.string(from: start)
    }
    var lengthText: String {
        let m = Int((duration / 60).rounded())
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }
}

enum FM4Archive {
    /// Pořady nabízené v archivu (klíč pořadu v audioapi.orf.at).
    static let shows = ["4DD", "4GP"]

    static func isFM4(_ s: Station?) -> Bool { s?.url.contains("orf-live.ors-shoutcast.at/fm4") == true }

    private struct Day: Decodable { let broadcasts: [Broadcast] }
    private struct Broadcast: Decodable {
        let programKey: String; let title: String; let end: Double; let isOnDemand: Bool?; let href: String
    }
    private struct Detail: Decodable { let streams: [Stream] }
    private struct Stream: Decodable { let loopStreamId: String; let start: Double; let end: Double }

    /// Poslední dostupná epizoda každého pořadu.
    static func latest() async throws -> [Episode] {
        let url = URL(string: "https://audioapi.orf.at/fm4/api/json/current/broadcasts")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let days = try JSONDecoder().decode([Day].self, from: data)
        let now = Date().timeIntervalSince1970 * 1000
        let all = days.flatMap(\.broadcasts).filter { $0.isOnDemand == true && $0.end < now }
        var out: [Episode] = []
        for key in shows {
            guard let b = all.filter({ $0.programKey == key }).max(by: { $0.end < $1.end }),
                  let href = URL(string: b.href) else { continue }
            let (d, _) = try await URLSession.shared.data(from: href)
            guard let st = try JSONDecoder().decode(Detail.self, from: d).streams.first,
                  let id = st.loopStreamId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { continue }
            out.append(Episode(show: b.title.trimmingCharacters(in: .whitespaces),
                               start: Date(timeIntervalSince1970: st.start / 1000),
                               duration: (st.end - st.start) / 1000,
                               url: "https://loopstream01.apa.at/?channel=fm4&shoutcast=0&id=\(id)"))
        }
        return out
    }
}

enum PlayState { case stopped, loading, playing, paused, error, reconnecting }

enum SheetKind: Identifiable {
    case search(slot: Int?)
    case edit(slot: Int)
    var id: String {
        switch self {
        case .search(let s): return "search-\(s ?? -1)"
        case .edit(let s): return "edit-\(s)"
        }
    }
}

final class RadioModel: NSObject, ObservableObject, AVPlayerItemMetadataOutputPushDelegate {
    /// Prvních 10 míst je vždy vidět (zkratky ⌘1…⌘0); další předvolby přibývají bez omezení.
    static let baseSlots = 10

    @Published var presets: [Station?] { didSet { savePresets() } }
    @Published private(set) var current: Station?
    @Published private(set) var state: PlayState = .stopped
    @Published private(set) var nowPlaying = ""
    @Published var volume: Double {
        didSet {
            #if os(macOS)
            player.volume = Float(volume)
            #endif
            UserDefaults.standard.set(volume, forKey: "volume") }
    }
    @Published var pinned = false
    @Published var mini = false
    @Published var sheet: SheetKind?

    @Published private(set) var episode: Episode?
    @Published private(set) var position: Double = 0
    @Published private(set) var archive: [Episode] = []
    @Published private(set) var archiveState: ArchiveLoad = .idle
    enum ArchiveLoad { case idle, loading, loaded, failed }
    private var archiveLoadedAt = Date.distantPast
    private var resumeAt: Double = 0

    private let player = AVPlayer()
    private var statusObs: NSKeyValueObservation?
    private var itemObs: NSKeyValueObservation?
    private var manualStop = true

    // Automatické obnovení spojení: dokud uživatel chce poslouchat, Vlnka se sama
    // znovu napojí po výpadku internetu, zaseknutí streamu nebo jeho ukončení serverem.
    @Published private(set) var online = true
    private var wantsPlaying = false
    private var isReconnecting = false
    private var notPlayingSince: Date?
    private var lastAttempt = Date.distantPast
    private var retryCount = 0
    private var watchdog: Timer?
    private let pathMonitor = NWPathMonitor()

    override init() {
        if let data = UserDefaults.standard.data(forKey: "presets.v1"),
           let saved = try? JSONDecoder().decode([Station?].self, from: data) {
            var p = saved
            if p.count < Self.baseSlots { p += Array(repeating: nil, count: Self.baseSlots - p.count) }
            presets = p
        } else {
            presets = DefaultStations.all
        }
        let v = UserDefaults.standard.object(forKey: "volume") as? Double ?? 0.7
        volume = v
        super.init()
        #if os(macOS)
        player.volume = Float(v)
        #endif
        player.automaticallyWaitsToMinimizeStalling = true
        statusObs = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.syncState() }
        }
        setupRemoteCommands()
        setupAutoReconnect()
        player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] t in
            guard let self, self.episode != nil, t.seconds.isFinite, self.resumeAt == 0 else { return }
            self.position = t.seconds
        }
        #if os(iOS)
        player.volume = 1
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, policy: .longFormAudio)
        NotificationCenter.default.addObserver(self, selector: #selector(audioInterrupted(_:)),
                                               name: AVAudioSession.interruptionNotification, object: nil)
        #endif
    }

    #if os(iOS)
    @objc private func audioInterrupted(_ n: Notification) {
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        DispatchQueue.main.async {
            if type == .began {
                if self.isActive { self.wantsPlaying = false; self.state = .paused; self.updateNowPlayingInfo() }
            } else if let o = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                      AVAudioSession.InterruptionOptions(rawValue: o).contains(.shouldResume),
                      let c = self.current {
                self.play(c) // po hovoru se napojí znovu na živé vysílání
            }
        }
    }
    #endif

    var isActive: Bool { state == .playing || state == .loading || state == .reconnecting }
    var savedCount: Int { presets.compactMap { $0 }.count }
    var trackLine: String {
        if state == .reconnecting { return online ? "Obnovuji spojení…" : "Čekám na připojení k internetu…" }
        if state == .error { return "Stream se nepodařilo načíst" }
        if state == .stopped { return "" }
        if let e = episode { return "\(e.show) · \(e.dateText)" }
        if !nowPlaying.isEmpty { return nowPlaying }
        return current == nil ? "" : "Živé vysílání"
    }

    // MARK: Playback

    func play(_ station: Station) {
        retryCount = 0
        isReconnecting = false
        episode = nil
        position = 0
        resumeAt = 0
        start(station)
        loadArchiveIfNeeded()
    }

    /// Pustí epizodu z archivu; stanice zůstává vybraná (FM4).
    func playEpisode(_ e: Episode) {
        guard let c = current else { return }
        retryCount = 0
        isReconnecting = false
        episode = e
        position = 0
        resumeAt = 0
        start(c)
    }

    func seek(to seconds: Double) {
        guard episode != nil else { return }
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1))
        updateNowPlayingInfo()
    }

    func loadArchiveIfNeeded(force: Bool = false) {
        guard FM4Archive.isFM4(current), archiveState != .loading else { return }
        guard force || archiveState != .loaded || Date().timeIntervalSince(archiveLoadedAt) > 3600 else { return }
        archiveState = .loading
        Task { @MainActor in
            do {
                self.archive = try await FM4Archive.latest()
                self.archiveLoadedAt = Date()
                self.archiveState = .loaded
            } catch {
                self.archiveState = .failed
            }
        }
    }

    private func start(_ station: Station, keepMeta: Bool = false) {
        guard let url = URL(string: episode?.url ?? station.url) else { return }
        wantsPlaying = true
        lastAttempt = Date()
        notPlayingSince = Date()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        manualStop = false
        current = station
        if !keepMeta { nowPlaying = "" }
        let item = AVPlayerItem(url: url)
        let meta = AVPlayerItemMetadataOutput(identifiers: nil)
        meta.setDelegate(self, queue: .main)
        item.add(meta)
        itemObs = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if item.status == .readyToPlay, self.resumeAt > 0 {
                    // po výpadku pokračovat v epizodě tam, kde přestala
                    self.player.seek(to: CMTime(seconds: self.resumeAt, preferredTimescale: 1))
                    self.resumeAt = 0
                }
                if item.status == .failed { self.syncState() }
            }
        }
        player.replaceCurrentItem(with: item)
        state = isReconnecting ? .reconnecting : .loading
        player.play()
        updateNowPlayingInfo()
    }

    func togglePlayPause() {
        if isActive {
            wantsPlaying = false
            isReconnecting = false
            player.pause()
            state = .paused
            updateNowPlayingInfo()
        } else if episode != nil, player.currentItem != nil, player.currentItem?.status != .failed {
            // epizoda pokračuje tam, kde se pozastavila
            wantsPlaying = true
            notPlayingSince = Date()
            player.play()
        } else if let e = episode {
            retryCount = 0
            resumeAt = position
            playEpisodeKeepingPosition(e)
        } else if let c = current ?? presets.compactMap({ $0 }).first {
            play(c) // u živého vysílání se po pauze napojíme znovu na aktuální čas
        }
    }

    private func playEpisodeKeepingPosition(_ e: Episode) {
        guard let c = current else { return }
        isReconnecting = false
        episode = e
        start(c)
    }

    func stop() {
        episode = nil
        position = 0
        resumeAt = 0
        manualStop = true
        wantsPlaying = false
        isReconnecting = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObs = nil
        nowPlaying = ""
        state = .stopped
        updateNowPlayingInfo()
    }

    func step(_ delta: Int) {
        let saved = presets.compactMap { $0 }
        guard !saved.isEmpty else { return }
        let idx = saved.firstIndex(where: { $0.id == current?.id }) ?? (delta > 0 ? -1 : 0)
        let next = (idx + delta + saved.count) % saved.count
        play(saved[next])
    }

    func playSlot(_ i: Int) {
        guard i < presets.count, let s = presets[i] else { return }
        play(s)
    }

    private func syncState() {
        guard player.currentItem != nil, !manualStop else { state = .stopped; return }
        let playing = player.timeControlStatus == .playing && player.currentItem?.status != .failed
        if playing {
            notPlayingSince = nil
            retryCount = 0
            isReconnecting = false
            state = .playing
        } else {
            if notPlayingSince == nil { notPlayingSince = Date() }
            if wantsPlaying {
                // chce poslouchat, ale nehraje: buď se načítá, nebo obnovujeme spojení
                state = (isReconnecting || player.currentItem?.status == .failed || !online) ? .reconnecting : .loading
            } else {
                state = player.currentItem?.status == .failed ? .error : .paused
            }
        }
        updateNowPlayingInfo()
    }

    // MARK: Automatické obnovení spojení

    private func setupAutoReconnect() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                if !self.online, self.wantsPlaying { self.isReconnecting = true; self.syncState() }
                if self.online, !wasOnline, self.wantsPlaying {
                    self.retryCount = 0
                    self.reconnect() // internet je zpět – hned se napojit
                }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "vlnka.net"))

        let nc = NotificationCenter.default
        for name in [AVPlayerItem.playbackStalledNotification,
                     AVPlayerItem.failedToPlayToEndTimeNotification,
                     AVPlayerItem.didPlayToEndTimeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem, self.wantsPlaying else { return }
                if note.name == AVPlayerItem.didPlayToEndTimeNotification, let e = self.episode,
                   self.position >= e.duration - 30 {
                    self.stop() // epizoda dohrála
                    return
                }
                // krátké zaseknutí AVPlayer často zvládne sám (řeší hlídač po 8 s);
                // chyba nebo ukončení streamu serverem = obnovit hned
                if note.name != AVPlayerItem.playbackStalledNotification { self.isReconnecting = true }
                self.syncState()
            }
        }

        // Hlídač: když má hrát a 8 s nehraje, zkusí to znovu (2, 4, 8 … max. 30 s mezi pokusy).
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
    }

    private func checkHealth() {
        guard wantsPlaying, current != nil, online else { return }
        guard let since = notPlayingSince else { return }
        let stuck = Date().timeIntervalSince(since) > 8 || player.currentItem?.status == .failed || isReconnecting
        let wait = min(30, 2 * pow(2, Double(retryCount)))
        if stuck, Date().timeIntervalSince(lastAttempt) >= wait { reconnect() }
    }

    private func reconnect() {
        guard let c = current, wantsPlaying else { return }
        if episode != nil, retryCount >= 4 {
            // epizoda mohla z archivu zmizet (po 7 dnech): netočit se donekonečna
            wantsPlaying = false
            isReconnecting = false
            player.pause()
            archiveState = .idle
            loadArchiveIfNeeded()
            state = .error
            updateNowPlayingInfo()
            return
        }
        retryCount += 1
        isReconnecting = true
        if episode != nil { resumeAt = position }
        start(c, keepMeta: true)
    }

    // MARK: Presets

    func save(_ station: Station, to slot: Int) {
        var s = station
        s.id = UUID()
        setPreset(s, at: slot)
    }

    func remove(_ slot: Int) {
        guard slot < presets.count else { return }
        // prvních 10 míst zůstává (jen se uvolní), další předvolby se odeberou celé
        if slot >= Self.baseSlots { presets.remove(at: slot) } else { presets[slot] = nil }
    }

    /// Uloží stanici na místo; index za koncem seznamu = nová předvolba navíc.
    func setPreset(_ station: Station, at slot: Int) {
        guard slot >= 0 else { return }
        if slot < presets.count { presets[slot] = station } else { presets.append(station) }
    }

    /// Kam se uloží nová stanice: první volné místo, jinak nové místo na konci.
    var nextFreeSlot: Int { presets.firstIndex(where: { $0 == nil }) ?? presets.count }

    /// Počet zobrazených dlaždic: když nic není volné, přidá se jedna prázdná „Přidat předvolbu“.
    var displayedSlots: Int { presets.contains(where: { $0 == nil }) ? presets.count : presets.count + 1 }

    func move(_ slot: Int, by delta: Int) {
        let target = slot + delta
        guard target >= 0, target < presets.count else { return }
        presets.swapAt(slot, target)
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: "presets.v1")
        }
    }

    // MARK: Metadata (název skladby ze streamu)

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        guard episode == nil else { return }
        let items = groups.flatMap(\.items)
        Task { @MainActor in
            for item in items {
                if let s = try? await item.load(.stringValue) {
                    let t = cleanTrackTitle(s)
                    let low = t.lowercased()
                    let junk = ["preroll", "advert", "livestream", "commercial", "http"]
                    let isJunk = t.count < 3 || junk.contains { low.contains($0) }
                        || low == self.current?.name.lowercased()
                    if !isJunk {
                        self.nowPlaying = t
                        self.updateNowPlayingInfo()
                        return
                    }
                }
            }
        }
    }

    // MARK: Ovládací centrum / multimediální klávesy

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        c.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !self.isActive { self.togglePlayPause() }
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.isActive { self.togglePlayPause() }
            return .success
        }
        c.stopCommand.addTarget { [weak self] _ in self?.stop(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.step(1); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.step(-1); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] ev in
            guard let self, self.episode != nil, let e = ev as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self.seek(to: e.positionTime)
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let c = current, state != .stopped else {
            center.nowPlayingInfo = nil
            #if os(macOS)
            center.playbackState = .stopped
            #endif
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: episode?.show ?? (nowPlaying.isEmpty ? c.name : nowPlaying),
            MPMediaItemPropertyArtist: c.name,
            MPNowPlayingInfoPropertyIsLiveStream: episode == nil,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let e = episode {
            info[MPMediaItemPropertyPlaybackDuration] = e.duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        }
        center.nowPlayingInfo = info
        MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = episode != nil
        #if os(macOS)
        center.playbackState = isActive ? .playing : .paused
        #endif
    }
}

/// Název ze streamu bez osamělého oddělovače: „Duchovní hudba -“ → „Duchovní hudba“.
/// Pomlčka bez mezery (např. kapela „-M-“) zůstává, je součástí jména.
func cleanTrackTitle(_ raw: String) -> String {
    raw.replacingOccurrences(of: #"^[\s\-–—]*[\-–—]\s+|\s+[\-–—][\s\-–—]*$"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Vzhled
// Estetika Apple (SF Pro, SF Symbols, jasná hierarchie) + olivová zelená z „jedu si dřevo!“.

enum Theme {
    private static func dyn(_ light: PColor, _ dark: PColor) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
        #else
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        #endif
    }
    private static func hex(_ v: UInt32, _ a: Double = 1) -> PColor {
        PColor(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255,
                blue: Double(v & 0xFF) / 255, alpha: a)
    }
    static let bg = dyn(hex(0xF4F3EF), hex(0x1E1E1C))
    static let card = dyn(hex(0xFFFFFF), hex(0x2A2A27))
    static let chip = dyn(hex(0xEBEAE5), hex(0x3A3A36))
    static let stroke = dyn(hex(0x000000, 0.09), hex(0xFFFFFF, 0.09))
    static let ink = dyn(hex(0x12110F), hex(0xEDE8DC))
    static let muted = dyn(hex(0x6E6E73), hex(0x98989D))
    static let olive = dyn(hex(0x5F7B2A), hex(0xA3BA5E))  // značka, text
    static let button = dyn(hex(0x6E8B30), hex(0x8AA545))       // tlačítka s tmavým textem
    static let oliveSoft = dyn(hex(0xE6E8D2), hex(0x323A22))
}

extension Font {
    /// SF Pro. „italic“ se v SF nesází kurzívou – jen odliší řez (medium), barvu řeší volající.
    static func ui(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
        .system(size: size, weight: bold ? .semibold : (italic ? .medium : .regular))
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
    }
}
extension View { func card() -> some View { modifier(CardStyle()) } }

/// Plné olivové tlačítko s tmavým textem (hlavní akce).
struct OliveButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(14, bold: true))
            .foregroundStyle(Color(red: 0.07, green: 0.067, blue: 0.06))
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.button.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(Rectangle())
    }
}

/// Tenké obrysové tlačítko (vedlejší akce).
struct OutlineButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(14))
            .foregroundStyle(Theme.olive)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(configuration.isPressed ? Theme.oliveSoft : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.olive.opacity(0.55)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}

struct DottedRule: View {
    var body: some View {
        Line().stroke(Theme.olive.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .frame(height: 1)
    }
    struct Line: Shape {
        func path(in r: CGRect) -> Path { Path { $0.move(to: .init(x: 0, y: 0.5)); $0.addLine(to: .init(x: r.width, y: 0.5)) } }
    }
}

struct StationGlyph: View {
    var size: CGFloat
    var body: some View {
        Circle()
            .fill(Theme.oliveSoft)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: size * 0.36, weight: .regular))
                .foregroundStyle(Theme.olive))
    }
}

struct IconButton: View {
    let symbol: String
    var on = false
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(on ? Theme.olive : Theme.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension PlayState {
    var color: Color {
        switch self {
        case .playing: return Theme.button
        case .loading, .reconnecting: return .orange
        case .error: return .red
        case .paused, .stopped: return Theme.muted.opacity(0.5)
        }
    }
    var label: String {
        switch self {
        case .playing: return "Živě"
        case .loading: return "Načítá se…"
        case .reconnecting: return "Obnovuji spojení"
        case .paused: return "Pozastaveno"
        case .stopped: return "Zastaveno"
        case .error: return "Stream nejde"
        }
    }
}

struct StatusLine: View {
    let state: PlayState
    var playingLabel: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(state.color).frame(width: 6, height: 6)
            Text(state == .playing ? (playingLabel ?? state.label) : state.label).font(.ui(13, italic: true)).foregroundStyle(Theme.muted)
        }
    }
}

struct NowPlayingCard: View {
    @EnvironmentObject var m: RadioModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Právě hraje").font(.ui(13, bold: true)).foregroundStyle(Theme.olive)
                Spacer()
                StatusLine(state: m.state, playingLabel: m.episode != nil ? "Z archivu" : nil)
            }
            HStack(spacing: 14) {
                StationGlyph(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.current?.name ?? "Zatím ticho")
                        .font(.ui(22, bold: true))
                    if !m.trackLine.isEmpty {
                        Text(m.trackLine)
                            .font(.ui(14))
                            .foregroundStyle(m.state == .error ? .red : Theme.ink)
                            .textSelection(.enabled)
                    }
                    Text(m.current?.subtitle ?? "Vyberte si stanici z předvoleb.")
                        .font(.ui(12))
                        .foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
            }
            HStack(spacing: 10) {
                Button { m.togglePlayPause() } label: {
                    Label(m.isActive ? "Pozastavit" : "Přehrát",
                          systemImage: m.isActive ? "pause.fill" : "play.fill")
                        .frame(width: 118).padding(.vertical, 6)
                }
                .buttonStyle(OliveButton())
                Button { m.stop() } label: {
                    Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 38).padding(.vertical, 7)
                }
                .buttonStyle(OutlineButton())
                .disabled(m.state == .stopped)
                .help("Zastavit (⌘.)")
                #if os(macOS)
                Image(systemName: m.volume < 0.01 ? "speaker.slash" : m.volume < 0.5 ? "speaker.wave.1" : "speaker.wave.2")
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20)
                    .padding(.leading, 8)
                Slider(value: $m.volume, in: 0...1)
                    .tint(Theme.button)
                    .controlSize(.small)
                #else
                Spacer()
                AirPlayButton().frame(width: 38, height: 38) // hlasitost řeší tlačítka telefonu
                #endif
            }
            if FM4Archive.isFM4(m.current) { ArchivePanel() }
        }
        .padding(16)
        .card()
    }
}

/// Rozbalený výběr u FM4: živé vysílání a poslední epizody z archivu.
struct ArchivePanel: View {
    @EnvironmentObject var m: RadioModel
    @State private var scrub: Double?

    private func clock(_ t: Double) -> String {
        let s = Int(max(0, t))
        return String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private func row(_ title: String, _ sub: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: active ? "speaker.wave.2.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.olive)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(14, bold: true)).foregroundStyle(Theme.ink)
                    Text(sub).font(.ui(12)).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Theme.oliveSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.bottom, 4)
            if let e = m.episode {
                VStack(spacing: 2) {
                    Slider(value: Binding(get: { scrub ?? min(m.position, e.duration) }, set: { scrub = $0 }),
                           in: 0...max(e.duration, 1),
                           onEditingChanged: { editing in
                               if !editing, let t = scrub { m.seek(to: t); scrub = nil }
                           })
                        .tint(Theme.button)
                        .controlSize(.small)
                    HStack {
                        Text(clock(scrub ?? m.position))
                        Spacer()
                        Text(clock(e.duration))
                    }
                    .font(.ui(11).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 4)
            }
            row("Živé vysílání", "FM4 právě teď", active: m.episode == nil && m.state != .stopped) {
                if let c = m.current { m.play(c) }
            }
            ForEach(m.archive) { e in
                row(e.show, "\(e.dateText) · \(e.lengthText)", active: m.episode == e) { m.playEpisode(e) }
            }
            switch m.archiveState {
            case .loading where m.archive.isEmpty:
                Text("Načítám archiv…").font(.ui(12)).foregroundStyle(Theme.muted).padding(.horizontal, 10)
            case .failed:
                HStack {
                    Text("Archiv se nepodařilo načíst.").font(.ui(12)).foregroundStyle(Theme.muted)
                    Button("Zkusit znovu") { m.loadArchiveIfNeeded(force: true) }
                        .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Theme.olive)
                }
                .padding(.horizontal, 10)
            default:
                EmptyView()
            }
        }
    }
}

struct PresetsSection: View {
    @EnvironmentObject var m: RadioModel
    private let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    private var grid: some View {
        LazyVGrid(columns: cols, spacing: 10) {
            ForEach(0..<m.displayedSlots, id: \.self) { PresetCell(index: $0) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Předvolby").font(.ui(17, bold: true))
                Spacer()
                Text(m.savedCount == 1 ? "1 uložená" : m.savedCount < 5 ? "\(m.savedCount) uložené" : "\(m.savedCount) uložených")
                    .font(.ui(12, italic: true)).foregroundStyle(Theme.muted)
            }
            #if os(macOS)
            // na Macu se okno nenafukuje: víc než 6 řad se posouvá
            // na výšku displeje: okno nikdy nepřeroste obrazovku (i s rozbaleným archivem)
            let rows = (m.displayedSlots + 1) / 2
            let natural = CGFloat(rows) * 66 - 10
            let chrome: CGFloat = FM4Archive.isFM4(m.current) ? (m.episode != nil ? 640 : 600) : 410
            let screen = NSScreen.main?.visibleFrame.height ?? 900
            let room = max(130, min(5 * 66 + 34, screen - chrome))
            if rows > 6 || natural > room {
                ScrollView { grid.padding(.trailing, 2) }
                    .frame(height: room)
            } else { grid }
            #else
            grid
            #endif
            Button { m.sheet = .search(slot: nil) } label: {
                Label("Vyhledat další stanici", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
            }
            .buttonStyle(OutlineButton())
            .padding(.top, 4)
        }
    }
}

struct PresetCell: View {
    @EnvironmentObject var m: RadioModel
    let index: Int
    @State private var hover = false

    var body: some View {
        let st = index < m.presets.count ? m.presets[index] : nil
        let extra = index >= m.presets.count
        let active = st != nil && st?.id == m.current?.id && m.state != .stopped
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(st?.name ?? (extra ? "Přidat předvolbu" : "Volné místo"))
                    .font(st == nil ? .ui(14, italic: true) : .ui(15, bold: true))
                    .foregroundStyle(st == nil ? Theme.muted : Theme.ink)
                Text(st?.subtitle ?? (extra ? "Další místo pro stanici" : "Klikněte a vyberte stanici"))
                    .font(.ui(12))
                    .foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if st != nil {
                Menu {
                    Button("Přehrát") { m.playSlot(index) }
                    Button("Upravit…") { m.sheet = .edit(slot: index) }
                    Button("Nahradit jinou stanicí…") { m.sheet = .search(slot: index) }
                    Divider()
                    Button("Posunout dříve") { m.move(index, by: -1) }.disabled(index == 0)
                    Button("Posunout později") { m.move(index, by: 1) }.disabled(index >= m.presets.count - 1)
                    Divider()
                    Button("Odebrat", role: .destructive) { m.remove(index) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hover || active ? 1 : 0.35)
            }
        }
        .padding(.vertical, 10)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(active ? Theme.oliveSoft : (hover ? Theme.chip.opacity(0.45) : Theme.card)))
        .overlay(alignment: .leading) {
            if active {
                RoundedRectangle(cornerRadius: 2).fill(Theme.button).frame(width: 3).padding(.vertical, 9)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(active ? Theme.olive.opacity(0.5) : Theme.stroke,
                          style: StrokeStyle(lineWidth: 1, dash: st == nil ? [2, 3] : [])))
        .contentShape(Rectangle())
        .onTapGesture {
            if st != nil { m.playSlot(index) } else { m.sheet = .search(slot: index) }
        }
        .onHover { hover = $0 }
        .help(st == nil ? "Klikněte pro výběr stanice" : "Zkratka ⌘\(index == 9 ? 0 : index + 1)")
    }
}

// MARK: - Vyhledávání stanic (radio-browser.info)

struct RBStation: Decodable {
    let name: String
    let url_resolved: String
    let country: String
    let codec: String
    let bitrate: Int
    let tags: String

    var station: Station {
        Station(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                country: country, codec: codec, bitrate: bitrate, url: url_resolved)
    }
}

struct SearchSheet: View {
    @EnvironmentObject var m: RadioModel
    @Environment(\.dismiss) private var dismiss
    let slot: Int?

    enum Mode: String, CaseIterable { case name = "Název", tag = "Žánr" }
    @State private var query = ""
    @State private var mode: Mode = .tag
    @State private var results: [RBStation] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var savedURL: String?

    private var targetSlot: Int? { slot ?? m.nextFreeSlot }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(slot.map { "Stanice pro \($0 + 1). předvolbu" } ?? "Vyhledat stanici")
                .font(.system(size: 17, weight: .semibold))
            HStack {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                TextField(mode == .tag ? "např. lounge, indie, jazz, chillout…" : "např. Radio Nova, SomaFM…",
                          text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Hledat") { Task { await search() } }
                    .keyboardShortcut(.defaultAction)
            }
            ZStack {
                List(Array(results.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.station.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(r.station.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { m.play(r.station) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .help("Poslechnout")
                        if savedURL == r.url_resolved {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.olive)
                        } else {
                            Button(targetSlot.map { "Uložit na \($0 + 1). místo" } ?? "Plno") {
                                if let t = targetSlot {
                                    m.save(r.station, to: t)
                                    savedURL = r.url_resolved
                                    if slot != nil { dismiss() }
                                }
                            }
                            .disabled(targetSlot == nil)
                            .help(targetSlot == nil ? "Všechny předvolby jsou obsazené – nějakou odeberte." : "")
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
                if loading { ProgressView() }
                else if let e = errorText { Text(e).foregroundStyle(.secondary) }
                else if results.isEmpty { Text("Nic nenalezeno").foregroundStyle(.secondary) }
            }
            .frame(height: 340)
            HStack {
                Button("Vlastní adresa streamu…") {
                    if let t = targetSlot { m.sheet = .edit(slot: t) }
                }
                .disabled(targetSlot == nil)
                Spacer()
                Text("Zdroj: radio-browser.info").font(.system(size: 10)).foregroundStyle(.tertiary)
                Button("Hotovo") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .macWidth(560)
        .task {
            query = "lounge"
            await search()
        }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        loading = true; errorText = nil
        defer { loading = false }
        var c = URLComponents(string: "https://de1.api.radio-browser.info/json/stations/search")!
        c.queryItems = [
            URLQueryItem(name: mode == .tag ? "tag" : "name", value: q),
            URLQueryItem(name: "limit", value: "60"),
            URLQueryItem(name: "hidebroken", value: "true"),
            URLQueryItem(name: "order", value: "clickcount"),
            URLQueryItem(name: "reverse", value: "true"),
        ]
        var req = URLRequest(url: c.url!)
        req.setValue("Vlnka/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            var seen = Set<String>()
            results = try JSONDecoder().decode([RBStation].self, from: data)
                .filter { !$0.url_resolved.isEmpty && seen.insert($0.name.lowercased()).inserted }
        } catch {
            results = []
            errorText = "Vyhledávání se nepovedlo. Zkontrolujte připojení."
        }
    }
}

// MARK: - Úprava předvolby

struct EditSheet: View {
    @EnvironmentObject var m: RadioModel
    @Environment(\.dismiss) private var dismiss
    let slot: Int
    let original: Station?
    @State private var name: String
    @State private var url: String
    @State private var country: String
    @State private var codec: String
    @State private var bitrate: String

    init(slot: Int, station: Station?) {
        self.slot = slot
        self.original = station
        _name = State(initialValue: station?.name ?? "")
        _url = State(initialValue: station?.url ?? "")
        _country = State(initialValue: station?.country ?? "")
        _codec = State(initialValue: station?.codec ?? "")
        _bitrate = State(initialValue: station.map { $0.bitrate > 0 ? "\($0.bitrate)" : "" } ?? "")
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        URL(string: url.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(slot + 1). předvolba").font(.system(size: 17, weight: .semibold))
            Form {
                TextField("Název", text: $name)
                TextField("Adresa streamu", text: $url, prompt: Text("https://…"))
                TextField("Země", text: $country)
                HStack {
                    TextField("Formát", text: $codec, prompt: Text("MP3 / AAC"))
                    TextField("kb/s", text: $bitrate).frame(width: 110)
                }
            }
            HStack {
                Button("Vyzkoušet") { m.play(build()) }.disabled(!valid)
                Spacer()
                Button("Zrušit") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uložit") {
                    m.setPreset(build(), at: slot)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .macWidth(460)
    }

    private func build() -> Station {
        var s = original ?? Station(name: "", country: "", codec: "", bitrate: 0, url: "")
        s.name = name.trimmingCharacters(in: .whitespaces)
        s.url = url.trimmingCharacters(in: .whitespaces)
        s.country = country.trimmingCharacters(in: .whitespaces)
        s.codec = codec.trimmingCharacters(in: .whitespaces)
        s.bitrate = Int(bitrate.trimmingCharacters(in: .whitespaces)) ?? 0
        return s
    }
}


extension View {
    @ViewBuilder func macWidth(_ w: CGFloat) -> some View {
        #if os(macOS)
        frame(width: w)
        #else
        self
        #endif
    }
}
