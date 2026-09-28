#!/usr/bin/env bash
# API 키 교체: 새 키 등록 → 업스트림 실물 검증 → 나머지 계정 비활성화
#             → models.yml kiro 블록·프리셋 재생성 → 호출 검증
#
# 키를 폐기·재발급했거나, kiro-go 가 기존 키를 "token invalid or expired" 로 막았을 때 쓴다.
# 키는 stdin 으로만 받는다(셸 히스토리·ps 노출 없음).
#   ./kiro-rekey.sh            # 프롬프트에 붙여넣기
#   printf '%s' "$KEY" | ./kiro-rekey.sh
#
# 업스트림이 계정을 정지("unusual user activity")했다면 이 스크립트의 대상이 아니다.
# README 6절을 보십시오.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export KIRO_GO_BASE="${KIRO_GO_BASE:-http://127.0.0.1:8317}"
export KIRO_GO_PWFILE="${KIRO_GO_PWFILE:-/root/kiro-go/admin-password.txt}"
export KIRO_GO_ADMIN_PASSWORD="${KIRO_GO_ADMIN_PASSWORD:-$(cat "$KIRO_GO_PWFILE")}"
BASE="$KIRO_GO_BASE"
PW="$KIRO_GO_ADMIN_PASSWORD"
MODELS_YML="${MODELS_YML:-$HOME/.gjc/agent/models.yml}"
NICK="${KIRO_NICK:-kiro-key}"
VERIFY_MODEL="${KIRO_VERIFY_MODEL:-kiro/claude-sonnet-4.5}"

api() { # api <METHOD> <PATH> [JSON_BODY]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BASE/admin/api$p" -H "X-Admin-Password: $PW" \
      -H 'Content-Type: application/json' -d "$b"
  else
    curl -sS -X "$m" "$BASE/admin/api$p" -H "X-Admin-Password: $PW"
  fi
}

curl -sS -m 5 "$BASE/admin" >/dev/null || { echo "kiro-go 가 $BASE 에 없습니다." >&2; exit 1; }

if [ -t 0 ]; then
  read -rsp "  Kiro API 키(ksk_...)를 붙여넣고 Enter: " KEY; echo
else
  IFS= read -r KEY || true
fi
[ -n "${KEY:-}" ] || { echo "키가 비어 있습니다." >&2; exit 1; }
case "$KEY" in ksk_*) ;; *) echo "ksk_ 로 시작하지 않습니다." >&2; exit 1 ;; esac

echo "== 1) 키 등록"
# kiro-go 계약: 필드명은 kiroApiKey, 리전은 "<key>|<region>" 으로 붙인다.
case "$KEY" in *'|'*) ;; *) KEY="$KEY|${KIRO_REGION:-us-east-1}" ;; esac
body="$(KEY="$KEY" NICK="$NICK" python3 -c 'import json,os;print(json.dumps({"kiroApiKey":os.environ["KEY"],"authMethod":"api_key","nickname":os.environ["NICK"]}))')"
resp="$(api POST /auth/credentials "$body")"
unset KEY body
KEEP_ID="$(printf '%s' "$resp" | python3 -c 'import json, sys
d = json.load(sys.stdin)
if not d.get("success"): sys.exit("등록 실패: %s" % d.get("error", d))
print(d.get("account", {}).get("id", ""))')"
[ -n "$KEEP_ID" ] || { echo "등록 응답에 account.id 가 없습니다. 관리 화면에서 확인하십시오." >&2; exit 1; }
echo "  등록 계정 id=$KEEP_ID"

echo "== 2) 키 실물 검증 (등록 단계는 키를 검사하지 않는다 — 업스트림에 직접 묻는다)"
if ! api POST "/accounts/$KEEP_ID/models/refresh" '{}' | python3 -c 'import json, sys
d = json.load(sys.stdin)
if not d.get("success"): sys.exit("업스트림이 키를 거부했습니다: %s" % d.get("error", d))
print("  부여 모델 %s개" % d.get("count"))'; then
  echo "  등록한 계정을 삭제합니다(풀 오염 방지)." >&2
  api DELETE "/accounts/$KEEP_ID" >/dev/null || true
  exit 1
fi

echo "== 3) 새 계정 외 전부 비활성화 (무료·무효 계정이 라운드로빈에 섞이지 않게)"
KEEP_ID="$KEEP_ID" python3 - <<'PY'
import json, os, urllib.request

base = os.environ["KIRO_GO_BASE"]
pw = os.environ["KIRO_GO_ADMIN_PASSWORD"]
keep = os.environ["KEEP_ID"]


def call(path, method="GET", payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + "/admin/api" + path, data=data, method=method,
                                 headers={"X-Admin-Password": pw, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


rows = call("/accounts")
rows = rows if isinstance(rows, list) else rows.get("accounts", rows.get("data", []))
for a in rows:
    if a["id"] == keep or not a.get("enabled"):
        continue
    try:
        call("/accounts/%s" % a["id"], "PUT", {"enabled": False})
        print("  비활성화", a.get("email") or a.get("nickname") or a["id"], a.get("authMethod"))
    except Exception as exc:
        print("  비활성화 실패", a["id"], exc)
PY

echo "== 4) 상태"
"$HERE/kiro-login.sh" status

echo "== 5) models.yml kiro 블록 재생성 (업스트림 부여 모델만)"
python3 "$HERE/gen_kiro_models.py" --apply "$MODELS_YML"

echo "== 6) 프리셋·equivalence 재적용"
python3 "$HERE/restore_profiles.py" "$MODELS_YML"

echo "== 7) 호출 검증 ($VERIFY_MODEL)"
if command -v gjc >/dev/null; then
  gjc -p "reply with exactly: OK" --model "$VERIFY_MODEL"
else
  echo "  gjc 가 PATH 에 없어 건너뜁니다."
fi
