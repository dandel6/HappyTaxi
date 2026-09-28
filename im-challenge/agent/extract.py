"""운행 기록 1건 → 컨트랙트 제출 형태로 변환하는 추출기.

입력
----
  · TIMS 로그 텍스트 (data/rides/*.txt)
  · 미터기 사진 (OCR 경로. 아래 "OCR" 참조)

출력
----
  SubmissionPayload — 원본 해시 + 추출값. 컨트랙트 submitRideMeter/Manual 인자 그대로.

백엔드 3단
----------
이 모듈은 심사위원 환경에서 **API 키 없이, 네트워크 없이** 돌아야 한다.
그래서 백엔드를 3단으로 두고 사용 가능한 것부터 쓴다.

  1. outlines + 로컬 LLM   OUTLINES_MODEL 이 설정돼 있으면 사용.
                           JSON 스키마를 생성 문법으로 강제한다.
  2. 무료 VLM/LLM API      LLM_API_BASE + LLM_API_KEY 가 있으면 사용.
                           cheahjs/free-llm-api-resources 목록의 엔드포인트를 가정.
  3. 결정론적 파서         위 둘이 없으면 정규식으로 뽑는다.
                           데모 로그는 우리가 만든 고정 포맷이라 확정적으로 파싱된다.

3번이 있는 이유는 "AI가 틀려도 장부는 안 깨진다"를 보이는 데 LLM이 꼭 필요하지 않기 때문이다.
논지의 증명 대상은 컨트랙트지 추출기가 아니다. 추출기는 틀릴 수 있는 쪽 역할이다.

OCR
---
PaddleOCR(PaddlePaddle/PaddleOCR)을 먼저 시도한다. 설치가 무거워 실패하면
2번 백엔드의 VLM에 이미지를 그대로 넘긴다. 둘 다 없으면 이미지 입력은 건너뛴다.
데모 5건은 전부 텍스트 로그라 OCR 없이도 완주한다.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from dataclasses import dataclass, asdict
from datetime import datetime
from pathlib import Path

from schema import RIDE_SCHEMA, RideExtraction

ROOT = Path(__file__).parent

#: LLM API 실패 이유를 모아둔다. 호출자가 출력해 원인을 보게 한다.
#: 이전엔 except가 무조건 삼켜서 "왜 정규식으로 떨어졌는지"를 알 방법이 없었다.
#: 반드시 redact()를 거쳐 넣는다 — 아래 주석 참조.
LAST_API_ERRORS: list[str] = []


# ───────────────────────────────────────────────────
# 키 유출 차단
# ───────────────────────────────────────────────────

_TOKEN_PATTERNS = [
    # Authorization 헤더가 에러 본문에 에코되는 경우
    (re.compile(r"(Bearer\s+)[A-Za-z0-9._\-]{8,}", re.I), r"\1<redacted>"),
    # 쿼리 파라미터로 키를 받는 공급자(Gemini 등). URL이 예외 문자열에 그대로 들어간다.
    (re.compile(r"([?&](?:api[_-]?key|key|access_token)=)[^&\s\"']+", re.I), r"\1<redacted>"),
    # 공급자별 토큰 접두사
    (re.compile(r"\b(sk-or-v1-|sk-|gsk_|AIza|hf_|r8_)[A-Za-z0-9._\-]{8,}"), r"\1<redacted>"),
]


def redact(s: str) -> str:
    """문자열에서 키로 보이는 것을 지운다.

    왜 필요한가:
      HTTPError 를 str() 하면 **요청 URL이 통째로** 들어간다.
      키를 쿼리로 받는 공급자면 그 순간 에러 문자열에 키가 박힌다.
      응답 본문도 마찬가지다 — 일부 공급자는 요청 맥락을 그대로 되돌려준다.
      그 문자열이 llm_compare.json 과 로그 파일로 들어가고,
      그 파일이 제출 ZIP 에 들어간다. 한 번만 새면 끝이다.

    두 가지를 다 한다:
      1. 환경변수에 설정된 **실제 키 문자열**을 직접 치환 (가장 확실)
      2. 공급자별 토큰 패턴을 정규식으로 치환 (방어 심층)
    1번만 있으면 다른 환경변수로 들어온 키를 놓치고,
    2번만 있으면 새 공급자 접두사를 놓친다.
    """
    if not s:
        return s
    for env_name in ("LLM_API_KEY", "OPENAI_API_KEY", "GROQ_API_KEY", "OPENROUTER_API_KEY"):
        v = os.environ.get(env_name)
        if v and len(v) >= 8:
            s = s.replace(v, "<redacted>")
    for pat, rep in _TOKEN_PATTERNS:
        s = pat.sub(rep, s)
    return s


# ─────────────────────────────────────────────────────────────
# 컨트랙트 제출 형태
# ─────────────────────────────────────────────────────────────


@dataclass
class SubmissionPayload:
    """컨트랙트 submitRideMeter / submitRideManual 인자.

    driver 주소와 village_id 는 추출값이 아니라 **매핑 결과**다.
    LLM이 마을명을 뱉으면 운영기관 대장에서 ID를 찾는다.
    LLM에게 ID를 직접 뱉게 하면 없는 마을 번호를 지어낼 수 있다.
    """

    driver: str
    vehicle_hash: str  # keccak(차량번호) — 원본은 개인정보라 온체인에 안 올린다
    ride_timestamp: int  # 운행일시 epoch seconds
    ride_day: int  # KST 에폭일
    origin_village_id: int
    fare_krw: int
    passengers: int
    fare_source: str  # "meter" | "manual"
    source_ref: str  # 원본 레코드 해시. 이벤트에만 실린다.
    backend: str  # 어느 백엔드가 뽑았는지

    def to_json(self) -> str:
        return json.dumps(asdict(self), ensure_ascii=False, indent=2)


# ─────────────────────────────────────────────────────────────
# 해시 · 시간 유틸
# ─────────────────────────────────────────────────────────────


def keccak_like(data: bytes) -> str:
    """원본 해시. 데모에서는 sha256을 쓴다.

    컨트랙트의 rideIdOf는 keccak256을 쓰지만, 그건 (차량해시, 일시, 마을)로
    컨트랙트가 **직접** 파생한다. 여기서 만드는 해시는 두 가지 용도뿐이다:
      · vehicle_hash — 차량번호를 온체인에 평문으로 안 올리기 위한 익명화
      · source_ref   — 원본 로그와 이벤트를 대사하기 위한 지문
    둘 다 컨트랙트가 값으로 쓰지 않고 그대로 보관만 하므로 알고리즘이 달라도 무방하다.
    운영 이관 시에는 양쪽을 keccak256으로 맞추는 편이 대사에 편하다.
    """
    return "0x" + hashlib.sha256(data).hexdigest()


def kst_epoch_day(dt: datetime) -> int:
    """KST 기준 1970-01-01부터의 일수. 컨트랙트 rideDay 규약."""
    return int(dt.timestamp() + 9 * 3600) // 86400


# ─────────────────────────────────────────────────────────────
# 백엔드 1 — outlines + 로컬 LLM
# ─────────────────────────────────────────────────────────────


def _extract_outlines(text: str) -> RideExtraction | None:
    """outlines로 JSON 스키마를 생성 문법에 강제해 뽑는다.

    OUTLINES_MODEL 미설정이면 None을 돌려 다음 백엔드로 넘긴다.
    모델 다운로드가 수 GB라 기본 경로로 두지 않는다.
    """
    model_id = os.environ.get("OUTLINES_MODEL")
    if not model_id:
        return None
    try:
        import outlines
        from transformers import AutoModelForCausalLM, AutoTokenizer
    except ImportError:
        return None

    try:
        model = outlines.from_transformers(
            AutoModelForCausalLM.from_pretrained(model_id),
            AutoTokenizer.from_pretrained(model_id),
        )
        prompt = (
            "다음 택시 운행 로그에서 값을 추출해 JSON으로만 답하라.\n\n"
            f"{text}\n"
        )
        # 스키마 밖 토큰이 생성 단계에서 차단된다. 파싱 실패라는 실패 모드가 없다.
        raw = model(prompt, outlines.json_schema(RIDE_SCHEMA), max_new_tokens=512)
        return RideExtraction.model_validate_json(raw)
    except Exception:
        return None


# ─────────────────────────────────────────────────────────────
# 백엔드 2 — 무료 LLM/VLM API
# ─────────────────────────────────────────────────────────────


def _extract_api(text: str) -> RideExtraction | None:
    """OpenAI 호환 엔드포인트에 JSON 스키마를 요구한다.

    LLM_API_BASE / LLM_API_KEY / LLM_API_MODEL 환경변수가 다 있어야 동작한다.
    무료 엔드포인트 목록: github.com/cheahjs/free-llm-api-resources
    """
    base = os.environ.get("LLM_API_BASE")
    key = os.environ.get("LLM_API_KEY")
    model = os.environ.get("LLM_API_MODEL")
    if not (base and key and model):
        return None

    # 공급자별로 지원 수준이 다르다. 강한 것부터 순서대로 내려간다.
    #   json_schema  생성 문법에 스키마를 강제. 파싱 실패라는 실패 모드가 없다.
    #   json_object  JSON임만 보장. 필드 구성은 프롬프트에 의존.
    #   (없음)      그냥 텍스트. 코드블록 감싸기를 벗겨낸다.
    attempts = [
        ("json_schema", {
            "type": "json_schema",
            "json_schema": {"name": "ride", "schema": RIDE_SCHEMA, "strict": True},
        }),
        ("json_object", {"type": "json_object"}),
        ("plain", None),
    ]

    prompt = (
        "다음 택시 운행 로그에서 값을 추출해 JSON으로만 답하라. 설명을 붙이지 마라.\n\n"
        "필드: " + ", ".join(RIDE_SCHEMA.get("properties", {})) + "\n"
        "fare_source 는 meter 또는 manual 중 하나다.\n\n" + text
    )

    for mode, rf in attempts:
        try:
            import urllib.request

            payload_req = {
                "model": model,
                "messages": [{"role": "user", "content": prompt}],
                "temperature": 0,
            }
            if rf is not None:
                payload_req["response_format"] = rf

            req = urllib.request.Request(
                base.rstrip("/") + "/chat/completions",
                data=json.dumps(payload_req, ensure_ascii=False).encode("utf-8"),
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {key}",
                },
            )
            with urllib.request.urlopen(req, timeout=60) as r:
                payload = json.loads(r.read().decode("utf-8"))

            content = payload["choices"][0]["message"]["content"]
            return RideExtraction.model_validate_json(_strip_fence(content))

        except Exception as e:  # noqa: BLE001
            detail = ""
            body = getattr(e, "read", None)
            if callable(body):
                try:
                    detail = " | " + body().decode("utf-8", "replace")[:300]
                except Exception:
                    pass
            # 조용히 삼키지 않는다. 이게 없어서 LLM 경로가 안 도는 걸 못 봤다.
            LAST_API_ERRORS.append(redact(f"[{mode}] {type(e).__name__}: {e}{detail}"))
            continue

    return None


def _strip_fence(s: str) -> str:
    """```json ... ``` 감싸기를 벗긴다. plain 모드에서 흔하다."""
    s = s.strip()
    if s.startswith("```"):
        s = re.sub(r"^```[a-zA-Z]*\s*", "", s)
        s = re.sub(r"\s*```$", "", s)
    return s.strip()


# ─────────────────────────────────────────────────────────────
# 백엔드 3 — 결정론적 파서
# ─────────────────────────────────────────────────────────────

# 컬럼명에 "당회운행요금(미터기 자동인식)" 처럼 괄호 안 공백이 들어 있다.
# \S* 로 잡으면 공백에서 끊겨 콜론을 못 만난다. [^:：\n]* 로 콜론 앞까지 통째로 집는다.
# 행 시작 앵커(^, MULTILINE)를 쓰는 이유는 "출발지"가 "세부출발지"에도 들어 있기 때문이다.
_PATTERNS = {
    "vehicle_no": r"^차량번호\s*[:：]\s*(\S+)",
    "ride_datetime": r"^운행일시\s*[:：]\s*(\S+)",
    "origin_village": r"^출발지\s*[:：]\s*(\S+)",
    "meter_fare_krw": r"^당회운행요금[^:：\n]*[:：]\s*([\d,]+)",
    "distance_m": r"^운행거리[^:：\n]*[:：]\s*([\d,]+)",
    "passengers": r"^승차자수\s*[:：]\s*(\d+)",
    "fare_source": r"^보조금\s*입력\s*방식\s*[:：]\s*(\S+)",
}


def _extract_regex(text: str) -> RideExtraction:
    """데모 로그 고정 포맷 파서. 네트워크·모델 없이 확정적으로 동작한다."""
    out: dict[str, object] = {}
    for field, pat in _PATTERNS.items():
        m = re.search(pat, text, re.MULTILINE)
        if not m:
            raise ValueError(f"필드 누락: {field}")
        val = m.group(1).replace(",", "")
        if field in ("meter_fare_krw", "distance_m", "passengers"):
            out[field] = int(val)
        else:
            out[field] = val
    # 스키마 검증은 동일하게 통과시킨다. 백엔드가 달라도 출력 계약은 하나다.
    return RideExtraction.model_validate(out)


# ─────────────────────────────────────────────────────────────
# 공개 API
# ─────────────────────────────────────────────────────────────


def extract(text: str) -> tuple[RideExtraction, str]:
    """사용 가능한 백엔드를 순서대로 시도한다. (추출값, 백엔드명)"""
    r = _extract_outlines(text)
    if r is not None:
        return r, "outlines+local-llm"
    r = _extract_api(text)
    if r is not None:
        return r, "free-llm-api"
    return _extract_regex(text), "deterministic-regex"


def ocr_image(path: Path) -> str | None:
    """미터기 사진 → 텍스트. PaddleOCR 우선, 없으면 None.

    데모 5건은 전부 텍스트 로그라 이 경로를 타지 않는다.
    이미지 입력이 들어오면 여기서 텍스트로 바꿔 extract()에 넘긴다.
    """
    try:
        from paddleocr import PaddleOCR
    except ImportError:
        return None
    try:
        ocr = PaddleOCR(use_angle_cls=True, lang="korean", show_log=False)
        result = ocr.ocr(str(path), cls=True)
        lines = [ln[1][0] for page in result for ln in page]
        return "\n".join(lines)
    except Exception:
        return None


def to_submission(
    ex: RideExtraction,
    raw_text: str,
    backend: str,
    driver_of_vehicle: dict[str, str],
    village_ids: dict[str, int],
) -> SubmissionPayload:
    """추출값 → 컨트랙트 인자.

    driver 주소와 village_id 는 **대장 조회 결과**이지 LLM 출력이 아니다.
    LLM에게 주소나 마을 ID를 뱉게 하면 존재하지 않는 값을 지어낼 수 있고,
    그건 스키마로 못 막는다(형식은 맞고 값만 틀리니까).
    조회에 실패하면 여기서 끊는다 — 컨트랙트까지 가기 전에.
    """
    if ex.vehicle_no not in driver_of_vehicle:
        raise KeyError(f"미등록 차량: {ex.vehicle_no}")
    if ex.origin_village not in village_ids:
        raise KeyError(f"미등록 마을: {ex.origin_village}")

    dt = datetime.fromisoformat(ex.ride_datetime)
    return SubmissionPayload(
        driver=driver_of_vehicle[ex.vehicle_no],
        vehicle_hash=keccak_like(ex.vehicle_no.encode()),
        ride_timestamp=int(dt.timestamp()),
        ride_day=kst_epoch_day(dt),
        origin_village_id=village_ids[ex.origin_village],
        fare_krw=ex.meter_fare_krw,
        passengers=ex.passengers,
        fare_source="manual" if ex.fare_source.lower().startswith("manual") else "meter",
        source_ref=keccak_like(raw_text.encode()),
        backend=backend,
    )
