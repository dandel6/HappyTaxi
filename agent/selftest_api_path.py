"""LLM API 경로 자체검사 — 로컬 목 서버로 _extract_api 를 실제로 태운다.

★ 이것은 LLM 실행이 아니다.
  여기서 돌리는 것은 OpenAI 호환 **목 서버**이고, 응답은 우리가 만든다.
  증명하는 것은 "우리 HTTP 코드 경로가 맞다"이지 "LLM이 정확하다"가 아니다.
  실제 LLM 비교는 run_llm_compare.py 가 키를 받아서 수행한다.

왜 필요한가:
  extract.py 의 _extract_api 는 지금까지 **한 번도 실행된 적이 없었다.**
  except 가 모든 예외를 삼켜서, 실패해도 조용히 정규식 백엔드로 떨어졌다.
  그래서 시연 로그가 전부 [deterministic-regex] 였다.

  코드를 읽어보니 실제로 두 군데가 깨져 있었다:
    1. strict=True 인데 스키마에 additionalProperties:false 가 없었다
       → OpenAI 호환 서버는 이 조합을 400으로 거절한다
    2. except Exception: return None 이 원인을 통째로 삼켰다
       → 키를 넣어도 왜 LLM이 안 도는지 알 방법이 없었다

  이 검사는 그 두 가지가 고쳐졌는지 확인한다.

검사 항목:
  A. 요청이 json_schema + strict 모드로 나가는가 (첫 시도에서 성공하는가)
  B. 스키마에 additionalProperties:false 가 들어 있는가
  C. 응답 파싱 → pydantic 검증 → SubmissionPayload 변환이 끝까지 가는가
  D. LLM이 **틀린 값**을 줘도 파이프라인이 어떻게 반응하는가

실행:
    python selftest_api_path.py
"""

from __future__ import annotations

import json
import os
import re
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import extract as EX  # noqa: E402
from run_agent import DRIVER_OF_VEHICLE, VILLAGE_IDS, load_rides  # noqa: E402

# ── 목 서버가 관측한 요청을 기록한다 ──────────────────────────
OBSERVED: list[dict] = []

# ride_003 에만 의도적으로 틀린 요금을 심는다.
# 논지가 "AI가 틀려도 장부는 안 깨진다" 이므로 틀리는 경우를 반드시 보여야 한다.
WRONG_FARE_FOR = "논공리"
WRONG_FARE_VALUE = 98000  # 실제 9,800 → 0 하나 더 붙은 값


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # 서버 접근 로그 억제
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        req = json.loads(self.rfile.read(n).decode("utf-8"))
        OBSERVED.append({
            "path": self.path,
            # 헤더 원본을 보관하지 않는다. 존재 여부만 불리언으로 남긴다.
            # OBSERVED 는 로그로 덤프될 수 있고, 그 로그는 ZIP 으로 들어간다.
            "auth_present": self.headers.get("Authorization", "").startswith("Bearer "),
            "model": req.get("model"),
            "response_format": req.get("response_format"),
            "temperature": req.get("temperature"),
        })

        prompt = req["messages"][0]["content"]

        def grab(pat, cast=str):
            m = re.search(pat, prompt, re.MULTILINE)
            if not m:
                return None
            v = m.group(1).replace(",", "")
            return cast(v) if cast is not str else v

        village = grab(r"^출발지\s*[:：]\s*(\S+)")
        fare = grab(r"^당회운행요금[^:：\n]*[:：]\s*([\d,]+)", int)
        if village == WRONG_FARE_FOR:
            fare = WRONG_FARE_VALUE  # ← 의도적 오추출

        out = {
            "vehicle_no": grab(r"^차량번호\s*[:：]\s*(\S+)"),
            "ride_datetime": grab(r"^운행일시\s*[:：]\s*(\S+)"),
            "origin_village": village,
            "meter_fare_krw": fare,
            "distance_m": grab(r"^운행거리[^:：\n]*[:：]\s*([\d,]+)", int),
            "passengers": grab(r"^승차자수\s*[:：]\s*(\d+)", int),
            "fare_source": grab(r"^보조금\s*입력\s*방식\s*[:：]\s*(\S+)"),
        }

        body = json.dumps({
            "choices": [{"message": {"content": json.dumps(out, ensure_ascii=False)}}]
        }, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def main() -> int:
    port = free_port()
    srv = HTTPServer(("127.0.0.1", port), MockHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    os.environ["LLM_API_BASE"] = f"http://127.0.0.1:{port}/v1"
    os.environ["LLM_API_KEY"] = "mock-key-not-a-secret"
    os.environ["LLM_API_MODEL"] = "mock-model"
    os.environ.pop("OUTLINES_MODEL", None)

    print("=" * 74)
    print("LLM API 경로 자체검사 — 로컬 목 서버")
    print("=" * 74)
    print(f"  목 서버: http://127.0.0.1:{port}/v1   (실제 LLM 아님)")
    print()

    fails = 0
    rows = []
    for name, text in load_rides():
        api_res, api_backend = EX.extract(text)
        reg_res = EX._extract_regex(text)
        rows.append((name, api_backend, api_res, reg_res))

    # ── A. 백엔드가 실제로 API 경로였는가 ──────────────────
    print("[A] 백엔드 선택")
    for name, backend, _, _ in rows:
        ok = backend == "free-llm-api"
        fails += 0 if ok else 1
        print(f"    {'OK ' if ok else '실패'} {name}  backend={backend}")
    if EX.LAST_API_ERRORS:
        print("    API 오류 기록:")
        for e in EX.LAST_API_ERRORS[:5]:
            print("      ", e[:150])

    # ── B. 요청 형태 ────────────────────────────────────
    print("\n[B] 요청 형태 (목 서버가 실제로 받은 것)")
    if not OBSERVED:
        print("    실패  요청이 한 건도 도달하지 않았다")
        fails += 1
    else:
        o = OBSERVED[0]
        rf = o["response_format"] or {}
        checks = [
            ("경로가 /v1/chat/completions", o["path"].endswith("/chat/completions")),
            ("Authorization 헤더 존재", o["auth_present"]),
            ("response_format.type == json_schema", rf.get("type") == "json_schema"),
            ("strict == True", (rf.get("json_schema") or {}).get("strict") is True),
            ("additionalProperties == False",
             (rf.get("json_schema") or {}).get("schema", {}).get("additionalProperties") is False),
            ("temperature == 0", o["temperature"] == 0),
            ("첫 시도에서 성공(폴백 안 탐)", len(OBSERVED) == len(rows)),
        ]
        for label, ok in checks:
            fails += 0 if ok else 1
            print(f"    {'OK ' if ok else '실패'} {label}")

    # ── C/D. 값 비교 ────────────────────────────────────
    print("\n[C] API 백엔드 vs 정규식 백엔드 — 필드별 비교")
    hdr = f"    {'운행':<13}{'필드':<16}{'API':>12}{'정규식':>12}   판정"
    print(hdr)
    print("    " + "-" * (len(hdr) - 4))
    mismatches = []
    for name, _, a, r in rows:
        if a is None:
            print(f"    {name:<13}(API 추출 실패)")
            fails += 1
            continue
        for f in type(a).model_fields:
            av, rv = getattr(a, f), getattr(r, f)
            if av != rv:
                mismatches.append((name, f, av, rv))
                print(f"    {name:<13}{f:<16}{str(av):>12}{str(rv):>12}   불일치")
    if not mismatches:
        print("    모든 필드 일치")

    print("\n[D] 불일치 해석")
    if mismatches:
        for name, f, av, rv in mismatches:
            print(f"    {name} · {f}: API={av} / 정규식={rv}")
        print()
        print("    이 건은 목 서버에 **의도적으로 심은 오추출**이다.")
        print("    실제 LLM도 자릿수를 틀리는 종류의 오류를 낸다.")
        print("    주목할 점은 컨트랙트가 이걸 못 막는다는 것이다 —")
        print("    운행ID는 (차량해시, 운행일시, 출발지)로 파생되므로 요금이 틀려도 ID는 같다.")
        print("    [I2] 중복 청구는 막지만 **금액 오류는 막지 못한다.**")
        print("    막는 것은 회당 상한(perRideCap)이다. 9,800 → 98,000 이 되어도")
        print("    보조금은 상한 10,000원에서 절삭된다. 피해가 상한으로 봉인된다.")
        print("    상한이 없었다면 이 한 건이 예산을 통째로 먹었을 것이다.")
    else:
        print("    불일치 없음 — 오추출 주입에 실패했다. 검사 자체가 약해진 것이다.")
        fails += 1

    srv.shutdown()
    print()
    print("=" * 74)
    print(f"  자체검사 {'통과' if fails == 0 else f'실패 {fails}건'}")
    print("=" * 74)
    print("  다시 강조: 이건 목 서버다. 실제 LLM 비교는 run_llm_compare.py.")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
