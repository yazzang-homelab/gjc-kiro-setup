#!/usr/bin/env python3
"""kiro-go 가 실제로 부여받은 모델 목록을 읽어 GJC models.yml 의 kiro 프로바이더
블록을 생성한다.

하드코딩된 모델 목록을 쓰지 않는다. kiro-go 관리 API 로 업스트림
ListAvailableModels 결과를 그대로 받아 YAML 로 옮기므로, 구독 등급이 바뀌면
다시 실행하는 것만으로 설정이 따라온다.

사용법:
    python3 gen_kiro_models.py --print
    python3 gen_kiro_models.py --apply ~/.gjc/agent/models.yml
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("KIRO_GO_BASE", "http://127.0.0.1:8317")
PWFILE = os.environ.get("KIRO_GO_PWFILE", "/root/kiro-go/admin-password.txt")

# 추론 강도(effort)를 노출할 모델. 나머지는 단일 강도로 등록한다.
REASONING = ("claude-opus", "claude-sonnet", "gpt-5", "deepseek", "glm")

# GJC 가 kiro 프로바이더에 붙이는 표시 접두사.
LABEL = "【Kiro】"

BLOCK_START = re.compile(r"^  kiro:\s*$")
NEXT_TOP = re.compile(r"^(\S|  [a-z0-9-]+:)")


def admin_password() -> str:
    env = os.environ.get("KIRO_GO_ADMIN_PASSWORD")
    if env:
        return env.strip()
    try:
        with open(PWFILE, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError as exc:
        sys.exit(f"관리자 비밀번호를 읽지 못했습니다: {exc}")


def api(path: str) -> dict:
    req = urllib.request.Request(
        f"{BASE}/admin/api{path}",
        headers={"X-Admin-Password": admin_password()},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"관리 API 호출 실패 {path}: HTTP {exc.code} {exc.read()[:200]!r}")
    except urllib.error.URLError as exc:
        sys.exit(f"kiro-go 에 연결하지 못했습니다 ({BASE}): {exc.reason}")


def active_account() -> dict:
    payload = api("/accounts")
    rows = payload if isinstance(payload, list) else payload.get("accounts") or payload.get("data") or []
    enabled = [a for a in rows if a.get("enabled")]
    if not enabled:
        sys.exit("활성화된 kiro-go 계정이 없습니다. 먼저 계정을 등록하십시오.")
    # 등급이 가장 높은 계정을 고르기 위해 모델 수가 가장 많은 계정을 선택한다.
    best, best_models = None, []
    for acc in enabled:
        models = api(f"/accounts/{acc['id']}/models").get("models") or []
        if len(models) > len(best_models):
            best, best_models = acc, models
    if not best_models:
        sys.exit("업스트림 모델 목록이 비어 있습니다. 계정 인증 상태를 확인하십시오.")
    return {"account": best, "models": best_models}


def is_reasoning(model_id: str) -> bool:
    return any(model_id.startswith(p) for p in REASONING)


def emit(models: list[dict]) -> str:
    out: list[str] = []
    add = out.append
    add("  kiro: ")
    add(f"    baseUrl: {BASE}/v1")
    add("    apiKey: kiro-local")
    add("    api: anthropic-messages")
    add("    disableStrictTools: true")
    add("    cacheRetention: short")
    add("    models: ")
    for m in models:
        mid = m["modelId"]
        limits = m.get("tokenLimits") or {}
        ctx = limits.get("maxInputTokens") or 200000
        out_tokens = limits.get("maxOutputTokens") or 32000
        inputs = [t.lower() for t in (m.get("supportedInputTypes") or ["TEXT"])]
        name = m.get("modelName") or mid
        rate = m.get("rateMultiplier")

        add(f"      - id: {mid}")
        add(f"        name: {LABEL} {name} · kiro (rate {rate})")
        if is_reasoning(mid):
            # 상위 배수 모델은 최대 강도까지 노출한다. 소진 및 고난도 레인이 쓴다.
            levels = ("low", "medium", "high", "xhigh") if (rate or 0) >= 2.0 \
                else ("low", "medium", "high")
            add("        reasoning: true")
            add("        thinking: ")
            add(f"          minLevel: {levels[0]}")
            add(f"          maxLevel: {levels[-1]}")
            add("          mode: effort")
            add("          defaultLevel: medium")
            add("          levels: ")
            for lvl in levels:
                add(f"            - {lvl}")
        else:
            add("        reasoning: false")
        add("        input: ")
        for t in inputs:
            add(f"          - {t}")
        # kiro-go 는 구독 크레딧으로 과금되므로 토큰 단가는 0 으로 둔다.
        add("        cost: ")
        for field in ("input", "output", "cacheRead", "cacheWrite"):
            add(f"          {field}: 0")
        add(f"        contextWindow: {ctx}")
        add(f"        maxTokens: {out_tokens}")
    return "\n".join(out) + "\n"


def apply(path: str, block: str) -> None:
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()

    start = None
    for i, line in enumerate(lines):
        if BLOCK_START.match(line.rstrip("\n")):
            start = i
            break
    if start is None:
        sys.exit(f"{path} 에서 '  kiro:' 블록을 찾지 못했습니다.")

    end = len(lines)
    for j in range(start + 1, len(lines)):
        if NEXT_TOP.match(lines[j]):
            end = j
            break

    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}-genkiro"
    shutil.copy2(path, backup)

    lines[start:end] = [block]
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)

    print(f"적용 완료: {path}")
    print(f"백업 생성: {backup}")


def main() -> None:
    ap = argparse.ArgumentParser(description="GJC models.yml 의 kiro 블록 생성기")
    ap.add_argument("--print", dest="show", action="store_true", help="생성 결과를 출력만 한다")
    ap.add_argument("--apply", metavar="MODELS_YML", help="models.yml 에 kiro 블록을 덮어쓴다")
    args = ap.parse_args()

    if not args.show and not args.apply:
        ap.error("--print 또는 --apply 중 하나를 지정하십시오.")

    found = active_account()
    models = found["models"]
    acc = found["account"]
    label = acc.get("email") or acc.get("nickname") or acc.get("id")
    print(f"계정 {label} 에서 모델 {len(models)} 종을 확인했습니다.", file=sys.stderr)

    block = emit(models)
    if args.show:
        print(block, end="")
    if args.apply:
        apply(os.path.expanduser(args.apply), block)


if __name__ == "__main__":
    main()
