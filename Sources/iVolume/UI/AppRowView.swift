import SwiftUI

struct AppRowView: View {
    let item: AudioAppItem

    @State private var volume: Double
    @State private var isMuted: Bool

    init(item: AudioAppItem) {
        self.item = item
        _volume = State(initialValue: item.volume)
        _isMuted = State(initialValue: item.isMuted)
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed")
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Slider(value: $volume, in: 0...1)
                        .disabled(isMuted)
                        .onChange(of: volume) {
                            commit()
                        }
                    Text("\(Int((isMuted ? 0 : volume) * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
            }

            Button {
                isMuted.toggle()
                commit()
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func commit() {
        VolumeStore.shared.setState(StoredVolumeState(volume: volume, isMuted: isMuted), for: item.bundleID)
        AudioEngineManager.shared.setVolume(volume, isMuted: isMuted, for: item)
    }
}
