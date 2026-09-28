"""실제 LLM 백엔드 vs 정규식 백엔드 — 필드별 대조.

이 스크립트는 **실제 API 키가 있어야만** 호출을 수행한다.
키가 없으면 무엇을 설정해야 하는지 알려주고 exit 2 로 끝난다.
없는 결과를 지어내지 않는다 — 그게 이 파일의 유일한 규칙이다.

설정
----
  이번 대조에 실제로 쓴 값:
              LLM_API_BASE=https://api.orcarouter.ai/v1
              LLM_API_MODEL=gpt-5.6-luna

  OpenAI 호환이면 다른 공급자도 붙는다. 다만 **모델은 생명주기가 짧다** —
  예를 들어 Groq 의 llama-3.3-70b-versatile 은 2026-08-16 자로 중단됐다.
  공급자를 바꿀 때는 현재 서비스 중인 모델 목록을 먼저 확인할 것.
  모델명이 틀리면 exit 3 (대조 불가) 로 끝나고 사유는 api_errors 에 남는다.

  대안 엔드포인트 목록: https://github.com/cheahjs/free-llm-api-resources

실행
----
    export LLM_API_BASE=... LLM_API_KEY=... LLM_API_MODEL=...
    python run_llm_compare.py

    # 이미 만들어진 out/llm_compare.json 으로 로그만 다시 그릴 때 (API 호출 없음)
    python run_llm_compare.py --from-json

산출물
------
    out/llm_compare.json    기계 판독용 원본
    logs/llm-compare.txt    사람이 읽는 대조표

주의
----
  키는 환경변수로만 쓴다. 저장소에 넣지 않는다.
  이 스크립트는 키를 **한 글자도** 출력하지 않는다.
  엔드포인트에 키가 쿼리로 박혀 있을 수 있어 그것도 redact() 를 거친다.
  .env 를 만들어 쓰더라도 제출 ZIP 빌드에서 제외된다.
"""

from __future__ import annotations

import datetime
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import extract as EX  # noqa: E402
from run_agent import load_rides  # noqa: E402

ROOT = Path(__file__).parent
OUT = ROOT / "out"
LOGS = ROOT / "logs"

FIELDS = ["vehicle_no", "ride_datetime", "origin_village",
          "meter_fare_krw", "distance_m", "passengers", "fare_source"]


# ─────────────────────────────────────────────────────────────
# 렌더링 — 라이브 실행과 --from-json 이 같은 함수를 쓴다.
# 로그와 JSON 이 따로 놀지 않게 하려면 출처가 하나여야 한다.
# ─────────────────────────────────────────────────────────────


def render(payload: dict) -> str:
    L: list[str] = []
    ok = payload["llm_success"]
    n = payload["rides"]
    compared = ok * len(FIELDS)

    L.append("=" * 74)
    L.append("  실제 LLM vs 정규식 — 필드별 대조")
    L.append("=" * 74)
    L.append(f"  endpoint : {payload['endpoint']}")
    L.append(f"  model    : {payload['model']}")
    L.append("  key      : 환경변수에서만 읽음. 값은 출력도 기록도 하지 않음.")
    L.append(f"  실행 시각 : {payload.get('ran_at', '(미기록)')}")
    L.append("")
    L.append(f"  LLM 추출 성공 {ok}/{n}건")
    if payload.get("api_errors"):
        L.append("  API 오류:")
        for e in payload["api_errors"][:8]:
            L.append("    " + e[:180])
    L.append("")

    # ── 성공 0건이면 대조 자체가 없었다 ─────────────────────
    #
    # 예전 버전은 여기서도 "불일치 필드 0건 / 전체 35필드" 를 찍었다.
    # 비교를 한 번도 안 했는데 전부 일치한 것처럼 읽힌다 —
    # 실패를 성공으로 오독하게 만드는 출력이라 버그다.
    if ok == 0:
        L.append("  " + "!" * 70)
        L.append("  대조 불가 — LLM 추출이 한 건도 성공하지 않았습니다.")
        L.append("  비교가 수행되지 않았으므로 '불일치 0건' 은 성립하지 않습니다.")
        L.append("  " + "!" * 70)
        L.append("")
        L.append("  확인할 것:")
        L.append("    · LLM_API_BASE / LLM_API_KEY / LLM_API_MODEL 값")
        L.append("    · 위 'API 오류' 항목 (원인이 기록됩니다)")
        L.append("    · 모델이 response_format=json_schema 를 지원하는지")
        return "\n".join(L)

    hdr = f"  {'운행':<14}{'필드':<16}{'LLM':>14}{'정규식':>14}   판정"
    L.append(hdr)
    L.append("  " + "-" * (len(hdr) - 2))

    for r in payload["records"]:
        name = r["ride"]
        if r.get("llm") is None:
            L.append(f"  {name:<14}(LLM 추출 실패 — 이 건은 대조에서 제외)")
            continue
        diffs = r.get("mismatched_fields") or []
        if diffs:
            for f in diffs:
                L.append(f"  {name:<14}{f:<16}{str(r['llm'][f]):>14}"
                         f"{str(r['regex'][f]):>14}   불일치")
        else:
            L.append(f"  {name:<14}{'(전 필드)':<16}{'':>14}{'':>14}"
                     f"   일치  {r.get('latency_s')}s")

    tm = payload["mismatched_fields"]
    L.append("")
    L.append("=" * 74)
    L.append(f"  불일치 필드 {tm}건 / 대조된 {compared}필드 ({ok}건 × {len(FIELDS)}필드)")
    L.append("=" * 74)

    if tm:
        L.append("")
        L.append("  불일치를 감추지 않습니다. 해석은 이렇습니다:")
        L.append("    · 운행ID는 (차량해시, 운행일시, 출발지)로 컨트랙트가 직접 파생합니다.")
        L.append("      이 세 필드가 맞으면 중복 청구는 [I2]가 구조적으로 막습니다.")
        L.append("    · 금액 필드가 틀리면 컨트랙트는 못 막습니다. 막는 것은 회당 상한입니다 —")
        L.append("      과다 추출은 perRideCap 에서 절삭되어 피해가 상한으로 봉인됩니다.")
        L.append("    · 마을명이 틀리면 대장 조회에서 KeyError 로 끊겨 컨트랙트까지 가지 않습니다.")
    else:
        L.append("")
        L.append("  이번 실행에서는 오추출이 없었습니다.")
        L.append("  다만 이것이 'LLM은 틀리지 않는다'를 뜻하지는 않습니다 —")
        L.append("  표본 5건이고, 데모 로그는 포맷이 정연합니다.")
        L.append("  틀렸을 때 무슨 일이 벌어지는지는 selftest_api_path.py 가")
        L.append("  요금 자릿수를 일부러 틀리게 해서 보여줍니다.")
    return "\n".join(L)


def require_key() -> tuple[str, str, str]:
    base = os.environ.get("LLM_API_BASE")
    key = os.environ.get("LLM_API_KEY")
    model = os.environ.get("LLM_API_MODEL")
    if base and key and model:
        return base, key, model

    print("=" * 74)
    print("  실제 LLM 키가 설정되지 않았습니다. 비교를 수행할 수 없습니다.")
    print("=" * 74)
    for name, val in [("LLM_API_BASE", base), ("LLM_API_KEY", key), ("LLM_API_MODEL", model)]:
        print(f"    {name:<16} {'설정됨' if val else '없음'}")
    print()
    print("  이번 대조에 쓴 설정:")
    print("    LLM_API_BASE   https://api.orcarouter.ai/v1")
    print("    LLM_API_MODEL  gpt-5.6-luna")
    print()
    print("  대안 엔드포인트:")
    print("    OpenRouter  https://openrouter.ai/keys")
    print("    목록        https://github.com/cheahjs/free-llm-api-resources")
    print("    ※ 모델은 중단될 수 있습니다. 현재 서비스 중인 모델명을 확인하십시오.")
    print()
    print("  코드 경로만 검증하려면 목 서버 자체검사를 쓰십시오:")
    print("    python selftest_api_path.py")
    print()
    print("  기존 결과로 로그만 다시 그리려면:")
    print("    python run_llm_compare.py --from-json")
    print()
    print("  이 스크립트는 키 없이 결과를 만들어내지 않습니다.")
    raise SystemExit(2)


def write_log(payload: dict) -> Path:
    LOGS.mkdir(exist_ok=True)
    body = render(payload)
    hdr = (
        "=" * 74 + "\n"
        "실제 LLM vs 정규식 백엔드 대조 로그\n"
        + "=" * 74 + "\n"
        f"실행 시각 : {payload.get('ran_at', '(미기록)')}\n"
        f"명령      : python run_llm_compare.py\n"
        f"백엔드    : {payload['model']} @ {payload['endpoint']}\n"
        "\n"
        "※ 이 로그에는 API 키가 포함되지 않습니다. 키는 환경변수로만 읽고\n"
        "   출력하지 않으며, 엔드포인트와 에러 문자열은 extract.redact() 를\n"
        "   거칩니다. 그 동작은 no-key-leak-selftest.txt 가 표식 키로 검증합니다.\n"
        + "=" * 74 + "\n\n"
    )
    p = LOGS / "llm-compare.txt"
    p.write_text(hdr + body + "\n", encoding="utf-8")
    return p


def main() -> int:
    OUT.mkdir(exist_ok=True)

    # ── --from-json : API 호출 없이 기존 결과로 로그만 다시 그린다 ──
    if "--from-json" in sys.argv:
        src = OUT / "llm_compare.json"
        if not src.exists():
            print(f"  {src} 가 없습니다. 먼저 키를 넣고 실행하십시오.")
            return 2
        payload = json.loads(src.read_text(encoding="utf-8"))
        print(render(payload))
        p = write_log(payload)
        print(f"\n저장: {p}")
        return 0 if payload["llm_success"] else 3

    base, key, model = require_key()

    rows = []
    for name, text in load_rides():
        t0 = time.time()
        api = EX._extract_api(text)
        dt = time.time() - t0
        reg = EX._extract_regex(text)
        rows.append((name, api, reg, dt))

    records, total_mismatch = [], 0
    for name, a, r, dt in rows:
        if a is None:
            records.append({"ride": name, "llm": None, "regex": r.model_dump(),
                            "mismatched_fields": None, "latency_s": round(dt, 2)})
            continue
        diffs = [f for f in FIELDS if getattr(a, f) != getattr(r, f)]
        total_mismatch += len(diffs)
        records.append({"ride": name, "llm": a.model_dump(), "regex": r.model_dump(),
                        "mismatched_fields": diffs, "latency_s": round(dt, 2)})

    ok_cnt = sum(1 for rec in records if rec["llm"] is not None)

    payload = {
        "note": "실제 LLM API 호출 결과. 키는 기록하지 않음.",
        "ran_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "endpoint": EX.redact(base),
        "model": model,
        "rides": len(rows),
        "llm_success": ok_cnt,
        "mismatched_fields": total_mismatch,
        "compared_fields": ok_cnt * len(FIELDS),
        "api_errors": EX.LAST_API_ERRORS[:20],
        "records": records,
    }

    print(render(payload))
    (OUT / "llm_compare.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    p = write_log(payload)
    print(f"\n저장: {OUT / 'llm_compare.json'}")
    print(f"저장: {p}")

    # 성공 0건은 성공이 아니다. 종료 코드로도 구분한다.
    return 0 if ok_cnt else 3


if __name__ == "__main__":
    raise SystemExit(main())
