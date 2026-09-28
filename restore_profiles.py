#!/usr/bin/env python3
"""models.yml 에 kiro 프리셋과 equivalence 예외를 다시 쓴다.

gen_kiro_models.py 가 `providers.kiro` 블록을 업스트림 부여 모델로 새로 만든 뒤
실행한다. 구독 등급이 바뀌면 부여 모델 집합이 달라지므로, 없는 모델을 가리키는
프리셋이 남아 있으면 GJC 가 그 프리셋을 고르는 순간 실패한다.

- 프리셋은 `providers.kiro` 에 실제로 등록된 모델만 참조하는 것만 넣는다.
  미부여 모델을 가리키는 프리셋은 건너뛰고 이유를 출력한다.
- kiro 외 프로바이더를 섞는 프리셋은 그 프로바이더가 models.yml 에 정의돼 있을 때만 넣는다.
- `equivalence.exclude` 에서 `kiro/` 항목만 다시 만든다. 다른 항목은 보존한다.
- 몇 번 실행해도 결과가 같다(이 스크립트가 관리하는 프리셋만 걷어내고 다시 쓴다).

사용법:
    python3 restore_profiles.py ~/.gjc/agent/models.yml
"""

from __future__ import annotations

import os
import re
import shutil
import sys
import time

# 값이 dict 면 kiro 전용(required_providers: [kiro])이고, "providers"/"mapping" 을 가진
# dict 면 혼합 프리셋이다. kiro/ 로 시작하는 참조만 부여 여부를 검사한다.
PROFILES: dict[str, dict] = {
    # 상시 기본: 판단 레인은 상위 모델.
    "kiro": {
        "default": "kiro/claude-opus-5:medium",
        "executor": "kiro/claude-opus-5:high",
        "planner": "kiro/gpt-5.6-sol:high",
        "architect": "kiro/claude-opus-4.8:high",
        "critic": "kiro/gpt-5.6-terra:high",
    },
    # 판단은 상위 모델, 토큰을 가장 많이 쓰는 executor 는 최저 배수 모델.
    "kiro-mixed": {
        "default": "kiro/claude-opus-5:medium",
        "executor": "kiro/qwen3-coder-next",
        "planner": "kiro/deepseek-3.2:high",
        "architect": "kiro/glm-5:high",
        "critic": "kiro/claude-opus-5:high",
    },
    # 크레딧 절약: 전 레인 저배수 모델.
    "kiro-thrift": {
        "default": "kiro/qwen3-coder-next",
        "executor": "kiro/qwen3-coder-next",
        "planner": "kiro/deepseek-3.2:high",
        "architect": "kiro/glm-5:high",
        "critic": "kiro/minimax-m2.1",
    },
    # 중배수 모델 위주. 상위 등급의 잔여 크레딧을 무난하게 쓸 때.
    "kiro-burn": {
        "default": "kiro/claude-sonnet-5:medium",
        "executor": "kiro/claude-sonnet-4.5:high",
        "planner": "kiro/gpt-5.6-terra:high",
        "architect": "kiro/claude-haiku-4.5",
        "critic": "kiro/gpt-5.6-luna:high",
    },
    # 월말: 곧 소멸할 크레딧으로 평소 아끼던 상위 레인을 연다.
    "kiro-monthend": {
        "default": "kiro/claude-opus-5:high",
        "executor": "kiro/claude-opus-5:high",
        "planner": "kiro/gpt-5.6-sol:high",
        "architect": "kiro/claude-opus-5:high",
        "critic": "kiro/claude-opus-4.8:high",
    },
    # 최대 강도. 상위 배수(>= 2.0) 모델만 xhigh 를 노출하므로 그 모델만 쓴다.
    "kiro-xhigh": {
        "default": "kiro/claude-opus-5:xhigh",
        "executor": "kiro/claude-opus-5:xhigh",
        "planner": "kiro/gpt-5.6-sol:xhigh",
        "architect": "kiro/claude-opus-4.8:xhigh",
        "critic": "kiro/claude-opus-4.7:xhigh",
    },
    # 혼합 예시: 본 대화(default)만 kiro 로 받고, 토큰을 태우는 서브에이전트 4레인은
    # 다른 구독 프로바이더로 돌린다. 실측상 위임 1건 크레딧이 절반 수준이다(README 5절).
    # 아래 프로바이더 이름은 예시다. models.yml 에 없으면 이 프리셋은 건너뛴다.
    "kiro-luna": {
        "providers": ["kiro", "codex-1", "codex-2"],
        "mapping": {
            "default": "kiro/claude-opus-5:medium",
            "executor": "codex-1/gpt-5.6-luna:max",
            "planner": "codex-2/gpt-5.6-luna:max",
            "architect": "codex-2/gpt-5.6-luna:max",
            "critic": "codex-1/gpt-5.6-luna:max",
        },
    },
}

ROLES = ("default", "executor", "planner", "architect", "critic")

TOP = re.compile(r"^\S")
PROVIDER_KEY = re.compile(r"^  ([A-Za-z0-9._-]+):\s*$")
# GJC 가 models.yml 을 다시 쓰면 목록 들여쓰기가 바뀐다(`      - id:` ↔ `    - id:`).
MODEL_ID = re.compile(r"^\s+-\s+id:\s*(\S+)\s*$")
KIRO_EXCLUDE = re.compile(r"^\s*-\s*kiro/")


def section(lines: list[str], name: str) -> tuple[int, int] | None:
    """최상위 키 `name:` 의 [시작, 끝) 줄 범위."""
    start = None
    for i, line in enumerate(lines):
        if start is None:
            if re.match(rf"^{re.escape(name)}:\s*$", line):
                start = i
        elif TOP.match(line):
            return start, i
    return (start, len(lines)) if start is not None else None


def provider_names(lines: list[str]) -> set[str]:
    span = section(lines, "providers")
    if span is None:
        return set()
    return {m.group(1) for line in lines[span[0] + 1:span[1]] if (m := PROVIDER_KEY.match(line))}


def kiro_models(lines: list[str]) -> list[str]:
    """providers.kiro 블록에 등록된 모델 id (등록 순서 유지)."""
    span = section(lines, "providers")
    if span is None:
        return []
    out: list[str] = []
    inside = False
    for line in lines[span[0] + 1:span[1]]:
        key = PROVIDER_KEY.match(line)
        if key:
            inside = key.group(1) == "kiro"
            continue
        if inside and (m := MODEL_ID.match(line)):
            out.append(m.group(1))
    return out


def spec(name: str) -> tuple[list[str], dict[str, str]]:
    raw = PROFILES[name]
    if "mapping" in raw:
        return list(raw["providers"]), dict(raw["mapping"])
    return ["kiro"], dict(raw)


def build_profiles(available: set[str], providers: set[str]) -> tuple[list[str], list[str], list[str]]:
    blocks: list[str] = []
    kept: list[str] = []
    notes: list[str] = []
    for name in PROFILES:
        required, mapping = spec(name)
        absent = sorted(p for p in required if p not in providers)
        if absent:
            notes.append(f"건너뜀 {name}: 정의되지 않은 프로바이더 {', '.join(absent)}")
            continue
        referenced = {
            v.split("/", 1)[1].split(":", 1)[0] for v in mapping.values() if v.startswith("kiro/")
        }
        missing = sorted(referenced - available)
        if missing:
            notes.append(f"건너뜀 {name}: 미부여 모델 {', '.join(missing)}")
            continue
        kept.append(name)
        blocks.append(f"  {name}:")
        blocks.append("    required_providers:")
        blocks.extend(f"    - {p}" for p in required)
        blocks.append(f"    display_name: {name}")
        blocks.append("    model_mapping:")
        blocks.extend(f"      {role}: {mapping[role]}" for role in ROLES)
    return blocks, kept, notes


def rewrite_profiles(lines: list[str], blocks: list[str]) -> list[str]:
    """profiles 섹션에서 이 스크립트가 관리하는 프리셋만 걷어내고 섹션 끝에 다시 쓴다."""
    span = section(lines, "profiles")
    if span is None:
        return lines + ["profiles:"] + blocks
    start, end = span
    body: list[str] = []
    skipping = False
    for line in lines[start + 1:end]:
        key = PROVIDER_KEY.match(line)
        if key:
            skipping = key.group(1) in PROFILES
        if not skipping:
            body.append(line)
    return lines[:start + 1] + body + blocks + lines[end:]


def rewrite_equivalence(lines: list[str], model_ids: list[str]) -> list[str]:
    """equivalence.exclude 의 kiro/ 항목만 교체한다. 다른 키와 항목은 그대로 둔다."""
    fresh = [f"  - kiro/{m}" for m in model_ids]
    span = section(lines, "equivalence")
    if span is None:
        return lines + ["equivalence:", "  exclude:"] + fresh
    start, end = span
    body = lines[start + 1:end]
    at = next((i for i, line in enumerate(body) if re.match(r"^  exclude:\s*$", line)), None)
    if at is None:
        return lines[:start + 1] + ["  exclude:"] + fresh + body + lines[end:]
    # 목록 항목은 `  - x` 처럼 exclude 와 같은 들여쓰기일 수 있으므로 `-` 는 다음 키로 보지 않는다.
    stop = next((i for i in range(at + 1, len(body)) if re.match(r"^ {0,2}[^\s-]", body[i])), len(body))
    kept = [line for line in body[at + 1:stop] if not KIRO_EXCLUDE.match(line)]
    body = body[:at + 1] + kept + fresh + body[stop:]
    return lines[:start + 1] + body + lines[end:]


def main() -> None:
    path = os.path.expanduser(sys.argv[1] if len(sys.argv) > 1 else "~/.gjc/agent/models.yml")
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    model_ids = kiro_models(lines)
    if not model_ids:
        sys.exit("providers.kiro 블록이 없습니다. gen_kiro_models.py --apply 를 먼저 실행하십시오.")

    blocks, kept, notes = build_profiles(set(model_ids), provider_names(lines))
    new = rewrite_equivalence(rewrite_profiles(lines, blocks), model_ids)

    backup = f"{path}.bak-{time.strftime('%Y%m%d-%H%M%S')}-kiroprofiles"
    shutil.copy2(path, backup)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(new) + "\n")

    print(f"백업 생성: {backup}")
    print("복원한 프리셋:", ", ".join(kept) or "(없음)")
    for note in notes:
        print(note)


if __name__ == "__main__":
    main()
