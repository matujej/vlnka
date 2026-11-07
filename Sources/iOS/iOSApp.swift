// Vlnka pro iPhone
import SwiftUI
import AVKit

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = UIColor(Theme.muted)
        v.activeTintColor = UIColor(Theme.olive)
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct PhoneView: View {
    @EnvironmentObject var m: RadioModel

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack(spacing: 12) {
                    StationGlyph(size: 40)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Vlnka").font(.system(size: 26, weight: .bold))
                        Text("Rádio do dílny").font(.ui(13)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.top, 8)
                NowPlayingCard()
                PresetsSection()
                Text("Předvolby zůstávají uložené v tomto iPhonu.")
                    .font(.ui(12))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .foregroundStyle(Theme.ink)
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.olive)
        .sheet(item: $m.sheet) { kind in
            NavigationStack {
                Group {
                    switch kind {
                    case .search(let slot): SearchSheet(slot: slot)
                    case .edit(let slot): EditSheet(slot: slot, station: m.presets[slot])
                    }
                }
            }
            .environmentObject(m)
            .tint(Theme.olive)
            .presentationDragIndicator(.visible)
        }
    }
}

@main
struct VlnkaPhoneApp: App {
    @StateObject private var model = RadioModel()
    var body: some Scene {
        WindowGroup {
            PhoneView().environmentObject(model)
        }
    }
}
