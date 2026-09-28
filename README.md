# GJC + Kiro 연동 가이드

유료 Kiro 구독(Pro / Pro+ / Power)을 [kiro-go](https://github.com/Quorinex/Kiro-Go) 프록시에 연결하고,
[Gajae Code(GJC)](https://github.com/yazzang-homelab) 오케스트레이션에 모델로 등록하는 절차를 정리한 문서입니다.

가장 흔한 실패 원인은 프록시 버그가 아니라 **신원(identity) 불일치**입니다.
이 문서는 그 원인을 진단하는 방법과, 확인된 정상 절차를 함께 다룹니다.

---

## 0. 먼저: 크레딧은 캘린더 월 경계에서 사라집니다

`getUsageLimits` 응답의 `nextDateReset` 은 가입 기념일이 아니라 **다음 달 1일 00:00 UTC** 입니다.
실측값이 정확히 월 경계에 떨어집니다.

```
"daysUntilReset": 0
"nextDateReset" : 1785542400   → 2026-08-01 00:00 UTC
```

공식 요금제 문서도 동일하게 안내합니다.

> Usage limits reset at the start of each billing month.
> Unused credits do not roll over to the next month.

| 종류 | 이월 | 만료 |
|---|---|---|
| 플랜 기본 크레딧 | 없음 | 매월 1일 소멸 |
| 추가 구매 크레딧 | 있음 | 구매일로부터 12개월 |

따라서 **월말에 결제하면 며칠 만에 그 달치 전량을 받고, 1일에 다시 전량으로 초기화**됩니다.
앞의 배분은 유효기간이 며칠뿐이므로, 그 안에 쓰지 않으면 그대로 0이 됩니다.

### 배수가 처리량을 결정합니다

모델마다 `rateMultiplier`(요청당 크레딧 배수)가 다릅니다. 아래는 2026-08-18
Power 등급 계정의 `ListAvailableModels` 응답입니다. 배수와 부여 모델은 등급과 시점에 따라
바뀌므로 표를 외우지 말고 `./kiro-usage.sh` 로 현재 값을 확인하십시오.

| 모델 | 배수 | 10,000 크레딧 환산 하한 |
|---|---:|---:|
| gpt-5.6-sol | 2.4 | 4,166 |
| claude-opus-5 / 4.8 / 4.7 / 4.6 / 4.5 | 2.2 | 4,545 |
| claude-sonnet-5 / 4.6 / 4.5 / 4 | 1.3 | 7,692 |
| auto, gpt-5.6-terra | 1.0 | 10,000 |
| glm-5 | 0.5 | 20,000 |
| claude-haiku-4.5 | 0.4 | 25,000 |
| deepseek-3.2, minimax-m2.5 | 0.25 | 40,000 |
| minimax-m2.1 | 0.15 | 66,666 |
| gpt-5.6-luna | 0.1 | 100,000 |
| qwen3-coder-next | 0.05 | **200,000** |

모델 간 차이는 최대 48배입니다. 문제는 크레딧을 다 못 쓰는 것이 아니라
**비싼 레인으로 싼 일을 하는 것**입니다.

> **배수는 상대 가격이지 실제 차감량이 아닙니다.** 실제 차감량은 업스트림 응답 스트림의
> `meteringEvent.usage` 이며(kiro-go `proxy/kiro.go`), 실측값은 "1요청 = 배수만큼 차감"보다
> 작았습니다(5-3절). 위 환산은 그 가정에 따른 **하한**입니다.

> 이 문서가 다루는 것은 본인이 결제한 구독을 유효기간 안에 제대로 쓰는 방법입니다.
> 계정 공유, 크레딧 재판매, 다중 계정 순환은 이용약관 위반이며 범위 밖입니다.

---

## 1. 핵심: Kiro 계정은 두 종류입니다

| 구분 | AWS Builder ID | app.kiro.dev 계정 |
|---|---|---|
| kiro-go `authMethod` | `idc` | `social` / `api_key` |
| 로그인 방식 | 디바이스 코드 | Google / GitHub 소셜 |
| 유료 구독 귀속 | 불가 | **가능** |
| 기본 등급 | `KIRO FREE` | 결제 등급 그대로 |

**이메일 주소가 같아도 두 계정은 서로 다른 신원입니다.**
app.kiro.dev 에서 결제한 구독은 AWS Builder ID 로 로그인한 세션에 반영되지 않습니다.

`kiro-go` 소스에서도 두 경로는 명시적으로 분리되어 있습니다.

```go
// config/config.go
AuthMethod  // "idc", "social", "external_idp", or "api_key"

// proxy/handler.go
case method == "social" || method == "google" || method == "github":
    req.AuthMethod = "social"
```

### 증상

Builder ID 로 연결하면 다음 현상이 나타납니다.

```
WARN [ProfileArn] Failed to resolve profile ARN: no available Kiro profile
WARN [KiroAPI] Endpoint AmazonQ error: HTTP 400
     {"message":"Invalid model. ...","reason":"INVALID_MODEL_ID"}
```

- 상위 모델(Opus 계열)을 선택하면 HTTP 400 으로 거부됩니다.
- 그런데 **관리 화면 모델 목록에는 Opus 가 보입니다.**

목록에 보이는 이유는 권한이 있어서가 아닙니다. `profileArn` 해석이 실패하면
kiro-go 가 업스트림 목록을 받아오지 못하고 `proxy/handler.go` 의 **하드코딩된 대체 목록**을
그대로 노출하기 때문입니다. 선택하는 순간 업스트림이 거부합니다.

---

## 2. 진단: 실제 구독 등급 확인

추측하지 말고 AWS 응답을 직접 확인하십시오.

```bash
# ACCESS_TOKEN 또는 ksk_ 키를 환경변수로 전달합니다.
curl -s "https://codewhisperer.us-east-1.amazonaws.com/getUsageLimits\
?origin=AI_EDITOR&resourceType=AGENTIC_REQUEST&isEmailRequired=true" \
  -H "Authorization: Bearer $KIRO_TOKEN" | python3 -m json.tool
```

판정 기준은 `subscriptionInfo` 입니다.

| 필드 | 무료 신원 | 유료 신원 |
|---|---|---|
| `subscriptionTitle` | `KIRO FREE` | `KIRO PRO` / `KIRO POWER` 등 |
| `subscriptionManagementTarget` | `PURCHASE` | `MANAGE` |
| `upgradeCapability` | `UPGRADE_CAPABLE` | `UPGRADE_INCAPABLE`(최상위) |

`PURCHASE` 가 보이면 그 신원에는 결제 이력이 없습니다. 계정을 잘못 연결한 것입니다.

부여된 모델의 정확한 목록은 다음으로 확인합니다.

```bash
curl -s "https://codewhisperer.us-east-1.amazonaws.com/ListAvailableModels\
?origin=AI_EDITOR&maxResults=50" \
  -H "Authorization: Bearer $KIRO_TOKEN" | python3 -m json.tool
```

> Builder ID 로는 `ListAvailableProfiles` 가
> `AWS Builder ID is not supported for this operation.` 을 반환합니다.
> 이것이 로그의 `no available Kiro profile` 경고의 원인이며, 그 자체는 버그가 아닙니다.

---

## 3. 정상 연결 절차

### 3-1. API 키 발급

`app.kiro.dev` 에 **유료 구독이 있는 계정**으로 로그인한 뒤 API 키(`ksk_...`)를 발급합니다.

API 키 계정은 `https://runtime.{region}.kiro.dev/` 런타임을 사용하며 `profileArn` 을
요구하지 않습니다. Builder ID 경로의 프로필 문제를 근본적으로 우회합니다.

```go
// proxy/kiro.go
return fmt.Sprintf("https://runtime.%s.kiro.dev/", region)
```

### 3-2. kiro-go 에 등록

```bash
./kiro-login.sh apikey
```

키는 stdin 으로만 입력받습니다. 셸 히스토리와 `ps` 출력에 남지 않습니다.

### 3-3. 무료 계정을 풀에서 제외

kiro-go 는 계정 풀을 라운드로빈으로 사용합니다. 무료 Builder ID 계정이 활성 상태로
남아 있으면 상위 모델 요청이 **무작위로 실패**합니다. 반드시 비활성화하십시오.

```bash
./kiro-login.sh status            # 계정 ID 확인
./kiro-login.sh disable <계정ID>
```

### 3-4. 확인

```bash
./kiro-login.sh status
```

구독 등급과 부여 모델 수가 출력됩니다.

---

## 4. GJC 에 모델 등록

`gen_kiro_models.py` 는 업스트림이 실제로 부여한 모델만 읽어 `models.yml` 의
`kiro` 프로바이더 블록을 생성합니다. 모델 목록을 하드코딩하지 않으므로 구독 등급이
바뀌면 다시 실행하는 것만으로 설정이 따라옵니다.

```bash
python3 gen_kiro_models.py --print                        # 미리보기
python3 gen_kiro_models.py --apply ~/.gjc/agent/models.yml
```

실행 시 기존 파일은 `models.yml.bak-<타임스탬프>-genkiro` 로 자동 백업됩니다.
`kiro` 블록이 없으면 `providers:` 섹션 맨 앞에 새로 넣습니다(처음 등록할 때,
또는 계정 문제로 블록을 걷어낸 뒤 되살릴 때).

이어서 프리셋을 다시 씁니다.

```bash
python3 restore_profiles.py ~/.gjc/agent/models.yml
```

`restore_profiles.py` 는 아래 프리셋 중 **부여된 모델만 참조하는 것만** 넣고,
나머지는 빠진 모델 이름과 함께 건너뜁니다. 등급이 낮아 Opus 가 없는 계정에서 Opus
프리셋이 남아 있으면 GJC 는 그 프리셋을 고르는 순간 실패하기 때문입니다.
`equivalence.exclude` 는 `kiro/` 항목만 교체하고 다른 항목은 보존합니다.

| 프리셋 | 구성 |
|---|---|
| `kiro` | 상시 기본. 판단 레인 상위 모델 |
| `kiro-mixed` | 판단은 Opus, executor 는 최저 배수 |
| `kiro-thrift` | 전 레인 저배수 |
| `kiro-burn` | 중배수 위주 |
| `kiro-monthend` | 소멸 직전 크레딧으로 상위 레인 개방 |
| `kiro-xhigh` | 배수 2.0 이상 모델의 `xhigh` 강도 |
| `kiro-luna` | 본 대화만 kiro, 서브에이전트는 다른 프로바이더(혼합 예시) |

혼합 프리셋은 참조하는 프로바이더가 `models.yml` 에 정의돼 있을 때만 들어갑니다.
자기 환경의 프로바이더 이름으로 `PROFILES` 를 고쳐 쓰십시오.

### 프리셋 구성 예시

`rateMultiplier` 는 요청당 크레딧 배수입니다. 이 값을 기준으로 레인을 배치하면
동일 예산에서 처리량이 크게 달라집니다.

```yaml
profiles:
  # 판단은 상위 모델, 반복 편집은 저비용 모델
  kiro-mixed:
    required_providers: [kiro]
    model_mapping:
      default:   kiro/claude-opus-5:medium      # rate 2.2
      executor:  kiro/qwen3-coder-next          # rate 0.05
      planner:   kiro/deepseek-3.2:high         # rate 0.25
      architect: kiro/glm-5:high                # rate 0.5
      critic:    kiro/claude-opus-5:high        # rate 2.2
```

토큰을 가장 많이 소모하는 `executor` 레인을 저배수 모델로 돌리는 것이 핵심입니다.
Opus(2.2)와 qwen3-coder-next(0.05)의 배수 차이는 44배입니다.

월말처럼 곧 소멸할 크레딧이 남았다면 평소 아끼던 상위 레인을 여는 프리셋을 따로 둡니다.

```yaml
  kiro-monthend:
    required_providers: [kiro]
    model_mapping:
      default:   kiro/claude-opus-5:high
      executor:  kiro/claude-opus-5:high      # 평소엔 0.05 로 두던 자리
      planner:   kiro/gpt-5.6-sol:high
      architect: kiro/claude-opus-5:high
      critic:    kiro/claude-opus-4.8:high
```

단, 소진 자체가 목적이 되면 안 됩니다. 밀린 리팩터링, 테스트 보강, 문서화처럼
**결과가 저장소에 남는 작업**에만 붙이십시오.

### 검증

```bash
gjc -p "reply with exactly: OK" --model kiro/claude-opus-5
```

---

## 5. 운영

### 5-1. 잔여 확인

```bash
./kiro-usage.sh
```

활성 계정마다 업스트림에서 등급·크레딧·리셋일을 새로 읽고, 모델별 배수와 잔여 호출 하한을
출력합니다. 비활성 계정은 kiro-go 가 기록한 사유와 시각을 함께 보여 줍니다(6절).

### 5-2. 등급 변경 후

```bash
./kiro-refresh.sh
```

부여 모델 재조회 → `kiro` 블록 재생성 → 프리셋 재적용 → 잔여 출력을 한 번에 수행합니다.
API 키는 등급이 바뀌어도 유효하므로 재등록할 필요가 없습니다.

### 5-3. 실제 차감량

실제 차감은 요청마다 업스트림이 보내는 `meteringEvent.usage` 값입니다.

```go
// proxy/kiro.go
case "meteringEvent":
    if usage, ok := event["usage"].(float64); ok {
        totalCredits += usage
    }
```

2026-08-18 GJC 세션에서 기록한 값입니다(단일 세션, 표본 소수).

| 작업 | 차감 크레딧 | 배수 |
|---|---:|---:|
| claude-opus-5 단발 턴 | 0.295 | 2.2 |
| claude-sonnet-5 단발 턴 | 0.256 | 1.3 |
| claude-opus-5 툴 루프 1턴 | 1.05 | 2.2 |
| 서브에이전트 위임 1건, 전 레인 kiro | 3.94 | — |
| 서브에이전트 위임 1건, `kiro-luna` 구성 | 1.93 | — |

단발 턴은 배수보다 훨씬 적게 차감됐고, 툴 루프처럼 컨텍스트가 커지면 늘었습니다.
차감량이 요청 크기에 따라 달라지는 것으로 보이지만, 산식은 공개돼 있지 않습니다.
계획은 `kiro-usage.sh` 의 하한으로 세우고, 실제 소모는 작업 전후 잔여 차이로 확인하십시오.

---

## 6. 계정이 풀에서 빠졌을 때

kiro-go 는 서로 다른 두 상황을 모두 `banStatus: BANNED` 로 표시하고 계정을
비활성화(`enabled: false`)합니다. **`BANNED` 라는 글자만 보고 판단하지 말고 `banReason` 을
보십시오.** `./kiro-usage.sh` 가 비활성 계정마다 사유를 출력합니다.

| `banReason` | 판정 근거 (kiro-go) | 의미 | 조치 |
|---|---|---|---|
| `AWS temporarily suspended - unusual user activity detected` | 오류 문자열에 `TEMPORARILY_SUSPENDED` 또는 `account suspended` | 업스트림이 계정을 정지 | 프록시로 해결되지 않음. Kiro 고객지원에 문의 |
| `Authentication failed - token invalid or expired` | `HTTP 401`·`HTTP 403`·`unauthorized`·`token expired` 등 부분 문자열 | 키 폐기·만료, 구독 종료 등 | 키 재발급 후 `./kiro-rekey.sh` |

```go
// proxy/account_failover.go
case isSuspensionErrorMessage(errMsg):
    h.disableAccount(account, "BANNED", "AWS temporarily suspended - unusual user activity detected")
case isAuthErrorMessage(errMsg):
    h.disableAccount(account, "BANNED", "Authentication failed - token invalid or expired")
```

두 번째 사유는 부분 문자열 매칭이라 범위가 넓습니다. 계정 정보 갱신 경로
(`proxy/kiro_api.go` 의 `RefreshAccountInfo`)는 `403`·`401`·`invalid`·`expired` 가 들어간
어떤 오류도 같은 사유로 기록합니다. 키를 버리기 전에 2절의 `getUsageLimits` 를
직접 호출해 업스트림의 실제 응답을 확인하십시오.

이 환경에서 관측한 사례입니다.

| 시각 (UTC) | 등급 | 사유 | 당시 사용량 |
|---|---|---|---:|
| 2026-08-18 07:24 | Power | `unusual user activity detected` | 1,736 / 10,000 |
| 2026-09-01 07:03 | Pro | `token invalid or expired` | 0 / 2,000 |

정지는 크레딧 한도에 한참 못 미친 사용량에서 발생했습니다. 한도가 남아 있다는 것은
정지되지 않는다는 보장이 아닙니다. 업스트림은 판정 기준을 공개하지 않습니다.

> 정지된 계정을 대신할 새 계정을 만들어 풀에 넣는 것은 우회이며 이용약관 위반입니다.
> `kiro-rekey.sh` 는 본인 구독의 키를 교체하는 용도입니다.

### 키 교체

```bash
./kiro-rekey.sh
```

새 키 등록 → `models/refresh` 로 업스트림 실물 검증(거부되면 방금 등록한 계정 삭제) →
나머지 계정 비활성화 → `kiro` 블록·프리셋 재생성 → `gjc -p` 호출 검증 순서로 진행합니다.
kiro-go 의 등록 API 는 키를 검사하지 않으므로 검증 단계를 건너뛰면 무효 키가 풀에 들어갑니다.

---

## 7. 알아둘 점

**모델 ID 정규화.** kiro-go 는 `claude-opus-5-0` 형태를 `claude-opus-5.0` 으로 변환해
전송합니다. 업스트림에는 소수점 변종이 없으므로 400 이 반환됩니다. 정식 ID 는
`claude-opus-5` 입니다.

```go
// proxy/translator.go
claude-(opus|sonnet|haiku)-(\d+)-(\d{1,2})\b  →  claude-$1-$2.$3
```

**`/v1/models` 응답을 신뢰하지 마십시오.** 인증 상태에 따라 대체 목록이 섞입니다.
권한의 근거는 업스트림 `ListAvailableModels` 뿐입니다. 실측: 모든 계정이 비활성인
상태에서도 `/v1/models` 는 `claude-opus-4.7`, `gpt-4o`, `gpt-4` 등 17종을 반환했습니다.

**API 키 취급.** 키는 구독 전체에 대한 접근 권한입니다. 채팅 로그, 이슈, 커밋에
노출되었다면 즉시 `app.kiro.dev` 에서 폐기하고 재발급하십시오.

**관리 포트 노출 금지.** kiro-go 관리 API 는 비밀번호 헤더 하나로 계정 자격증명을
다룹니다. `127.0.0.1` 에만 바인딩하십시오.

kiro-go 는 **현재 디렉터리**의 `data/config.json` 을 읽고, 없으면 `host: 0.0.0.0`,
`port: 8080` 기본값으로 새 파일을 만든 뒤 전 인터페이스에 바인딩합니다
(`config/config.go`). 다른 디렉터리에서 바이너리를 실행하면 설정해 둔 `127.0.0.1` 이
적용되지 않습니다. `--version` 같은 플래그도 받지 않고 그대로 서버를 띄웁니다.
항상 작업 디렉터리를 고정한 서비스로 띄우십시오.

```ini
# /etc/systemd/system/kiro-go.service
[Service]
Type=simple
WorkingDirectory=/root/kiro-go
ExecStart=/root/kiro-go/kiro-go
Restart=always
RestartSec=5
```

띄운 뒤 `ss -ltnp | grep kiro-go` 로 `127.0.0.1:8317` 만 열려 있는지 확인하십시오.

---

## 파일

| 파일 | 설명 |
|---|---|
| `kiro-login.sh` | 계정 등록 · 비활성화 · 상태 확인 헬퍼 |
| `gen_kiro_models.py` | 업스트림 권한 기반 `models.yml` 블록 생성기 |
| `restore_profiles.py` | 부여 모델 기준 kiro 프리셋·`equivalence` 재적용 |
| `kiro-usage.sh` | 등급·크레딧·리셋일·모델별 배수, 비활성 계정 사유 |
| `kiro-refresh.sh` | 등급 변경 후 모델·프리셋 일괄 갱신 |
| `kiro-rekey.sh` | API 키 교체(등록 → 실물 검증 → 풀 정리 → 재생성 → 호출 검증) |

스크립트는 `KIRO_GO_BASE`(기본 `http://127.0.0.1:8317`)와 `KIRO_GO_PWFILE`
(기본 `/root/kiro-go/admin-password.txt`) 또는 `KIRO_GO_ADMIN_PASSWORD` 를 따릅니다.
`kiro-refresh.sh`·`kiro-rekey.sh` 는 `MODELS_YML`(기본 `~/.gjc/agent/models.yml`)도 따르며,
같은 디렉터리의 다른 스크립트를 호출합니다.

## 웹 가이드

같은 내용을 초보자용 / 오케스트레이션용으로 나눈 문서: <https://leesayah.duckdns.org/kiro-identity.html>

## 라이선스

MIT

## 고지

본 문서는 개인 환경에서 확인한 절차를 정리한 자료이며 Amazon, AWS, Kiro 와 무관합니다.
각 서비스의 이용약관 준수 책임은 사용자에게 있습니다.
