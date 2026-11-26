// AppMixer のデモ動画の台本。App Store のスクリーンショットと同じ部品（../screenshots/app.js の
// popover）を、その時刻の状態で組み直して動かす。アプリの実物の収録ではなく、再現。
// window.renderAt(秒) がその時刻の 1 コマを組む。コマは render-frames.mjs が 0 秒から順に撮る
// （指の跡とポインタの「最後の位置」は前のコマから引き継ぐので、途中の秒から始めない）。
//
// 見せる順: （開いたところから）Google Chrome の音量を 100% から 30% へ →
// システム音をミュート → FaceTime の通話で自動ダッキング → ミュージックの出力先を AirPods Pro へ →
// ミュージックの左右バランス。1 場面に 1 機能。
// 字幕は入れない。操作は、ポインタと右下のトラックパッドの図（指の位置。押している間は緑）で見せる。
// 自動で起きるダッキングの間は、図から指を離す（人が操作していないことが分かるように）。
//
// 置き場所は実物（MenuBarExtra の .window）と App Store の画像と同じく、メニューバーのアイコンの真下に開き、
// 画面の右端に収まるよう左へ押し戻す（../screenshots/app.js の layoutSide と同じ式）。倍率は、FaceTime の行と
// 帯が増えても右下の図（下から 34・高さ 213）に重ならない 1.5。
// 書き出すのは START からで、アイコンを押して開くところは台本にだけ残す: ページは動画の 0.1 秒目を表紙にするので、
// 頭から書き出すと、表紙が何も無い暗い画面になる（2026-11-11 のレビュー）。
//
// 画面の状態は、アプリが実際にその状況で出す表示に合わせる（決まりは ../screenshots/shots.js の先頭）。
// 動きは時刻だけから決める。乱数や実際の時計を使うと、撮り直すたびに違う動画になる。
(() => {
  const AM = window.AM;
  const Z = 1.5;
  // メニューバーのアイコンの選択の角丸（背景の絵が中心 x=1066・幅 36 で描く）の左端と、メニューバーの下端（34 と線 1）
  const ICON_LEFT = 1048;
  const POP_TOP = 35 + 4;
  const START = 1.62;
  const END = 16.8;
  const canvas = document.getElementById("canvas");

  const el = (tag, cls, parent) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    (parent || canvas).append(node);
    return node;
  };
  const stage = el("div", "stage");
  const ripple = el("div", "ripple");
  const pointer = el("div", "pointer");
  pointer.innerHTML =
    '<svg viewBox="0 0 20 30" width="26" height="39"><path d="M1.5 1.5 L1.5 23 L6.6 18.2 L10 26.8 L13.4 25.4 L10 17 L17 17 Z" fill="#000" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg>';
  const pad = el("div", "pad");
  const padRing = el("div", "pad-ring", pad);
  const trail = [0, 1, 2, 3, 4].map(() => el("div", "pad-trail", pad));
  const finger = el("div", "pad-finger", pad);

  const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
  const ease = (p) => p * p * (3 - 2 * p);
  // a から b の間で 0 → 1（ゆっくり動き出して、ゆっくり止まる）
  const ramp = (t, a, b) => ease(clamp((t - a) / (b - a)));
  const within = (t, a, b) => t >= a && t < b;
  // 音が鳴っているように、メーターを少し揺らす（決まった波。乱数は使わない）
  const wave = (t, seed) => 0.82 + 0.18 * (0.5 + 0.5 * Math.sin(t * 7.3 + seed) * Math.sin(t * 2.9 + seed * 1.7));

  // ─── 台本: その時刻の画面の状態 ──────────────────────────

  function model(t) {
    const call = within(t, 6.4, 8.8);
    const duck = 1 - 0.78 * (ramp(t, 6.4, 6.8) - ramp(t, 8.8, 9.2));
    const chromeVolume = 1 - 0.7 * ramp(t, 2.6, 4.0);
    const routed = t >= 11.3;
    const menuOpen = within(t, 10.0, 11.3);
    // 区切りのつまみは細い（3pt）ので、はっきり分かるところまで寄せる
    const balance = -0.6 * ramp(t, 12.9, 14.0);
    const rows = [];
    if (call) rows.push({ key: "facetime", ...APP.facetime, volume: 1, level: 0.5 * wave(t, 0.4) });
    rows.push({
      key: "chrome", ...APP.chrome, volume: chromeVolume, level: 0.62 * chromeVolume * duck * wave(t, 1.1),
      ducked: call, hover: within(t, 1.9, 4.4),
    });
    rows.push({
      key: "music", ...APP.music, volume: 1, level: 0.58 * duck * wave(t, 2.3), ducked: call, hover: within(t, 9.0, 14.6),
      balance, output: routed ? DEVICE.airpods : undefined, menu: menuOpen ? [DEVICE.airpods, DEVICE.speaker, DEVICE.usb] : undefined,
    });
    rows.push({ key: "system", ...APP.system, volume: 1, muted: t >= 5.4, level: 0, hover: within(t, 4.6, 6.0) });
    return {
      open: ramp(t, 1.2, 1.42),
      popover: { device: DEVICE.speaker, master: 0.62, rows, banner: call ? "FaceTime" : undefined },
      keys: rows.map((r) => r.key),
      menuOpen,
      // メニューの印: 開いた時点では「既定の出力」。ポインタが乗っている行が青
      menuHover: t >= 10.75 ? 1 : -1,
    };
  }

  // ─── 台本: ポインタと指 ──────────────────────────────────

  // ポインタの道筋。from・to は、その時刻の画面の部品の位置（行が増減しても追いかける）
  const moves = [
    { a: 0.3, b: 1.1, from: ["at", 930, 430], to: ["icon"] },
    { a: 1.7, b: 2.4, from: ["icon"], to: ["knob", "chrome"] },
    { a: 4.5, b: 5.2, from: ["knob", "chrome"], to: ["mute", "system"] },
    { a: 5.7, b: 6.3, from: ["mute", "system"], to: ["at", 620, 470] },
    { a: 9.1, b: 9.9, from: ["at", 620, 470], to: ["output", "music"] },
    { a: 10.3, b: 11.0, from: ["output", "music"], to: ["item", "music", 1] },
    { a: 12.0, b: 12.7, from: ["last"], to: ["balance", "music"] },
    // つまみから離れて、片側に寄ったつまみ（青）を見せる
    { a: 14.5, b: 15.2, from: ["balance", "music"], to: ["at", 620, 470] },
  ];
  // 押したまま動かす区間（ドラッグ）、押した瞬間、指がトラックパッドに触れている区間
  const presses = [[2.5, 4.1], [12.8, 14.1]];
  const clicks = [1.2, 5.4, 10.0, 11.3];
  const touching = [[0.3, START], [1.7, 4.3], [4.5, 6.3], [9.1, 11.65], [12.0, 14.3], [14.5, 15.2]];

  let keys = [];
  let last = { x: 930, y: 430 };
  function resolve(anchor) {
    const [kind, a, b] = anchor;
    if (kind === "at") return { x: a, y: b };
    // メニューバーのアイコン。背景の絵（scripts/make-backdrop.swift）が、中心 x=1066・上から 17 に描く
    if (kind === "icon") return { x: 1066, y: 19 };
    if (kind === "last") return last;
    const row = stage.querySelectorAll(".row")[keys.indexOf(a)];
    if (!row) return last;
    const target = {
      knob: () => row.querySelector(".slider .knob"),
      mute: () => row.querySelector(".mute"),
      output: () => row.querySelector(".output"),
      item: () => row.querySelectorAll(".menu .mi")[b],
      balance: () => row.querySelector(".meterbox .knob"),
    }[kind]();
    if (!target) return last;
    const r = target.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  }

  function pointerAt(t) {
    let current = null;
    for (const move of moves) if (t >= move.a) current = move;
    if (!current) return resolve(moves[0].from);
    const to = resolve(current.to);
    if (t >= current.b) return to;
    const from = resolve(current.from);
    const p = ramp(t, current.a, current.b);
    return { x: from.x + (to.x - from.x) * p, y: from.y + (to.y - from.y) * p };
  }

  // ─── 1 コマを組む ────────────────────────────────────────

  const history = [];
  window.renderAt = (videoTime) => {
    const t = START + videoTime;
    const m = model(t);
    keys = m.keys;
    canvas.dataset.open = m.open > 0 ? "1" : "0";
    stage.replaceChildren();
    if (m.open > 0) {
      const wrap = el("div", "popwrap", stage);
      wrap.style.left = `${Math.min(ICON_LEFT - 8 * Z, 1440 - 56 - 420 * Z)}px`;
      wrap.style.top = `${POP_TOP}px`;
      wrap.style.opacity = m.open;
      wrap.style.transform = `scale(${0.96 + 0.04 * m.open})`;
      const pop = AM.popover(m.popover, Z);
      wrap.append(pop);
      // 出力先のメニューは、macOS と同じく画面の内側へ押し戻す（../screenshots/app.js の layoutSide と同じ）
      for (const menu of pop.querySelectorAll(".menu")) {
        const over = menu.getBoundingClientRect().right - (1440 - 24);
        if (over > 0) menu.style.left = `${-6 - over / Z}px`;
      }
      pop.querySelectorAll(".menu .mi").forEach((item, index) => {
        item.classList.toggle("hl", index === m.menuHover);
        const tick = item.querySelector(".tick");
        tick.replaceChildren();
        if (index === 0) tick.append(AM.sym("checkmark", 11));
      });
    }
    const at = pointerAt(t);
    // 部品が消えた直後（メニューを閉じたときなど）は、最後の位置に留まる。そこから動き出す道筋
    // （moves の from: ["last"]。12.0〜12.7）が終わるまでは、留まった位置を起点に据えたままにする。
    // コマごとに起点を書き換えると、前のコマの位置を追いかける動きになり、コマ数で速さが変わる
    if (!within(t, 11.3, 12.7)) last = at;
    const p = within(t, 11.3, 12.0) ? last : at;
    pointer.style.transform = `translate(${p.x - 2}px, ${p.y - 2}px)`;

    const pressed = presses.some(([a, b]) => within(t, a, b));
    const click = clicks.find((c) => within(t, c, c + 0.4));
    ripple.style.opacity = click === undefined ? 0 : 0.9 * (1 - (t - click) / 0.4);
    const size = click === undefined ? 0 : 14 + 46 * ease((t - click) / 0.4);
    ripple.style.width = ripple.style.height = `${size}px`;
    ripple.style.transform = `translate(${p.x - size / 2}px, ${p.y - size / 2}px)`;

    // 右下の図: ポインタの位置をトラックパッドの上の指の位置に写す
    const touch = touching.some(([a, b]) => within(t, a, b));
    const fx = 14 + clamp((p.x - 560) / 860) * (320 - 28);
    const fy = 14 + clamp(p.y / 720) * (213 - 28);
    finger.style.opacity = touch ? 1 : 0;
    finger.style.transform = `translate(${fx - 12.5}px, ${fy - 12.5}px)`;
    finger.dataset.pressed = pressed || click !== undefined ? "1" : "0";
    padRing.style.opacity = click === undefined ? 0 : 0.9 * (1 - (t - click) / 0.4);
    const ring = click === undefined ? 0 : 20 + 34 * ease((t - click) / 0.4);
    padRing.style.width = padRing.style.height = `${ring}px`;
    padRing.style.transform = `translate(${fx - ring / 2}px, ${fy - ring / 2}px)`;
    history.push({ t, x: fx, y: fy, touch });
    while (history.length && t - history[0].t > 0.45) history.shift();
    trail.forEach((dot, index) => {
      const mark = history[Math.floor((index / trail.length) * history.length)];
      const strength = mark && mark.touch && touch ? clamp(1 - (t - mark.t) / 0.45) : 0;
      const d = 18 * (0.5 + 0.5 * strength);
      dot.style.opacity = 0.35 * strength;
      dot.style.width = dot.style.height = `${d}px`;
      dot.style.transform = mark ? `translate(${mark.x - d / 2}px, ${mark.y - d / 2}px)` : "";
    });
  };
  window.videoDuration = END - START;
  window.renderAt(0);
})();
