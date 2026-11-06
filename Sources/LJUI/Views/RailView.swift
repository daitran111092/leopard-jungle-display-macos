import SwiftUI
import LJCore

/// Right rail (620 px), shared by every page: audio output, Bluetooth devices, system. Mockup `.rail`.
/// Min text size 18 px (the mockup's 15–17 px labels are raised to 18).
struct RailView: View {
    let audio: AudioOutput?
    let bluetooth: [BtDevice]
    let system: SystemStats?
    let motion: RailMotion?
    let t: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            label("Audio output")
            OutputBlock(audio: audio, t: t)
            label("Bluetooth", right: bluetooth.isEmpty ? nil : "\(bluetooth.count) device\(bluetooth.count == 1 ? "" : "s")")
            BluetoothGrid(devices: bluetooth)
            label("System")
            SystemBlock(stats: motion?.readout ?? system,
                        cpuBar: motion?.cpuBar ?? system?.cpuFraction ?? 0,
                        memBar: motion?.memBar ?? system?.memFraction ?? 0)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 30, bottom: 16, trailing: 26))
        .frame(width: Screen.rail, height: Screen.height, alignment: .topLeading)
        .background(
            LinearGradient(stops: [.init(color: Color(hex: 0x07040f, alpha: 0), location: 0),
                                   .init(color: Color(hex: 0x07040f, alpha: 0.55), location: 0.12),
                                   .init(color: Color(hex: 0x07040f, alpha: 0.55), location: 1)],
                           startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .leading) {
            LinearGradient(stops: [.init(color: Palette.pink, location: 0), .init(color: Palette.violet, location: 0.55),
                                   .init(color: Palette.blue, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .frame(width: 3)
        }
    }

    private func label(_ s: String, right: String? = nil) -> some View {
        HStack {
            Text(s.uppercased())
            Spacer()
            if let right { Text(right.uppercased()).foregroundStyle(Palette.pink) }
        }
        .font(.chakra(18, 600))
        .tracking(3)
        .foregroundStyle(Palette.muted)
        .lineLimit(1)
    }
}

// MARK: - Audio output

/// The Audio output block's tinted look (clipped corners, translucent fill, half-alpha border), shared with the
/// Music page's sample-rate badge.
enum OutBlockStyle {
    static let cut: CGFloat = 10
    static let fillAlpha = 0.12
    static let borderAlpha = 0.5
    static let lineWidth: CGFloat = 2
}

extension View {
    /// Tinted clipped-corner block in `color` (the Audio output block's normal state).
    func outBlockStyle(_ color: Color) -> some View {
        let shape = ClippedCorners(cut: OutBlockStyle.cut)
        return background { shape.fill(color.opacity(OutBlockStyle.fillAlpha)) }
            .overlay { shape.strokeBorder(color.opacity(OutBlockStyle.borderAlpha), lineWidth: OutBlockStyle.lineWidth) }
    }
}

private struct OutputBlock: View {
    let audio: AudioOutput?
    let t: TimeInterval

    private var warn: Bool { audio?.isBuiltInSpeaker == true }

    var body: some View {
        let shape = ClippedCorners(cut: OutBlockStyle.cut)
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(warn ? Palette.white : Palette.text)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(audio?.name ?? "No output device")
                    .font(.chakra(28, 700))
                    .foregroundStyle(warn ? Palette.white : Palette.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(subtitle)
                    .font(.chakra(18, 500))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if warn {
                Text("OOPS! LOUD!")
                    .font(.display(20))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Palette.pink)
                    .rotationEffect(.degrees(-3 + sin(t * 9) * 2.5))
                    .scaleEffect(1 + abs(sin(t * 4.5)) * 0.06)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if warn { Stripes(phase: (t * 50).truncatingRemainder(dividingBy: Stripes.period)).clipShape(shape) }
            else { shape.fill(Palette.blue.opacity(OutBlockStyle.fillAlpha)) }
        }
        .overlay {
            // Warning border flashes pink/white at 2.5 Hz (mockup: floor(t*2.5) % 2).
            let flash = warn && Int(floor(t * 2.5)) % 2 == 1
            shape.strokeBorder(warn ? (flash ? Palette.white : Palette.pink) : Palette.blue.opacity(OutBlockStyle.borderAlpha),
                               lineWidth: OutBlockStyle.lineWidth)
        }
    }

    private var icon: String {
        guard let a = audio else { return "speaker.slash.fill" }
        if a.isBuiltInSpeaker { return "speaker.wave.3.fill" }
        switch a.transport {
        case .bluetooth: return "headphones"
        case .builtin: return "speaker.wave.2.fill"
        case .usb: return "cable.connector"
        case .hdmi: return "tv"
        case .airplay: return "airplayaudio"
        case .other: return "hifispeaker.fill"
        }
    }

    private var subtitle: String {
        guard let a = audio else { return "Check Sound settings" }
        let kind: String = if a.isBuiltInSpeaker { "Built-in speakers" } else {
            switch a.transport {
            case .bluetooth: "Bluetooth"
            case .builtin: "Built-in"
            case .usb: "USB"
            case .hdmi: "HDMI"
            case .airplay: "AirPlay"
            case .other: "Output"
            }
        }
        guard let v = a.volume else { return kind }
        return "\(kind) · volume \(Int((v * 100).rounded()))%"
    }
}

/// `repeating-linear-gradient(-45deg, pink .28 0 14px, pink .12 14px 28px)`, shifted right by `phase`.
private struct Stripes: View {
    static let band: CGFloat = 14 * 2.squareRoot()        // horizontal width of one 14 px band
    static let period: Double = Double(band) * 2          // 39.6 px, as in the mockup
    let phase: Double

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Palette.pink.opacity(0.12)))
            var p = Path()
            let h = size.height
            var x = CGFloat(phase) - CGFloat(Self.period) - h
            while x < size.width {
                p.move(to: CGPoint(x: x, y: h))
                p.addLine(to: CGPoint(x: x + Self.band, y: h))
                p.addLine(to: CGPoint(x: x + Self.band + h, y: 0))
                p.addLine(to: CGPoint(x: x + h, y: 0))
                p.closeSubpath()
                x += CGFloat(Self.period)
            }
            ctx.fill(p, with: .color(Palette.pink.opacity(0.28)))
        }
    }
}

// MARK: - Bluetooth

private struct BluetoothGrid: View {
    let devices: [BtDevice]

    var body: some View {
        if devices.isEmpty {
            Text("No devices connected")
                .font(.chakra(18, 500)).foregroundStyle(Palette.muted)
        } else {
            let shown = Array(devices.prefix(4))
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<((shown.count + 1) / 2), id: \.self) { row in
                    HStack(spacing: 14) {
                        cell(shown[row * 2])
                        if row * 2 + 1 < shown.count { cell(shown[row * 2 + 1]) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                    }
                }
            }
        }
    }

    private func cell(_ d: BtDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.icon(d.kind))
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Palette.text)
                .frame(width: 26)
            Text(d.name)
                .font(.chakra(18, 500))
                .foregroundStyle(Palette.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            BatteryView(percent: Self.level(d))
        }
        .frame(maxWidth: .infinity)
    }

    /// Single battery, else the lower earbud.
    static func level(_ d: BtDevice) -> Int? {
        if let b = d.battery { return b }
        let buds = [d.batteryL, d.batteryR].compactMap { $0 }
        return buds.min() ?? d.batteryCase
    }

    static func icon(_ k: BtKind) -> String {
        switch k {
        case .headphones: "headphones"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .controller: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}

private struct BatteryView: View {
    let percent: Int?

    var body: some View {
        let color: Color = switch batteryClass(percent) {
        case .ok: Palette.teal
        case .low: Palette.bad
        case .na: Palette.muted
        }
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Rectangle().strokeBorder(color, lineWidth: 2).frame(width: 26, height: 14)
                Rectangle().fill(color)
                    .frame(width: CGFloat(min(100, max(0, percent ?? 0))) * 0.2, height: 8)
                    .offset(x: 3)
            }
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.chakra(18, 600))
                .monospacedDigit()
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

// MARK: - System

private struct SystemBlock: View {
    let stats: SystemStats?
    let cpuBar: Double
    let memBar: Double

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                meter("CPU", stats.map { "\(Int($0.cpu.rounded()))%" } ?? "—", cpuBar)
                meter("RAM", stats.map { Self.ram($0) } ?? "—", memBar)
            }
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { i in
                    if let s = stats, i < s.topApps.count { app(s.topApps[i]) }
                    else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    static func ram(_ s: SystemStats) -> String {
        let gib = 1_073_741_824.0
        return String(format: "%.1f / %.0f GB", Double(s.memUsedBytes) / gib, Double(s.memTotalBytes) / gib)
    }

    private func meter(_ name: String, _ value: String, _ fill: Double) -> some View {
        VStack(spacing: 5) {
            HStack(alignment: .lastTextBaseline) {
                Text(name).font(.chakra(19, 600)).foregroundStyle(Palette.text)
                Spacer()
                Text(value).font(.chakra(24, 600)).foregroundStyle(Palette.white).monospacedDigit()
            }
            Bar(fill: fill)
        }
        .frame(maxWidth: .infinity)
    }

    private func app(_ a: AppUsage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(a.name)
                .font(.chakra(18, 700)).foregroundStyle(Palette.white)
                .lineLimit(1).truncationMode(.tail)
            (Text(fmtBytes(a.rssBytes)).foregroundColor(Palette.white)
             + Text(" · ").foregroundColor(Palette.text)
             + Text("\(Int(a.cpu.rounded()))%").foregroundColor(a.cpu >= 20 ? Palette.pink : Palette.muted))
                .font(.chakra(18, 500))
                .lineLimit(1)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .leading) { Palette.blue.frame(width: 3) }
    }
}

/// `.bar > span`: 12 px track, gradient fill blue → violet 70 % → pink with a blue glow.
struct Bar: View {
    let fill: Double
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(LinearGradient(stops: [.init(color: Palette.blue, location: 0), .init(color: Palette.violet, location: 0.7),
                                                 .init(color: Palette.pink, location: 1)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: g.size.width * CGFloat(min(1, max(0, fill))))
                    .shadow(color: Palette.blue.opacity(0.6), radius: 5)
            }
        }
        .frame(height: height)
        .clipped()
    }
}
