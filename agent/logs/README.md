# agent/logs — 실행 로그

이 디렉터리의 로그는 전부 **실제로 실행한 결과**를 그대로 받아 적은 것입니다.
편집하지 않았고, 종료 코드도 그대로 기록했습니다.

예외: regex-baseline.txt 45행의 로컬 절대경로는 agent/out/submissions.json 상대경로로 치환했다.

## 파일

| 파일 | 내용 | 백엔드 |
|---|---|---|
| `llm-compare.txt` | **실제 LLM** vs 정규식 필드별 대조 | `gpt-5.6-luna` @ OrcaRouter |
| `mock-api-selftest.txt` | LLM API 경로(`_extract_api`) 자체검사 | **목 HTTP 서버** — LLM 아님 |
| `no-key-leak-selftest.txt` | API 키 유출 차단 검증 | 해당 없음 |
| `regex-baseline.txt` | 5건 추출 → 제출 → 중복 거부 | `deterministic-regex` |

## 실제 LLM 대조 결과

```
endpoint : https://api.orcarouter.ai/v1
model    : gpt-5.6-luna
실행     : 2026-09-18 09:52 (KST)

추출 성공   5/5건
불일치     0건 / 대조된 35필드 (5건 × 7필드)
응답 지연   1.53 ~ 2.13초
API 오류   없음
```

이 실행은 **저장소 소유자 환경에서 수행**됐고 원본이 `agent/out/llm_compare.json`
에 남아 있습니다. `llm-compare.txt` 는 그 JSON을 그대로 렌더링한 것이라 둘이
틀어질 수 없습니다 (`python run_llm_compare.py --from-json` 으로 재생성 가능).

**불일치 0건이 "LLM은 틀리지 않는다"를 뜻하지는 않습니다.** 표본이 5건이고
데모 로그는 포맷이 정연합니다. 틀렸을 때 무슨 일이 벌어지는지는
`mock-api-selftest.txt` 가 요금 자릿수를 일부러 틀리게 해서 보여줍니다.

### 직접 다시 돌리려면

무료 키를 발급받아 환경변수로 넣고 한 줄 실행하면 됩니다.

```powershell
# PowerShell
$env:LLM_API_BASE="https://api.orcarouter.ai/v1"
$env:LLM_API_KEY="gsk_..."
$env:LLM_API_MODEL="gpt-5.6-luna"
python run_llm_compare.py
```

```bash
# bash
export LLM_API_BASE="https://api.orcarouter.ai/v1"
export LLM_API_KEY="gsk_..."
export LLM_API_MODEL="gpt-5.6-luna"
python run_llm_compare.py
```

5건을 실제 LLM으로 추출하고 정규식 결과와 필드별로 대조한 뒤
`agent/out/llm_compare.json` 과 `agent/logs/llm-compare.txt` 를 동시에 씁니다.

종료 코드가 세 가지로 갈립니다.

| 코드 | 의미 |
|---|---|
| `0` | 대조 수행됨 |
| `2` | 키 미설정 — 호출 자체를 안 함 |
| `3` | 호출했으나 추출 성공 0건 — **대조 불가** |

`3` 을 따로 둔 이유가 있습니다. 이전 버전은 추출이 전부 실패해도
"불일치 필드 0건 / 전체 35필드" 를 찍었습니다. 비교를 한 번도 안 했는데
전부 일치한 것처럼 읽힙니다 — 실패를 성공으로 오독하게 만드는 출력이라
버그였고, 지금은 "대조 불가" 로 명시하고 분모도 `대조된 N필드` 로 바뀝니다.

위 값은 이번 대조에 실제로 쓴 설정입니다. 다른 공급자를 쓰실 경우
**모델명이 여전히 서비스 중인지 먼저 확인하십시오** — 모델은 생명주기가 짧습니다.
예를 들어 Groq 의 `llama-3.3-70b-versatile` 은 2026-08-16 자로 중단됐습니다.
모델명이 틀리면 `exit 3`(대조 불가)로 끝나고 사유가 'API 오류' 항목에 남습니다.

대안 엔드포인트: [OpenRouter](https://openrouter.ai/keys) ·
[무료 엔드포인트 목록](https://github.com/cheahjs/free-llm-api-resources)

## 목 서버 검사가 증명하는 것과 못 하는 것

`mock-api-selftest.txt` 가 증명하는 것은 **우리 HTTP 코드 경로가 맞다**는 것뿐입니다.
LLM의 정확도와는 무관합니다.

검사 과정에서 실제 버그 두 개를 잡았습니다. 키가 있었어도 LLM 경로는
조용히 실패했을 것입니다.

1. `strict: true` 를 보내면서 스키마에 `additionalProperties: false` 가 없었습니다.
   OpenAI 호환 서버는 이 조합을 400으로 거절합니다.
2. `except Exception: return None` 이 원인을 통째로 삼켰습니다.
   그래서 실패해도 조용히 정규식으로 떨어졌고, 시연 로그가 전부
   `[deterministic-regex]` 였는데도 아무도 눈치채지 못했습니다.

둘 다 고쳤고, 목 서버가 받은 실제 요청으로 확인했습니다.

```
OK  response_format.type == json_schema
OK  strict == True
OK  additionalProperties == False
OK  첫 시도에서 성공(폴백 안 탐)
```

## 키가 로그에 남지 않는 근거

`extract.redact()` 가 두 가지를 동시에 합니다.

- 환경변수에 설정된 **실제 키 문자열**을 직접 치환
- 공급자별 토큰 패턴(`Bearer ...`, `?api_key=...`, `sk-` / `gsk_` / `AIza` 등)을 정규식 치환

`no-key-leak-selftest.txt` 가 이걸 검증합니다. 표식 키를 심고, 키를 쿼리로도 받는
엔드포인트를 흉내 내 400을 되돌리며, 응답 본문에 `Authorization` 헤더를 일부러
echo 합니다. 그 뒤 에러 목록·콘솔 출력·엔드포인트 문자열 전부를 표식으로 검색합니다.

```
OK    LAST_API_ERRORS
OK    콘솔 출력
OK    redact(endpoint)
OK    redact(가짜 에러문자열)
통과 — 표식이 어느 표면에도 남지 않았다
```

`.env` 파일은 제출 ZIP 빌드에서 제외됩니다.
