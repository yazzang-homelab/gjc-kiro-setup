#!/usr/bin/env bash
# kiro-go 계정 등록 헬퍼. 브라우저가 없는 호스트에서도 셸만으로 계정을 연결한다.
#
# AWS Builder ID 는 OAuth 디바이스 코드 방식이므로 인증 페이지는 다른 기기에서 열어도 된다.
# 유료 구독(Kiro Pro / Pro+ / Power)은 app.kiro.dev 계정에 귀속되므로 API 키 방식을 사용한다.
set -euo pipefail

BASE="${KIRO_GO_BASE:-http://127.0.0.1:8317}"
PWFILE="${KIRO_GO_PWFILE:-/root/kiro-go/admin-password.txt}"
PW="${KIRO_GO_ADMIN_PASSWORD:-$(cat "$PWFILE")}"

api() { # api <METHOD> <PATH> [JSON_BODY]
  local m="$1" p="$2" b="${3:-}"
  if [ -n "$b" ]; then
    curl -sS -X "$m" "$BASE/admin/api$p" \
      -H "X-Admin-Password: $PW" -H 'Content-Type: application/json' -d "$b"
  else
    curl -sS -X "$m" "$BASE/admin/api$p" -H "X-Admin-Password: $PW"
  fi
}

jget() {
  python3 -c 'import sys,json;d=json.load(sys.stdin);v=d.get(sys.argv[1]);print(json.dumps(v) if isinstance(v,(dict,list)) else (v or ""))' "$1"
}

cmd_builderid() {
  local region="${1:-us-east-1}"
  local start; start="$(api POST /auth/builderid/start "{\"region\":\"$region\"}")"
  local sid url code
  sid="$(printf '%s' "$start" | jget sessionId)"
  url="$(printf '%s' "$start" | jget verificationUriComplete)"
  code="$(printf '%s' "$start" | jget userCode)"
  [ -n "$sid" ] || { echo "세션 시작에 실패했습니다: $start" >&2; exit 1; }

  echo
  echo "  아래 주소를 아무 기기의 브라우저에서 여십시오."
  echo "    $url"
  echo "  표시되는 코드: $code"
  echo
  echo "  승인 대기 중..."

  local i out status
  for i in $(seq 1 120); do
    sleep 5
    out="$(api POST /auth/builderid/poll "{\"sessionId\":\"$sid\"}")"
    status="$(printf '%s' "$out" | jget status)"
    case "$status" in
      complete|success) echo "  연결되었습니다."; printf '%s\n' "$out" | python3 -m json.tool; return 0 ;;
      pending|authorization_pending|"") printf '.' ;;
      *) echo; echo "  실패: $out" >&2; exit 1 ;;
    esac
  done
  echo; echo "  시간이 초과되었습니다." >&2; exit 1
}

cmd_apikey() {
  # 키를 stdin 으로만 받는다. 셸 히스토리와 프로세스 목록에 남지 않는다.
  local key
  read -rsp "  Kiro API 키(ksk_...)를 붙여넣고 Enter: " key; echo
  [ -n "$key" ] || { echo "  키가 비어 있습니다." >&2; exit 1; }
  case "$key" in *'|'*) ;; *) key="$key|us-east-1";; esac
  local body
  body="$(KEY="$key" python3 -c 'import json,os;print(json.dumps({"kiroApiKey":os.environ["KEY"],"authMethod":"api_key","nickname":"kiro-key"}))')"
  api POST /auth/credentials "$body" | python3 -m json.tool
}

cmd_disable() {
  local id="${1:?계정 ID를 지정하십시오}"
  api PUT "/accounts/$id" '{"enabled":false}' | python3 -m json.tool
}

cmd_status() {
  echo "== 계정 =="
  api GET /accounts | python3 -c '
import sys, json
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("accounts", d.get("data", []))
if not rows:
    print("  (없음)"); raise SystemExit
for a in rows:
    print("  %-24s %-10s %-10s enabled=%-5s id=%s" % (
        a.get("email") or a.get("nickname") or "-",
        a.get("provider") or a.get("authMethod"),
        a.get("region"), a.get("enabled"), a.get("id")))'
  echo "== 구독 등급 및 부여 모델 =="
  api GET /accounts | python3 -c '
import sys, json, urllib.request, os
base = os.environ["BASE"]; pw = os.environ["PW"]
d = json.load(sys.stdin)
rows = d if isinstance(d, list) else d.get("accounts", d.get("data", []))
for a in rows:
    if not a.get("enabled"):
        continue
    req = urllib.request.Request(base + "/admin/api/accounts/" + a["id"] + "/models",
                                 headers={"X-Admin-Password": pw})
    try:
        ms = json.load(urllib.request.urlopen(req, timeout=20)).get("models") or []
    except Exception as exc:
        print("  %s: 조회 실패 %s" % (a.get("email"), exc)); continue
    print("  %s -> %d 종" % (a.get("email") or a.get("nickname"), len(ms)))
    for m in ms:
        t = m.get("tokenLimits") or {}
        print("    %-22s rate=%-5s ctx=%s" % (m["modelId"], m.get("rateMultiplier"), t.get("maxInputTokens")))'
}

export BASE PW

case "${1:-}" in
  builderid) shift; cmd_builderid "$@" ;;
  apikey)    cmd_apikey ;;
  disable)   shift; cmd_disable "$@" ;;
  status)    cmd_status ;;
  *) cat <<EOF
사용법: $0 <명령>

  builderid [리전]   AWS Builder ID 디바이스 코드 로그인 (기본 us-east-1, 무료 등급)
  apikey             app.kiro.dev 에서 발급한 API 키(ksk_...) 등록 (유료 구독 반영)
  disable <계정ID>   계정을 라운드로빈 풀에서 제외
  status             연결된 계정과 업스트림 부여 모델 목록 출력
EOF
    exit 2 ;;
esac
