// window.renderAt(秒) と window.videoDuration を持つページ（video.html）を、1 コマずつ PNG に撮る
// （1440×900・デバイスの倍率 1）。
//
//   node render-frames.mjs <ページの URL> <出力のフォルダ> [fps（既定 30）]
//
// 出力: <出力のフォルダ>/f00000.png から順に、videoDuration × fps 枚。
//
// npm の依存を持たない。Google Chrome をヘッドレスで 1 回だけ起動し、Node の組み込みの WebSocket
// （Node 22 以降）で、DevTools Protocol（CDP）に直接話す。コマごとに Chrome を起動し直す
// やり方（スクリーンショットの render.sh）は、コマの数だけ起動を待つことになり、指の跡のような
// 「前のコマから引き継ぐ状態」も持てない。
//
// 実際の時計に頼らない。ページは渡した秒のコマを組むだけで、撮るのはそのコマが組み上がってから。
// 画面の録画と違って、Mac の速さでコマが落ちたり、動きの速さが変わったりしない。
// ただし、画素の値まで毎回同じとは限らない（Chrome 157 では、474 コマのうち 1 コマで、指の縁の
// 56 画素が実行のたびに 5/255 までずれた。目では分からない）。コマを画素で比べて確かめるときは、
// この程度の差を見込むこと。

import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const WIDTH = 1440;
const HEIGHT = 900;
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

const [url, out, fpsArg] = process.argv.slice(2);
const fps = Number(fpsArg || 30);
if (!url || !out || !(fps > 0)) {
  console.error("使い方: node render-frames.mjs <ページの URL> <出力のフォルダ> [fps]");
  process.exit(2);
}
if (typeof WebSocket !== "function") {
  console.error(`error: Node.js 22 以降が要ります（組み込みの WebSocket を使うため）。いまは ${process.version}`);
  process.exit(1);
}

/** 1 つの WebSocket の上で CDP を話す。返事は id で、ページからの知らせは method で受ける。 */
class Cdp {
  constructor(socket) {
    this.socket = socket;
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.closed = null;
    socket.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== undefined) {
        const waiter = this.pending.get(message.id);
        if (!waiter) return;
        this.pending.delete(message.id);
        if (message.error) waiter.reject(new Error(`${waiter.method}: ${message.error.message}`));
        else waiter.resolve(message.result);
      } else {
        for (const listener of this.listeners.get(message.method) || []) listener(message.params);
      }
    });
    // Chrome が先に落ちたら、返事を待ったまま止まらないように全部を失敗にする。
    socket.addEventListener("close", () => {
      this.closed = new Error("Chrome との接続が切れました");
      for (const waiter of this.pending.values()) waiter.reject(this.closed);
      this.pending.clear();
    });
  }

  static connect(endpoint) {
    return new Promise((resolve, reject) => {
      const socket = new WebSocket(endpoint);
      socket.addEventListener("open", () => resolve(new Cdp(socket)), { once: true });
      socket.addEventListener("error", () => reject(new Error(`Chrome に接続できません: ${endpoint}`)), { once: true });
    });
  }

  send(method, params = {}, sessionId) {
    if (this.closed) return Promise.reject(this.closed);
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this.socket.send(JSON.stringify({ id, method, params, sessionId }));
    });
  }

  on(method, listener) {
    this.listeners.set(method, [...(this.listeners.get(method) || []), listener]);
  }
}

/** Chrome を起動し、DevTools の口（ws://…）が開くのを待つ。 */
function launchChrome(profile) {
  const chrome = spawn(CHROME, [
    "--headless=new",
    // 0 は「空いているポート」。開いた口は Chrome が標準エラーに書く。
    "--remote-debugging-port=0",
    // ふだん使いの Chrome とは別のプロファイルで起動する（Chrome は既定のプロファイルを
    // リモートデバッグに開かない。開いている Chrome にも触らない）。
    `--user-data-dir=${profile}`,
    "--no-first-run",
    "--no-default-browser-check",
    // スクリーンショットの render.sh と同じく、GPU を使わずに描く（描く Mac の GPU に左右されない）。
    "--disable-gpu",
    "--hide-scrollbars",
    "--force-device-scale-factor=1",
    `--window-size=${WIDTH},${HEIGHT}`,
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });

  const endpoint = new Promise((resolve, reject) => {
    let log = "";
    const timer = setTimeout(() => reject(new Error(`Chrome が 30 秒たっても起動しません\n${log}`)), 30_000);
    chrome.stderr.setEncoding("utf8");
    chrome.stderr.on("data", (chunk) => {
      log += chunk;
      const found = log.match(/DevTools listening on (ws:\/\/\S+)/);
      if (found) {
        clearTimeout(timer);
        resolve(found[1]);
      }
    });
    chrome.once("error", (error) => {
      clearTimeout(timer);
      reject(new Error(`Google Chrome を起動できません（CHROME=<実行ファイル> で指定できます）: ${error.message}`));
    });
    chrome.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`Chrome が起動の途中で終わりました（終了コード ${code}）\n${log}`));
    });
  });
  return { chrome, endpoint };
}

const exited = (child) =>
  new Promise((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) resolve();
    else child.once("exit", resolve);
  });

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  mkdirSync(out, { recursive: true });
  // 前に撮ったコマを残さない。台本を短くしたあとに古いコマが残っていると、
  // 動画にするときに末尾へ混じる。消すのは、この道具が付ける名前のものだけ。
  for (const name of readdirSync(out)) {
    if (/^f\d{5}\.png$/.test(name)) rmSync(join(out, name));
  }

  const profile = mkdtempSync(join(tmpdir(), "appmixer-demo-chrome-"));
  const { chrome, endpoint } = launchChrome(profile);
  try {
    const cdp = await Cdp.connect(await endpoint);
    const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
    const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
    const page = (method, params) => cdp.send(method, params, sessionId);

    // ページの中の失敗（スクリプトの例外、読めなかった部品や背景）は、黙って撮り進めない。
    // 背景の無い動画や、アイコンの欠けた動画ができてしまう。
    const problems = [];
    cdp.on("Runtime.exceptionThrown", ({ exceptionDetails }) => {
      problems.push(exceptionDetails.exception?.description || exceptionDetails.text);
    });
    cdp.on("Log.entryAdded", ({ entry }) => {
      if (entry.level === "error") problems.push(`${entry.text}${entry.url ? ` (${entry.url})` : ""}`);
    });
    const check = () => {
      if (problems.length) throw new Error(`ページでエラーが出ました:\n  ${problems.join("\n  ")}`);
    };
    /** ページの中で式を評価する。Promise なら終わるまで待つ。 */
    const evaluate = async (expression) => {
      const { result, exceptionDetails } = await page("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
      if (exceptionDetails) {
        throw new Error(`ページでエラーが出ました: ${exceptionDetails.exception?.description || exceptionDetails.text}`);
      }
      return result.value;
    };

    await page("Page.enable");
    await page("Runtime.enable");
    await page("Log.enable");
    await page("Emulation.setDeviceMetricsOverride", { width: WIDTH, height: HEIGHT, deviceScaleFactor: 1, mobile: false });

    const loaded = new Promise((resolve) => cdp.on("Page.loadEventFired", resolve));
    const navigation = await page("Page.navigate", { url });
    if (navigation.errorText) throw new Error(`ページを開けません: ${url}（${navigation.errorText}）`);
    await loaded;
    check();

    // video.js は defer なので、load の時点で renderAt がある。無ければ部品が足りていない。
    const ready = await evaluate('typeof window.renderAt === "function" && typeof window.videoDuration === "number"');
    if (!ready) {
      throw new Error("ページに window.renderAt と window.videoDuration がありません（先に部品と背景を作ること。render.sh）");
    }
    await evaluate("document.fonts.ready.then(() => true)");

    const duration = await evaluate("window.videoDuration");
    const count = Math.round(duration * fps);
    for (let frame = 0; frame < count; frame++) {
      // そのコマで初めて出る画像（行のアイコン）の読み込みは、撮るのを待ってくれない。
      // 読めてから撮る。読めない画像があれば decode() が失敗して、ここで止まる。
      try {
        await evaluate(`(async () => {
          window.renderAt(${frame / fps});
          await Promise.all([...document.images].map((image) => image.decode()));
          return true;
        })()`);
      } catch (error) {
        // どのファイルが読めなかったかは、Chrome の知らせ（problems）のほうに出る。
        check();
        throw error;
      }
      const { data } = await page("Page.captureScreenshot", { format: "png" });
      check();
      writeFileSync(join(out, `f${String(frame).padStart(5, "0")}.png`), Buffer.from(data, "base64"));
    }
    console.log(`frames 0..${count - 1} (${duration}s at ${fps}fps) -> ${out}`);

    await cdp.send("Browser.close").catch(() => {});
    await Promise.race([exited(chrome), sleep(5000)]);
  } finally {
    if (chrome.exitCode === null && chrome.signalCode === null) {
      chrome.kill();
      await Promise.race([exited(chrome), sleep(5000)]);
    }
    rmSync(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

main().catch((error) => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
