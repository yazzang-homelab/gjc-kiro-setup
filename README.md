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

크레딧은 요청 수가 아니라 `rateMultiplier × 요청 수` 로 차감됩니다.

| 모델 | 배수 | 10,000 크레딧 환산 |
|---|---:|---:|
| gpt-5.6-sol | 2.4 | 4,166 |
| claude-opus-5 | 2.2 | 4,545 |
| claude-sonnet-5 | 1.3 | 7,692 |
| gpt-5.6-luna | 0.6 | 16,666 |
| glm-5 | 0.5 | 20,000 |
| deepseek-3.2 | 0.25 | 40,000 |
| minimax-m2.1 | 0.15 | 66,666 |
| qwen3-coder-next | 0.05 | **200,000** |

같은 크레딧으로 4,545회를 쓸 수도, 200,000회를 쓸 수도 있습니다.
문제는 크레딧을 다 못 쓰는 것이 아니라 **비싼 레인으로 싼 일을 하는 것**입니다.

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
상위 모델과 최저 배수 모델의 차이는 40배가 넘습니다.

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

## 5. 알아둘 점

**모델 ID 정규화.** kiro-go 는 `claude-opus-5-0` 형태를 `claude-opus-5.0` 으로 변환해
전송합니다. 업스트림에는 소수점 변종이 없으므로 400 이 반환됩니다. 정식 ID 는
`claude-opus-5` 입니다.

```go
// proxy/translator.go
claude-(opus|sonnet|haiku)-(\d+)-(\d{1,2})\b  →  claude-$1-$2.$3
```

**`/v1/models` 응답을 신뢰하지 마십시오.** 인증 상태에 따라 대체 목록이 섞입니다.
권한의 근거는 업스트림 `ListAvailableModels` 뿐입니다.

**API 키 취급.** 키는 구독 전체에 대한 접근 권한입니다. 채팅 로그, 이슈, 커밋에
노출되었다면 즉시 `app.kiro.dev` 에서 폐기하고 재발급하십시오.

**관리 포트 노출 금지.** kiro-go 관리 API 는 비밀번호 헤더 하나로 계정 자격증명을
다룹니다. `127.0.0.1` 에만 바인딩하십시오.

---

## 파일

| 파일 | 설명 |
|---|---|
| `kiro-login.sh` | 계정 등록 · 비활성화 · 상태 확인 헬퍼 |
| `gen_kiro_models.py` | 업스트림 권한 기반 `models.yml` 블록 생성기 |

## 웹 가이드

같은 내용을 초보자용 / 오케스트레이션용으로 나눈 문서: <https://leesayah.duckdns.org/kiro-identity.html>

## 라이선스

MIT

## 고지

본 문서는 개인 환경에서 확인한 절차를 정리한 자료이며 Amazon, AWS, Kiro 와 무관합니다.
각 서비스의 이용약관 준수 책임은 사용자에게 있습니다.
