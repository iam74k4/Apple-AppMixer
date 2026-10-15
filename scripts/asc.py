#!/usr/bin/env python3
"""App Store Connect API を CI から叩くための小さな道具。

main へマージしたあとの「アップロード → 処理待ち → 審査提出 → 配信確認」を
人手を挟まずに進めるために使う。fastlane を丸ごと持ち込むほどの量ではないので、
必要な 3 つの操作だけを置く。

    wait-build   アップロードしたビルドの処理が終わるのを待つ
    submit       バージョンにビルドを紐づけ、リリースノートを入れて審査に出す
    state        いま App Store 側がそのバージョンをどう扱っているかを表示する
    screenshots  製品ページのスクリーンショットを、書き出した PNG で差し替える
    withdraw     審査中のバージョンがあれば取り下げて、編集できる状態に戻す

認証は App Store Connect API キー（.p8）。次の環境変数を読む。

    ASC_API_KEY_ID      キー ID
    ASC_API_ISSUER_ID   Issuer ID
    ASC_API_KEY_P8      .p8 の中身そのもの
    ASC_BUNDLE_ID       対象アプリのバンドル ID

依存は PyJWT（と cryptography）だけ。HTTP は標準ライブラリで足りる。
"""

import argparse
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com"
PLATFORM = "MAC_OS"

# 配信が始まった状態。ここに来たらタグを打ってよい。
# appVersionState では READY_FOR_DISTRIBUTION、旧 appStoreState では READY_FOR_SALE。
LIVE_STATES = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION"}
# 人が App Store Connect で操作しないと先に進まない状態。待っても変わらない。
STUCK_STATES = {
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "DEVELOPER_REMOVED_FROM_SALE",
}


def log(message):
    # 進捗は stderr へ出す。stdout は呼び出し側が値として読むため混ぜない。
    print(message, file=sys.stderr, flush=True)


def die(message):
    log(f"error: {message}")
    sys.exit(1)


# --- API ------------------------------------------------------------------


def token():
    """20 分で切れる ES256 の JWT を作る。Apple は 20 分より長いものを拒む。"""
    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer = os.environ.get("ASC_API_ISSUER_ID")
    private_key = os.environ.get("ASC_API_KEY_P8")
    if not (key_id and issuer and private_key):
        die("ASC_API_KEY_ID / ASC_API_ISSUER_ID / ASC_API_KEY_P8 が要ります。")
    now = int(time.time())
    return jwt.encode(
        {"iss": issuer, "iat": now, "exp": now + 20 * 60, "aud": "appstoreconnect-v1"},
        private_key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def api(method, path, body=None, params=None):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Authorization", f"Bearer {token()}")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request) as response:
            raw = response.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as error:
        # Apple のエラーは本文にしか理由が書かれていない。捨てると原因が追えない。
        detail = error.read().decode(errors="replace")
        raise ApiError(error.code, detail) from None


class ApiError(Exception):
    def __init__(self, status, detail):
        super().__init__(f"HTTP {status}: {detail}")
        self.status = status
        self.detail = detail


def app_id():
    bundle_id = os.environ.get("ASC_BUNDLE_ID")
    if not bundle_id:
        die("ASC_BUNDLE_ID が要ります。")
    found = api("GET", "/v1/apps", params={"filter[bundleId]": bundle_id})["data"]
    if not found:
        die(
            f"バンドル ID {bundle_id} のアプリが見つかりません。"
            " App Store Connect にアプリレコードを作ってください。"
        )
    return found[0]["id"]


# --- wait-build -----------------------------------------------------------


def find_build(app, build_number, version):
    """アップロードしたビルドを探す。

    ASC では builds.version が CFBundleVersion（ビルド番号）で、
    preReleaseVersion.version が表示用バージョン。名前が紛らわしいので注意。

    必ず両方で絞る。ビルド番号だけで探すと、同じ番号を持つ別バージョンの
    古いビルド（例: 1.0 (10001) と 1.0.1 (10001)）を掴んでしまい、
    紐づけた版が INVALID_BINARY になる。処理中のビルドがまだ一覧に出て
    いない間は None を返し、呼び出し側が待つ。
    """
    found = api(
        "GET",
        "/v1/builds",
        params={
            "filter[app]": app,
            "filter[version]": build_number,
            "filter[preReleaseVersion.version]": version,
            "sort": "-uploadedDate",
            "limit": 1,
        },
    )["data"]
    return found[0] if found else None


def cmd_wait_build(args):
    app = app_id()
    deadline = time.time() + args.timeout
    while True:
        build = find_build(app, args.build, args.version)
        if build is None:
            log(f"ビルド {args.version} ({args.build}) はまだ現れていません。")
        else:
            state = build["attributes"].get("processingState")
            log(f"processingState: {state}")
            if state == "VALID":
                print(build["id"])
                return
            if state in ("INVALID", "FAILED"):
                die(
                    f"ビルドの処理が {state} で終わりました。"
                    " App Store Connect か、Apple からのメールに理由が出ています。"
                )
        if time.time() >= deadline:
            die(
                f"{args.timeout} 秒待ちましたが処理が終わりませんでした。"
                "アップロード自体は終わっているので、App Store Connect で"
                "処理の終了を確認してから、release ワークフローを"
                "workflow_dispatch で再実行してください。"
            )
        time.sleep(args.interval)


# --- submit ---------------------------------------------------------------


def version_state(version):
    """appStoreState は 3.3 で非推奨。新しい appVersionState を先に見る。"""
    attributes = version["attributes"]
    return attributes.get("appVersionState") or attributes.get("appStoreState")


def find_version(app, version_string):
    found = api(
        "GET",
        f"/v1/apps/{app}/appStoreVersions",
        params={
            "filter[versionString]": version_string,
            "filter[platform]": PLATFORM,
            "limit": 1,
        },
    )["data"]
    return found[0] if found else None


def find_or_create_version(app, version_string, release_type):
    version = find_version(app, version_string)
    if version is not None:
        state = version_state(version)
        if state in LIVE_STATES:
            die(
                f"{version_string} は既に配信済み（{state}）です。"
                " bundle/Info.plist のバージョンを上げてください。"
            )
        log(f"既存のバージョン {version_string} を使います（{state}）。")
        return version["id"]

    log(f"バージョン {version_string} を作ります（releaseType={release_type}）。")
    try:
        created = api(
            "POST",
            "/v1/appStoreVersions",
            body={
                "data": {
                    "type": "appStoreVersions",
                    "attributes": {
                        "platform": PLATFORM,
                        "versionString": version_string,
                        "releaseType": release_type,
                    },
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )
    except ApiError as error:
        # screenshots と submit のジョブが同時に走るため、先に相手が作っていることが
        # ある。その場合は作れないので、もう一度探す。
        if error.status != 409:
            raise
        version = find_version(app, version_string)
        if version is None:
            raise
        log(f"バージョン {version_string} は別の処理が先に作っていました。")
        return version["id"]
    return created["data"]["id"]


def set_whats_new(version_id, notes):
    """「このバージョンでの変更点」を、まだ空のロケールに入れる。

    CHANGELOG は日本語なので、そのまま全ロケールへ入れると英語のページにも
    日本語のリリースノートが出る。App Store Connect で先に書いておいた
    ロケール（英語など）は上書きしない。新しいバージョンは空で作られるため、
    何も書いていなければ従来どおり全ロケールに入る。

    アプリの最初のバージョンには変更点の欄が無く、Apple は 409 を返す。
    それは失敗ではないので警告にとどめる。
    """
    localizations = api(
        "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )["data"]
    for localization in localizations:
        locale = localization["attributes"].get("locale")
        if (localization["attributes"].get("whatsNew") or "").strip():
            log(f"{locale} は App Store Connect で書かれているので、そのままにします。")
            continue
        try:
            api(
                "PATCH",
                f"/v1/appStoreVersionLocalizations/{localization['id']}",
                body={
                    "data": {
                        "type": "appStoreVersionLocalizations",
                        "id": localization["id"],
                        "attributes": {"whatsNew": notes},
                    }
                },
            )
            log(f"リリースノートを入れました（{locale}）。")
        except ApiError as error:
            log(f"warning: {locale} のリリースノートを入れられませんでした: {error}")


def attach_build(version_id, build_id):
    api(
        "PATCH",
        f"/v1/appStoreVersions/{version_id}",
        body={
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
            }
        },
    )
    log("ビルドをバージョンに紐づけました。")


def submit_for_review(app, version_id):
    """審査に出す。

    提出は 3 手に分かれている。提出物の入れ物（reviewSubmissions）を作り、
    そこにバージョンを入れ（reviewSubmissionItems）、最後に submitted=true にする。
    最後の一手を忘れると「作ったのに出ていない」状態になる。
    """
    existing = api(
        "GET",
        "/v1/reviewSubmissions",
        params={"filter[app]": app, "filter[state]": "READY_FOR_REVIEW", "limit": 1},
    )["data"]
    if existing:
        submission_id = existing[0]["id"]
        log("提出前の入れ物が残っていたので、それを使います。")
    else:
        submission_id = api(
            "POST",
            "/v1/reviewSubmissions",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "attributes": {"platform": PLATFORM},
                    "relationships": {"app": {"data": {"type": "apps", "id": app}}},
                }
            },
        )["data"]["id"]

    try:
        api(
            "POST",
            "/v1/reviewSubmissionItems",
            body={
                "data": {
                    "type": "reviewSubmissionItems",
                    "relationships": {
                        "reviewSubmission": {
                            "data": {"type": "reviewSubmissions", "id": submission_id}
                        },
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        },
                    },
                }
            },
        )
    except ApiError as error:
        # 同じバージョンが既に入っている場合は、そのまま提出へ進めばよい。
        # 409 はそれ以外（スクリーンショットの取り込み中、メタデータ不足など
        # 「いまは出せない」状態）でも返るので、本文を見て区別する。
        if error.status != 409 or "already" not in error.detail.lower():
            raise
        log("このバージョンは既に入れ物の中にありました。")

    api(
        "PATCH",
        f"/v1/reviewSubmissions/{submission_id}",
        body={
            "data": {
                "type": "reviewSubmissions",
                "id": submission_id,
                "attributes": {"submitted": True},
            }
        },
    )
    log("審査に提出しました。")


def cmd_submit(args):
    app = app_id()
    version_id = find_or_create_version(app, args.version, args.release_type)
    attach_build(version_id, args.build_id)

    if args.notes_file:
        notes = open(args.notes_file, encoding="utf-8").read().strip()
        if notes:
            set_whats_new(version_id, notes)
        else:
            log("warning: リリースノートが空でした。App Store Connect で入れてください。")

    if args.no_submit:
        log("--no-submit のため、審査には出しません。")
        return
    submit_for_review(app, version_id)


# --- withdraw -------------------------------------------------------------

# 審査に出ていて、Apple の手の中にある状態。この間は版を編集できない。
IN_REVIEW_STATES = {"WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"}


def cmd_withdraw(args):
    """同じ版を出し直すために、審査中の提出を取り下げる。

    取り下げないと、新しいビルドの紐づけもスクリーンショットの差し替えも
    「編集できない状態」で弾かれる。審査に出ていなければ何もしない。
    """
    app = app_id()
    version = find_version(app, args.version)
    if version is None:
        log(f"バージョン {args.version} はまだ無いので、取り下げるものはありません。")
        return
    state = version_state(version)
    if state not in IN_REVIEW_STATES:
        log(f"{args.version} は {state}。審査中ではないので、そのまま進めます。")
        return

    submissions = api(
        "GET",
        "/v1/reviewSubmissions",
        params={"filter[app]": app, "filter[state]": ",".join(sorted(IN_REVIEW_STATES))},
    )["data"]
    if not submissions:
        die(f"{args.version} は {state} ですが、取り下げられる提出物が見つかりません。")
    for submission in submissions:
        api(
            "PATCH",
            f"/v1/reviewSubmissions/{submission['id']}",
            body={
                "data": {
                    "type": "reviewSubmissions",
                    "id": submission["id"],
                    "attributes": {"canceled": True},
                }
            },
        )
        log(f"提出 {submission['id']} を取り下げました。")

    # 取り下げが版に反映されるまで少し待つ。すぐ次へ進むと、まだ審査中の
    # 扱いでビルドの紐づけが弾かれる。
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        state = version_state(find_version(app, args.version))
        if state not in IN_REVIEW_STATES:
            log(f"{args.version} は {state} になりました。")
            return
        time.sleep(10)
    die(f"{args.timeout} 秒待ちましたが {args.version} が審査中のままです。App Store Connect を見てください。")


# --- screenshots ----------------------------------------------------------

# Mac の製品ページの枠。App Store Connect の「Mac」に当たる。
SCREENSHOT_DISPLAY_TYPE = "APP_DESKTOP"

# ロケール -> marketing/screenshots/build の下のフォルダ。
# 英語は地域ごとに別ロケールだが、絵は同じものを入れる。
def screenshot_folder(locale):
    if locale == "ja":
        return "ja"
    if locale.startswith("en"):
        return "en"
    return None


def upload_chunk(operation, data):
    """Apple が指定した URL へ、指定されたヘッダーで 1 片を PUT する。"""
    request = urllib.request.Request(
        operation["url"], data=data, method=operation.get("method", "PUT")
    )
    for header in operation.get("requestHeaders", []):
        request.add_header(header["name"], header["value"])
    try:
        with urllib.request.urlopen(request) as response:
            response.read()
    except urllib.error.HTTPError as error:
        raise ApiError(error.code, error.read().decode(errors="replace")) from None


def screenshot_set(localization_id, locale):
    """そのロケールの Mac 用スクリーンショットの入れ物。無ければ作る。"""
    found = api(
        "GET",
        f"/v1/appStoreVersionLocalizations/{localization_id}/appScreenshotSets",
        params={"filter[screenshotDisplayType]": SCREENSHOT_DISPLAY_TYPE},
    )["data"]
    if found:
        return found[0]["id"]
    log(f"{locale} に Mac のスクリーンショットの枠が無いので作ります。")
    created = api(
        "POST",
        "/v1/appScreenshotSets",
        body={
            "data": {
                "type": "appScreenshotSets",
                "attributes": {"screenshotDisplayType": SCREENSHOT_DISPLAY_TYPE},
                "relationships": {
                    "appStoreVersionLocalization": {
                        "data": {
                            "type": "appStoreVersionLocalizations",
                            "id": localization_id,
                        }
                    }
                },
            }
        },
    )
    return created["data"]["id"]


def upload_screenshot(set_id, path):
    """1 枚を入れる。予約 → 分割アップロード → 確定、の 3 手。"""
    data = open(path, "rb").read()
    reserved = api(
        "POST",
        "/v1/appScreenshots",
        body={
            "data": {
                "type": "appScreenshots",
                "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
                "relationships": {
                    "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}
                },
            }
        },
    )["data"]
    for operation in reserved["attributes"]["uploadOperations"]:
        offset = operation["offset"]
        upload_chunk(operation, data[offset : offset + operation["length"]])
    api(
        "PATCH",
        f"/v1/appScreenshots/{reserved['id']}",
        body={
            "data": {
                "type": "appScreenshots",
                "id": reserved["id"],
                "attributes": {
                    "uploaded": True,
                    "sourceFileChecksum": hashlib.md5(data).hexdigest(),
                },
            }
        },
    )
    return reserved["id"]


def wait_screenshots(screenshot_ids, timeout=600):
    """Apple 側の取り込みが終わるのを待つ。失敗した枚があれば止める。"""
    deadline = time.time() + timeout
    pending = set(screenshot_ids)
    while pending and time.time() < deadline:
        for screenshot_id in list(pending):
            attributes = api("GET", f"/v1/appScreenshots/{screenshot_id}")["data"]["attributes"]
            state = (attributes.get("assetDeliveryState") or {}).get("state")
            if state == "COMPLETE":
                pending.discard(screenshot_id)
            elif state == "FAILED":
                errors = (attributes.get("assetDeliveryState") or {}).get("errors")
                die(f"スクリーンショット {attributes.get('fileName')} の取り込みに失敗しました: {errors}")
        if pending:
            time.sleep(5)
    if pending:
        die(f"{timeout} 秒待ちましたが取り込みが終わりません。App Store Connect を見てください。")


def cmd_screenshots(args):
    app = app_id()
    version_id = find_or_create_version(app, args.version, args.release_type)
    localizations = api(
        "GET", f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations"
    )["data"]
    uploaded = []
    for localization in localizations:
        locale = localization["attributes"].get("locale")
        folder = screenshot_folder(locale)
        if folder is None:
            log(f"{locale} 用の絵は用意していないので、そのままにします。")
            continue
        directory = os.path.join(args.dir, folder)
        files = sorted(
            os.path.join(directory, name)
            for name in os.listdir(directory)
            if name.lower().endswith(".png")
        )
        if not files:
            die(f"{directory} に PNG がありません。先に make screenshots を実行してください。")

        set_id = screenshot_set(localization["id"], locale)
        # 入れ替えなので、先に古いものを全部消す。残すと新旧が混ざって並ぶ。
        existing = api("GET", f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]
        for old in existing:
            api("DELETE", f"/v1/appScreenshots/{old['id']}")
        log(f"{locale}: 古い {len(existing)} 枚を消し、{len(files)} 枚を入れます。")

        ids = [upload_screenshot(set_id, path) for path in files]
        # 並び順はファイル名の番号順（build/ の中と同じ）。
        api(
            "PATCH",
            f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
            body={"data": [{"type": "appScreenshots", "id": i} for i in ids]},
        )
        uploaded.extend(ids)
        log(f"{locale}: 入れました。")

    wait_screenshots(uploaded)
    log(f"スクリーンショットを差し替えました（{len(uploaded)} 枚）。")


# --- state ----------------------------------------------------------------


def cmd_state(args):
    version = find_version(app_id(), args.version)
    if version is None:
        die(f"バージョン {args.version} は App Store Connect にありません。")
    state = version_state(version)
    print(state)
    if args.require_live and state not in LIVE_STATES:
        hint = (
            "人の操作を待っています。App Store Connect を見てください。"
            if state in STUCK_STATES
            else "まだ配信前です。"
        )
        log(f"{args.version} は {state}。{hint}")
        sys.exit(2)


# --- entry ----------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    wait = sub.add_parser("wait-build", help="ビルドの処理が終わるのを待つ")
    wait.add_argument("--version", required=True, help="表示用バージョン（0.1.0 など）")
    wait.add_argument("--build", required=True, help="ビルド番号（CFBundleVersion）")
    wait.add_argument("--timeout", type=int, default=3600)
    wait.add_argument("--interval", type=int, default=60)
    wait.set_defaults(func=cmd_wait_build)

    submit = sub.add_parser("submit", help="ビルドを紐づけて審査に出す")
    submit.add_argument("--version", required=True)
    submit.add_argument("--build-id", required=True)
    submit.add_argument("--notes-file")
    submit.add_argument("--release-type", default="AFTER_APPROVAL")
    submit.add_argument(
        "--no-submit",
        action="store_true",
        help="バージョンの用意までで止める（審査には出さない）",
    )
    submit.set_defaults(func=cmd_submit)

    withdraw = sub.add_parser("withdraw", help="審査中の提出を取り下げる（同じ版の出し直し用）")
    withdraw.add_argument("--version", required=True)
    withdraw.add_argument("--timeout", type=int, default=300)
    withdraw.set_defaults(func=cmd_withdraw)

    shots = sub.add_parser("screenshots", help="製品ページのスクリーンショットを差し替える")
    shots.add_argument("--version", required=True)
    shots.add_argument(
        "--dir",
        default="marketing/screenshots/build",
        help="make screenshots の出力先（<dir>/ja, <dir>/en の PNG を使う）",
    )
    shots.add_argument("--release-type", default="AFTER_APPROVAL")
    shots.set_defaults(func=cmd_screenshots)

    state = sub.add_parser("state", help="バージョンの状態を表示する")
    state.add_argument("--version", required=True)
    state.add_argument(
        "--require-live",
        action="store_true",
        help="配信中でなければ終了コード 2 で終わる",
    )
    state.set_defaults(func=cmd_state)

    args = parser.parse_args()
    try:
        args.func(args)
    except ApiError as error:
        die(str(error))


if __name__ == "__main__":
    main()
