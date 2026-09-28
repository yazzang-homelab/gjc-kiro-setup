#!/usr/bin/env bash
# 구독 등급을 바꿨을 때(예: Pro+ → Power) 실행한다.
# 업스트림 부여 모델 집합이 바뀌므로 models.yml 의 kiro 블록과 프리셋을 다시 만든다.
# API 키는 등급 변경 후에도 그대로 유효하다 — 재등록할 필요가 없다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${KIRO_GO_BASE:-http://127.0.0.1:8317}"
PWFILE="${KIRO_GO_PWFILE:-/root/kiro-go/admin-password.txt}"
PW="${KIRO_GO_ADMIN_PASSWORD:-$(cat "$PWFILE")}"
MODELS_YML="${MODELS_YML:-$HOME/.gjc/agent/models.yml}"

curl -sS -m 5 "$BASE/admin" >/dev/null || { echo "kiro-go 가 $BASE 에 없습니다." >&2; exit 1; }

echo "== 1) 업스트림 모델 재조회"
ids="$(curl -sS "$BASE/admin/api/accounts" -H "X-Admin-Password: $PW" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
rows = rows if isinstance(rows, list) else rows.get("accounts", rows.get("data", []))
print("\n".join(a["id"] for a in rows if a.get("enabled")))')"
[ -n "$ids" ] || { echo "활성 계정이 없습니다." >&2; exit 1; }
for id in $ids; do
  curl -sS -X POST "$BASE/admin/api/accounts/$id/models/refresh" \
    -H "X-Admin-Password: $PW" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json, sys
d = json.load(sys.stdin)
if not d.get("success"): sys.exit("모델 재조회 실패: %s" % d.get("error", d))
print("  부여 모델 %s개" % d.get("count"))'
done

echo "== 2) models.yml kiro 블록 재생성"
python3 "$HERE/gen_kiro_models.py" --apply "$MODELS_YML"

echo "== 3) 프리셋·equivalence 재적용 (미부여 모델을 참조하는 프리셋은 제외)"
python3 "$HERE/restore_profiles.py" "$MODELS_YML"

echo "== 4) 등급·잔여"
"$HERE/kiro-usage.sh"
