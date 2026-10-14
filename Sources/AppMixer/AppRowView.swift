import SwiftUI

struct AppRowView: View {

    @ObservedObject var model: MixerModel
    let display: MixerModel.DisplayApp

    /// カーソルが乗っている間だけ、普段は伏せている操作を出す。
    @State private var isHovered = false
    /// つまみのドラッグを始めたときのバランス。移動量をここに足す。
    @State private var dragStartBalance: Float?

    private var app: AudioApp { display.app }

    /// 既定から動かしている行は、ホバーしていなくても操作を見せておく。
    /// そうしないと「なぜこのアプリだけ音が違うのか」が分からなくなる。
    private var showsControls: Bool {
        isHovered || display.muted || display.outputDeviceUID != nil
            || display.volume < 0.999 || display.balance != 0
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                icon

                VStack(alignment: .leading, spacing: 5) {
                    titleLine
                    controlLine
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider().padding(.leading, 44)
        }
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .opacity(app.isRunningOutput ? 1.0 : 0.55)
        .onHover { isHovered = $0 }
    }

    // MARK: - 1 段目: 名前・状態・出力先・音量値

    private var titleLine: some View {
        HStack(spacing: 6) {
            nameLabel

            statusBadge

            Spacer(minLength: 6)

            if showsControls {
                outputMenu
            }

            Text(display.muted ? localized("ミュート") : "\(Int((display.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(display.muted ? Color.secondary : Color.primary)
                .frame(width: 52, alignment: .trailing)
                // 枠いっぱいを当たり判定にする。これが無いと数字の字面の上
                // でしかダブルクリックを拾えない。
                .contentShape(Rectangle())
                .help(volumeHelp)
                // スライダーを掴んで戻すより速い、定番の操作。
                .onTapGesture(count: 2) {
                    model.setVolume(1.0, for: app)
                }
        }
    }

    /// アプリ名。「システム音」だけは何が入っているかの説明を添える。
    @ViewBuilder
    private var nameLabel: some View {
        let name = Text(app.name)
            .font(.callout).fontWeight(.medium)
            .lineLimit(1)
            .truncationMode(.tail)
        if app.isSystem {
            name.help(localized("通知音・警告音・効果音など、アプリに属さない音をまとめたものです"))
        } else {
            name
        }
    }

    private var volumeHelp: String {
        // 書式つきの文言なので、原文の 100% は %% と書く。
        String(
            format: localized("この音量は「%@」に対して記憶されます。ダブルクリックで 100%% に戻します"),
            model.memoryDeviceName(for: app)
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let trouble = display.trouble {
            Image(systemName: trouble == .silenced
                  ? "speaker.slash.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(trouble == .silenced ? Color.red : Color.orange)
                .help(trouble.message)
        } else if display.ducked {
            Image(systemName: "arrow.down.right.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.orange)
                .help("通話中のため自動で音量を下げています")
        }
    }

    // MARK: - 2 段目: ミュート + スライダー（直下にメーター）

    private var controlLine: some View {
        HStack(spacing: 8) {
            // ホバー前も場所は確保しておく。出し入れで幅が動くと目障りなため。
            Button {
                model.setMuted(!display.muted, for: app)
            } label: {
                Image(systemName: display.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(display.muted ? Color.accentColor : Color.secondary)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)

            // スライダーとメーターを同じ幅・同じ開始位置に揃えると、
            // メーターが「そのスライダーのレベル」として読める。
            VStack(alignment: .leading, spacing: 2) {
                Slider(
                    value: Binding(
                        get: { Double(display.volume) },
                        set: { model.setVolume(Float($0), for: app) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(display.muted)

                meterBar
            }
        }
    }

    // MARK: - Parts

    private var icon: some View {
        Group {
            if let icon = display.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// 出力先の選択。既定のままならアイコンだけの控えめな表示にして、
    /// 別デバイスへ振っているときだけデバイス名を出す。
    private var outputMenu: some View {
        Menu {
            Button {
                model.setOutputDevice(nil, for: app)
            } label: {
                if display.outputDeviceUID == nil {
                    Label("既定の出力", systemImage: "checkmark")
                } else {
                    Text("既定の出力")
                }
            }
            Divider()
            ForEach(model.outputDevices) { device in
                Button {
                    model.setOutputDevice(device.uid, for: app)
                } label: {
                    if display.outputDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            if display.outputDeviceUID == nil {
                Image(systemName: "hifispeaker")
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "hifispeaker.fill")
                    Text(model.outputDeviceName(display.outputDeviceUID))
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(display.outputDeviceUID == nil ? Color.secondary : Color.accentColor)
        .help("このアプリの出力先を選ぶ")
    }

    /// レベルメーター。左右バランスの「区切りのつまみ」を兼ねる。
    ///
    /// つまみは左右の境目を表し、ドラッグで片側を絞る。ダブルクリックで
    /// 中央に戻す。メーターの伸びは計測できている（タップが張れている）
    /// 行だけに出し、つまみは操作を見せている間だけ出す。
    private var meterBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: Self.meterHeight)
                Capsule()
                    .fill(meterColor)
                    .frame(width: width * CGFloat(min(1, max(0, display.level))),
                           height: Self.meterHeight)
                    .animation(.linear(duration: 0.05), value: display.level)
                    .opacity(showsMeter ? 1 : 0)
                // 区切りのつまみ。中央から動かしているときはアクセント色にして、
                // 「この行だけ片側が小さい」と分かるようにする。
                Capsule()
                    .fill(display.balance == 0 ? Color.secondary : Color.accentColor)
                    .frame(width: 3, height: height)
                    .position(x: Balance.x(of: display.balance, width: width), y: height / 2)
                    .opacity(showsControls ? 1 : 0)
            }
            .frame(height: height)
            // 棒の上ならどこでも掴める。4pt の線の上だけでは当たらない。
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                model.setBalance(0, for: app)
            }
            // 押した位置へ飛ばさず、動かしたぶんだけ動かす。ダブルクリックの
            // 1 回目や狙いを外したクリックで、押しただけでは変わらないように。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStartBalance ?? display.balance
                        dragStartBalance = start
                        let next = Balance.dragged(
                            from: start, translation: value.translation.width, width: width
                        )
                        if next != display.balance { model.setBalance(next, for: app) }
                    }
                    .onEnded { _ in dragStartBalance = nil }
            )
        }
        .frame(height: Self.knobHeight)
        .opacity(showsMeter || showsControls ? 1 : 0)
        .allowsHitTesting(showsControls)
        .help(balanceHelp)
    }

    private static let meterHeight: CGFloat = 4
    private static let knobHeight: CGFloat = 10

    /// 計測できていない行は伸びようがないので、出しても誤解を招く。
    private var showsMeter: Bool { app.isRunningOutput && display.metered }

    private var balanceHelp: String {
        String(
            format: localized("左右バランス: %@。ドラッグで片側を絞り、ダブルクリックで中央に戻します"),
            Balance.label(display.balance)
        )
    }

    private var meterColor: Color {
        switch display.level {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default:     return .red
        }
    }
}
