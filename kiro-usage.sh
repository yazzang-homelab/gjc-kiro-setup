#!/usr/bin/env bash
# 활성 kiro-go 계정의 구독 등급·크레딧·리셋일을 업스트림에서 새로 읽고,
# 모델별 rateMultiplier 와 그 배수로 환산한 잔여 호출 하한을 출력한다.
# 크레딧 숫자만으로는 판단이 안 된다 — 모델 간 배수가 40배 넘게 차이 나기 때문이다.
#
# 비활성(정지·키 무효) 계정도 사유와 함께 한 줄씩 보여 준다.
set -euo pipefail

export KIRO_GO_BASE="${KIRO_GO_BASE:-http://127.0.0.1:8317}"
export KIRO_GO_PWFILE="${KIRO_GO_PWFILE:-/root/kiro-go/admin-password.txt}"

python3 - <<'PY'
import json, os, sys, time, urllib.error, urllib.request

base = os.environ["KIRO_GO_BASE"]
pw = os.environ.get("KIRO_GO_ADMIN_PASSWORD") or open(os.environ["KIRO_GO_PWFILE"]).read().strip()


def call(path, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + "/admin/api" + path, data=data, method=method,
                                 headers={"X-Admin-Password": pw, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
    except urllib.error.HTTPError as exc:
        sys.exit("관리 API %s 실패: HTTP %s %r" % (path, exc.code, exc.read()[:200]))
    except urllib.error.URLError as exc:
        sys.exit("kiro-go 에 연결하지 못했습니다 (%s): %s" % (base, exc.reason))
    return json.loads(raw) if raw else {}


def label(acc):
    return acc.get("email") or acc.get("nickname") or acc["id"]


rows = call("/accounts")
rows = rows if isinstance(rows, list) else rows.get("accounts", rows.get("data", []))

for acc in rows:
    if acc.get("enabled"):
        continue
    reason = acc.get("banReason") or "수동 비활성화"
    when = acc.get("banTime")
    stamp = time.strftime(" (%Y-%m-%d %H:%M UTC)", time.gmtime(when)) if when else ""
    print("-- %s [%s] 비활성: %s%s" % (label(acc), acc.get("subscriptionType") or "?", reason, stamp))

active = [a for a in rows if a.get("enabled")]
if not active:
    sys.exit("활성 kiro 계정이 없습니다.")

for acc in active:
    aid = acc["id"]
    # 업스트림에서 새로 읽는다(config 의 캐시값은 오래됐을 수 있다).
    usage = (call("/accounts/%s/refresh" % aid, "POST", {}) or {}).get("usage") or {}
    over = call("/accounts/%s/overage" % aid)
    full = call("/accounts/%s/full" % aid)

    def g(*names, default=0):
        for n in names:
            for src in (usage, over, full):
                if n in src and src[n] not in (None, ""):
                    return src[n]
        return default

    cur = g("UsageCurrent", "usageCurrent")
    lim = g("UsageLimit", "usageLimit")
    left = max(lim - cur, 0)
    reset = g("NextResetDate", "nextResetDate", default="?")
    tier = over.get("subscriptionTitle") or full.get("subscriptionTitle") or "?"

    days = ""
    if reset != "?":
        try:
            secs = time.mktime(time.strptime(reset, "%Y-%m-%d")) - time.time()
            days = "  (D-%.1f일)" % (secs / 86400)
        except ValueError:
            pass

    print("== %s  [%s]" % (full.get("email") or label(acc), tier))
    print("   크레딧 %s / %s  (잔여 %s)   리셋 %s%s" % (cur, lim, left, reset, days))
    print("   오버리지 %s  cap %s  rate $%s/건"
          % (over.get("overageStatus", "?"), over.get("overageCap", "?"), over.get("overageRate", "?")))

    models = (call("/accounts/%s/models" % aid) or {}).get("models") or []
    rated = sorted(((m.get("rateMultiplier") or 0, m["modelId"]) for m in models), reverse=True)
    if not rated:
        print("   (모델 목록 비어 있음 — 인증 상태 확인)")
        continue
    # 실제 차감량은 업스트림 스트림의 meteringEvent.usage 이고(proxy/kiro.go),
    # 배수는 모델 간 상대 가격이다. 아래 호출 수는 "1호출 = 배수만큼 차감"을 가정한
    # 하한이며 실측 차감은 이보다 작았다(README 5절).
    print("   %-22s %6s  %14s" % ("모델", "배수", "잔여 호출(하한)"))
    for rate, mid in rated:
        calls = "제한없음" if not rate else "%d" % (left / rate)
        print("   %-22s %6s  %14s" % (mid, rate, calls))
    print()
PY
