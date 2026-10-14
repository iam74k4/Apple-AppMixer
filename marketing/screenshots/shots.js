// スクリーンショット 1 枚ごとの中身。画面の状態（アプリの UI）と文言を置く。
//
// 画面の状態は、アプリが実際にその状況で出す表示に合わせること。
//   - 一覧の並びは「再生中 → 名前順 → システム音は最後」
//     （AudioAppEnumerator.group と同じ）
//   - 音量が 100% 未満・ミュート・出力先の振り分け・バランスがある行は、
//     ミュートボタン・出力先ボタン・バランスのつまみが常に見える
//     （AppRowView.showsControls）
//   - メーターは音量を掛けた後のレベル（ProcessTap の displayPeak）。
//     30% の行は 100% の行より短く、ミュート中は伸びない
//   - バランスはメーターの上の区切りのつまみ。中央なら灰色、動かすと青
//   - ダッキング中も表示する音量は利用者が決めた値のまま。行に橙の印が付く
//
// { ja, en } の形の値は言語ごとに切り替わる。アプリ名とデバイス名は macOS が
// 返す名前なので、その言語の Mac で実際に出る名前にする（英語の Mac では
// 「ミュージック」ではなく「Music」）。AppMixer 自身の文言は app.js の UI。
//
// 背景は無地に近い暗い面にして、ポップオーバーと文言だけで伝える。

const APP = {
  chrome: { name: "Google Chrome", icon: "chrome" },
  facetime: { name: "FaceTime", icon: "facetime" },
  music: { name: { ja: "ミュージック", en: "Music" }, icon: "music" },
  // どのアプリにも属さない音（通知音・効果音）をまとめた行。
  system: { name: { ja: "システム音", en: "System Sounds" }, icon: "system" },
};

const DEVICE = {
  speaker: { ja: "MacBook Air のスピーカー", en: "MacBook Air Speakers" },
  airpods: "AirPods Pro",
  usb: "USB Audio Device",
};

window.SHOTS = [
  {
    id: "01-per-app-volume",
    layout: "side",
    z: 1.8,
    popover: {
      device: DEVICE.speaker,
      master: 0.62,
      rows: [
        { ...APP.chrome, volume: 0.3, level: 0.21 },
        { ...APP.music, volume: 0.8, level: 0.56 },
        { ...APP.system, volume: 1.0, muted: true, level: 0 },
      ],
    },
    copy: {
      ja: {
        eyebrow: "Mac のための音量ミキサー",
        headline: "動画は小さく。\n音楽はそのまま。",
        sub: "Windows の音量ミキサーのように、アプリごとに音量を変えられます。メニューバーからすぐ。",
        points: [
          { icon: "chrome", text: "動画は控えめに", chip: "30%" },
          { icon: "music", text: "音楽はそのまま", chip: "80%" },
          { icon: "system", text: "通知音だけ消す", chip: "ミュート", gray: true },
        ],
      },
      en: {
        eyebrow: "A volume mixer for your Mac",
        headline: "Turn the video down.\nKeep the music up.",
        sub: "Give every app its own volume — just like the Volume Mixer on Windows, right in your menu bar.",
        points: [
          { icon: "chrome", text: "Videos, a little quieter", chip: "30%" },
          { icon: "music", text: "Music, right where it was", chip: "80%" },
          { icon: "system", text: "Notification pings, gone", chip: "Muted", gray: true },
        ],
      },
    },
  },

  {
    id: "02-auto-ducking",
    layout: "side",
    z: 1.8,
    popover: {
      device: DEVICE.speaker,
      master: 0.62,
      rows: [
        { ...APP.facetime, volume: 1.0, level: 0.48 },
        { ...APP.chrome, volume: 0.3, level: 0.05, ducked: true },
        { ...APP.music, volume: 0.8, level: 0.12, ducked: true },
      ],
      banner: "FaceTime",
    },
    copy: {
      ja: {
        eyebrow: "通話中の自動ダッキング",
        headline: "通話が始まったら、\n音楽は自動で小さく。",
        sub: "FaceTime・Zoom・Teams などの通話や、マイクの使用を検知。通話が終われば元の音量に戻ります。",
        points: [
          { symbol: "phone.fill", text: "相手の声は小さくしない" },
          { symbol: "slider.horizontal.3", text: "下げる量は自分で決められる" },
          { symbol: "arrow.triangle.2.circlepath", text: "通話が終われば元どおり" },
        ],
      },
      en: {
        eyebrow: "Automatic ducking",
        headline: "A call starts.\nThe music steps back.",
        sub: "AppMixer notices FaceTime, Zoom, Teams and other calls — or your mic going live — and lowers everything else. When the call ends, it all comes back.",
        points: [
          { symbol: "phone.fill", text: "The other person stays loud" },
          { symbol: "slider.horizontal.3", text: "You choose how far it drops" },
          { symbol: "arrow.triangle.2.circlepath", text: "Restored when you hang up" },
        ],
      },
    },
  },

  {
    id: "03-per-device-memory",
    layout: "compare",
    z: 1.26,
    sides: [
      {
        symbol: "headphones",
        caption: DEVICE.airpods,
        popover: {
          device: DEVICE.airpods,
          master: 0.45,
          rows: [
            { ...APP.chrome, volume: 0.2, level: 0.14 },
            { ...APP.music, volume: 0.35, level: 0.25 },
          ],
        },
      },
      {
        symbol: "hifispeaker.fill",
        caption: DEVICE.speaker,
        popover: {
          device: DEVICE.speaker,
          master: 0.7,
          rows: [
            { ...APP.chrome, volume: 0.5, level: 0.35 },
            { ...APP.music, volume: 0.85, level: 0.6 },
          ],
        },
      },
    ],
    copy: {
      ja: {
        eyebrow: "出力デバイスごとに記憶",
        headline: "イヤホンでは控えめに、\nスピーカーでは大きめに。",
        sub: "同じアプリでも、デバイスごとに別の音量を覚えます。\nつなぎ替えるだけで、自動で切り替わります。",
        swap: "つなぎ替えると\n自動で切り替え",
      },
      en: {
        eyebrow: "Remembered per output device",
        headline: "Quieter in your AirPods.\nLouder on the speakers.",
        sub: "Every app keeps a separate volume for each output device.\nSwitch devices and the volumes switch with you.",
        swap: "Switches\nautomatically",
      },
    },
  },

  {
    id: "04-per-app-output",
    layout: "side",
    z: 1.8,
    // 既定の出力は AirPods（通話はそのまま AirPods）、ミュージックだけスピーカーへ振る。
    popover: {
      device: DEVICE.airpods,
      master: 0.5,
      rows: [
        { ...APP.facetime, volume: 1.0, level: 0.5 },
        {
          ...APP.music, volume: 0.7, level: 0.48, output: DEVICE.speaker,
          menu: [DEVICE.airpods, DEVICE.speaker, DEVICE.usb],
        },
      ],
    },
    copy: {
      ja: {
        eyebrow: "アプリごとの出力先",
        headline: "音楽はスピーカー、\n通話はイヤホン。",
        sub: "アプリごとに、音を出すデバイスを選べます。アプリの再起動も、システム設定を開く必要もありません。",
        points: [
          { icon: "music", text: "ミュージック", chip: "スピーカー" },
          { icon: "facetime", text: "FaceTime", chip: "AirPods Pro", gray: true },
        ],
      },
      en: {
        eyebrow: "Per-app output",
        headline: "Music on the speakers.\nCalls in your AirPods.",
        sub: "Send each app to the output device you want. No restarting apps, no trip to System Settings.",
        points: [
          { icon: "music", text: "Music", chip: "Speakers" },
          { icon: "facetime", text: "FaceTime", chip: "AirPods Pro", gray: true },
        ],
      },
    },
  },

  {
    id: "05-balance",
    layout: "side",
    z: 1.8,
    // ミュージックだけ右を 30% 絞る（つまみが左へ寄る）。
    popover: {
      device: DEVICE.airpods,
      master: 0.55,
      rows: [
        { ...APP.chrome, volume: 0.6, level: 0.3 },
        { ...APP.music, volume: 0.8, level: 0.5, balance: -0.3 },
        { ...APP.system, volume: 0.5, level: 0 },
      ],
    },
    copy: {
      ja: {
        eyebrow: "アプリごとの左右バランス",
        headline: "左右のバランスも、\nアプリごとに。",
        sub: "メーターの上の区切りのつまみをドラッグするだけ。片側を絞るだけなので音は歪みません。デバイスごとに記憶します。",
        points: [
          { symbol: "arrow.left.and.right", text: "ドラッグで片側だけ絞る" },
          { symbol: "headphones", text: "聴こえ方の左右差に合わせる" },
          { symbol: "arrow.counterclockwise", text: "ダブルクリックで中央に戻す" },
        ],
      },
      en: {
        eyebrow: "Per-app balance",
        headline: "Left and right,\nper app too.",
        sub: "Drag the divider on the level meter. It only lowers one side, so nothing distorts. Remembered per output device.",
        points: [
          { symbol: "arrow.left.and.right", text: "Drag to lower one side" },
          { symbol: "headphones", text: "Match how you hear" },
          { symbol: "arrow.counterclockwise", text: "Double-click to center" },
        ],
      },
    },
  },

  {
    id: "06-features",
    layout: "grid",
    copy: {
      ja: {
        headline: "Mac に足りなかった音量調整を、\nメニューバーに。",
        features: [
          { symbol: "slider.horizontal.3", text: "アプリ別の\n音量・ミュート" },
          { symbol: "arrow.left.and.right", text: "アプリ別の\n左右バランス" },
          { symbol: "bell.fill", text: "通知音・効果音も\nまとめて調整" },
          { symbol: "waveform", text: "リアルタイムの\nレベルメーター" },
          { symbol: "phone.fill", text: "通話中の\n自動ダッキング" },
          { symbol: "headphones", text: "デバイスごとに\n音量を記憶" },
          { symbol: "hifispeaker.2.fill", text: "アプリ別の\n出力先" },
          { symbol: "menubar.rectangle", text: "メニューバー常駐\nログイン時に起動" },
        ],
        trust: [
          { symbol: "checkmark.seal.fill", text: "買い切り・サブスクなし" },
          { symbol: "lock.shield", text: "データ収集なし" },
          { symbol: "mic.slash", text: "音声の録音・送信なし" },
        ],
        requirement: "macOS 14.4 以降 ・ 日本語 / English",
      },
      en: {
        headline: "The volume controls macOS left out,\nright in your menu bar.",
        features: [
          { symbol: "slider.horizontal.3", text: "Per-app\nvolume & mute" },
          { symbol: "arrow.left.and.right", text: "Per-app\nleft/right balance" },
          { symbol: "bell.fill", text: "System sounds\nin one row" },
          { symbol: "waveform", text: "Live\nlevel meters" },
          { symbol: "phone.fill", text: "Auto-ducking\nduring calls" },
          { symbol: "headphones", text: "Volume remembered\nper device" },
          { symbol: "hifispeaker.2.fill", text: "Per-app\noutput device" },
          { symbol: "menubar.rectangle", text: "Lives in the menu bar\nLaunches at login" },
        ],
        trust: [
          { symbol: "checkmark.seal.fill", text: "One-time purchase" },
          { symbol: "lock.shield", text: "No data collected" },
          { symbol: "mic.slash", text: "Never records or sends audio" },
        ],
        requirement: "macOS 14.4 or later · English / 日本語",
      },
    },
  },
];
