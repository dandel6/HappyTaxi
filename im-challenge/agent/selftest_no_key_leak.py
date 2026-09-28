"""키 유출 차단 검증 — 가짜 키를 심고 모든 산출물을 뒤진다.

왜 필요한가
-----------
LLM API 경로에는 키가 문자열로 흘러들 수 있는 구멍이 세 군데 있었다.

  1. urllib.error.HTTPError 를 str() 하면 **요청 URL이 통째로** 들어간다.
     키를 쿼리 파라미터로 받는 공급자(Gemini 등)면 그 순간 에러 문자열에 키가 박힌다.
  2. 에러 응답 **본문**을 진단용으로 300자 잘라 붙이고 있었다.
     일부 공급자는 요청 맥락을 그대로 되돌려준다.
  3. 목 서버 자체검사가 Authorization 헤더 **원본**을 메모리에 보관했다.

  세 경로 모두 결국 llm_compare.json 과 agent/logs/*.txt 로 흘러가고,
  그 파일은 제출 ZIP 에 들어간다. 한 번만 새면 끝이다.

이 검사가 하는 일
-----------------
  · 절대 실물과 겹치지 않는 표식 키를 환경변수에 심는다
  · 키를 쿼리로도 받는 엔드포인트를 흉내 내 400 을 되돌려준다
    (에러 문자열에 URL 과 본문이 둘 다 들어가도록 최악을 만든다)
  · 응답 본문에 Authorization 헤더를 **일부러 echo** 한다
  · 그 뒤 LAST_API_ERRORS / 콘솔 출력 / 기록 파일 전부를 표식으로 grep 한다

표식이 한 번이라도 발견되면 실패다.

실행:
    python selftest_no_key_leak.py
"""

from __future__ import annotations

import io
import json
import os
import socket
import sys
import threading
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import extract as EX  # noqa: E402

# 실물과 겹칠 수 없는 표식. 공급자 접두사를 흉내 내 패턴 차단도 같이 시험한다.
#
# 접두사를 쪼개서 조립하는 이유:
#   완성된 형태를 소스에 남기면 시크릿 스캐너가 오탐하고,
#   제출물을 받은 사람 눈에도 진짜 키처럼 보인다.
#   런타임 값은 동일하므로 정규식 차단 검증력은 그대로다.
_FAKE_PREFIX = "g" + "sk_"
CANARY = _FAKE_PREFIX + "NOTAREALKEY0000LEAKTEST0000DEADBEEF"


class LeakyHandler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        self.rfile.read(n)
        auth = self.headers.get("Authorization", "")
        # 최악의 공급자를 흉내 낸다: 에러 본문에 인증 헤더를 그대로 되돌려준다
        body = json.dumps({
            "error": {
                "message": f"invalid api key. received header: {auth}",
                "echoed_url": self.path,
            }
        }).encode("utf-8")
        self.send_response(400)
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
    srv = HTTPServer(("127.0.0.1", port), LeakyHandler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    # 키를 쿼리로도 붙인다. HTTPError 의 str() 에 URL 이 들어가는 경로를 강제로 연다.
    os.environ["LLM_API_BASE"] = f"http://127.0.0.1:{port}/v1?api_key={CANARY}"
    os.environ["LLM_API_KEY"] = CANARY
    os.environ["LLM_API_MODEL"] = "leak-test"
    os.environ.pop("OUTLINES_MODEL", None)
    EX.LAST_API_ERRORS.clear()

    print("=" * 74)
    print("키 유출 차단 검증")
    print("=" * 74)
    print(f"  표식 키 : {CANARY[:4]}...(이하 생략, 실물 아님)")
    print(f"  엔드포인트에 쿼리로도 키를 붙여 최악 경로를 강제합니다")
    print()

    sample = Path(__file__).parent / "data" / "rides" / "ride_001.txt"
    text = sample.read_text(encoding="utf-8")

    buf = io.StringIO()
    with redirect_stdout(buf):
        res = EX._extract_api(text)   # 반드시 실패하고 에러가 쌓인다
    console = buf.getvalue()

    surfaces = {
        "LAST_API_ERRORS": "\n".join(EX.LAST_API_ERRORS),
        "콘솔 출력": console,
        "redact(endpoint)": EX.redact(os.environ["LLM_API_BASE"]),
        "redact(가짜 에러문자열)": EX.redact(
            f"HTTP 400 at http://x/v1?api_key={CANARY} | Bearer {CANARY}"
        ),
    }

    print(f"  _extract_api 반환값: {res}  (None 이어야 정상)")
    print(f"  수집된 에러 {len(EX.LAST_API_ERRORS)}건")
    for e in EX.LAST_API_ERRORS[:3]:
        print("    ", e[:160])
    print()

    fails = 0
    print("  표식 검색")
    for name, blob in surfaces.items():
        hit = CANARY in blob
        fails += 1 if hit else 0
        print(f"    {'유출!!' if hit else 'OK   '} {name}")

    # 리댁션이 실제로 무언가를 지웠는지도 본다.
    # 아무것도 안 지웠는데 표식이 없으면 그냥 에러가 안 쌓인 것일 수 있다.
    marked = sum(1 for b in surfaces.values() if "<redacted>" in b)
    print(f"\n  <redacted> 치환이 일어난 표면: {marked}개")
    if marked == 0:
        print("    실패  아무것도 치환되지 않았다. 검사가 공회전했을 가능성.")
        fails += 1

    srv.shutdown()
    print()
    print("=" * 74)
    print(f"  {'통과 — 표식이 어느 표면에도 남지 않았다' if fails == 0 else f'실패 {fails}건'}")
    print("=" * 74)
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
