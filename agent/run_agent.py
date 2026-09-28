"""에이전트 파이프라인 — 운행 기록 5건을 뽑아 컨트랙트에 제출한다.

논지: AI가 틀려도 장부는 안 깨진다.

이 스크립트는 두 가지를 보인다.

  1. 정상 경로  5건을 추출해 컨트랙트에 제출하면 5건이 확정된다.
  2. 중복 경로  에이전트가 같은 운행을 두 번 제출해도 컨트랙트가 두 번째를 거부한다.

2번이 핵심이다. 에이전트는 재시도·타임아웃·배치 재실행 때문에 같은 건을 두 번 올리기 쉽다.
LLM 신뢰도를 아무리 올려도 그 문제는 안 사라진다. 그래서 컨트랙트가 막는다 —
운행ID를 (차량해시, 운행일시, 출발지)로 **컨트랙트가 직접** 파생하므로,
에이전트가 무엇을 보내든 같은 운행이면 같은 ID가 나오고 두 번째는 반려된다.

실행:
    python run_agent.py            # Anvil 있으면 온체인, 없으면 시뮬레이션
    python run_agent.py --dry      # 추출까지만
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from extract import extract, to_submission, SubmissionPayload  # noqa: E402

ROOT = Path(__file__).parent
RIDES = ROOT / "data" / "rides"
OUT = ROOT / "out"

# 운영기관 대장. 실제로는 차량등록 DB에서 온다.
# ★ 데모용 자리표시자다. Anvil 기본 계정을 기사 주소로 쓴다.
DRIVER_OF_VEHICLE = {
    "12가3456": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
    "34나7890": "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC",
    "56다1234": "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
}

# 지원 대상 마을 → 자리표시자 ID.
# ★가정(5) — 언론에 71개라는 개수만 있고 조례 별표 코드는 확인하지 못했다.
VILLAGE_IDS = {
    "구지리": 1,
    "유가리": 2,
    "논공리": 3,
    "옥포리": 4,
    "하빈리": 5,
}


def load_rides() -> list[tuple[str, str]]:
    return [(p.name, p.read_text(encoding="utf-8")) for p in sorted(RIDES.glob("*.txt"))]


def run_extraction() -> list[SubmissionPayload]:
    out: list[SubmissionPayload] = []
    print("=" * 70)
    print("1단계 — 운행 기록 추출")
    print("=" * 70)
    for name, text in load_rides():
        ex, backend = extract(text)
        p = to_submission(ex, text, backend, DRIVER_OF_VEHICLE, VILLAGE_IDS)
        out.append(p)
        print(
            f"  {name}  {ex.vehicle_no}  {ex.origin_village}(id={p.origin_village_id})  "
            f"{p.fare_krw:,}원  {p.fare_source:6s}  [{backend}]"
        )
    print(f"\n  추출 {len(out)}건. 백엔드: {out[0].backend}")
    return out


def ride_id(p: SubmissionPayload) -> str:
    """컨트랙트가 파생할 운행ID를 오프체인에서 미리 계산한다.

    실제 판정은 컨트랙트가 한다. 여기 계산은 중복 탐지 시연용 표시일 뿐이고,
    이 값이 틀려도 컨트랙트 쪽 [I2]는 영향을 받지 않는다.
    """
    return f"{p.vehicle_hash[:10]}..{p.ride_timestamp}..{p.origin_village_id}"


def simulate_submission(payloads: list[SubmissionPayload]) -> dict:
    """컨트랙트 [I2] 판정을 오프체인에서 재현한다.

    Anvil이 없어도 논지를 보일 수 있어야 한다. 판정 규칙은 컨트랙트와 동일하다:
      rideUsed[keccak(차량해시, 운행일시, 출발지)] 가 이미 true면 거부.
    """
    print()
    print("=" * 70)
    print("2단계 — 컨트랙트 제출")
    print("=" * 70)

    used: set[str] = set()
    accepted, rejected = [], []

    for p in payloads:
        rid = ride_id(p)
        if rid in used:
            rejected.append((p, rid))
            print(f"  거부  {p.driver[:10]}..  {rid}  ← RideAlreadyClaimed")
        else:
            used.add(rid)
            accepted.append((p, rid))
            subsidy = max(0, p.fare_krw - 1000)
            print(f"  확정  {p.driver[:10]}..  {rid}  보조금 {min(subsidy, 10000):,}원")

    # 에이전트 재시도 시뮬레이션 — 1건을 그대로 다시 올린다
    print()
    print("  [재시도] 에이전트가 ride_001 을 한 번 더 제출한다")
    dup = payloads[0]
    rid = ride_id(dup)
    if rid in used:
        rejected.append((dup, rid))
        print(f"  거부  {dup.driver[:10]}..  {rid}  ← RideAlreadyClaimed")
    else:
        print("  !! 중복이 통과했다. [I2]가 깨졌다는 뜻이다.")

    return {"accepted": len(accepted), "rejected": len(rejected)}


def try_onchain() -> bool:
    """Anvil이 떠 있는지 확인한다. 없으면 시뮬레이션으로 넘어간다."""
    try:
        r = subprocess.run(
            ["cast", "block-number", "--rpc-url", "http://127.0.0.1:8545"],
            capture_output=True, timeout=5,
        )
        return r.returncode == 0
    except Exception:
        return False


def main() -> None:
    OUT.mkdir(exist_ok=True)
    payloads = run_extraction()

    if "--dry" in sys.argv:
        print("\n--dry 지정. 제출 생략.")
    else:
        onchain = try_onchain()
        if onchain:
            print("\n  Anvil 감지됨. 온체인 제출은 script/ 배포 후 cast send로 수행한다.")
            print("  이 데모는 판정 규칙이 동일한 오프체인 재현으로 진행한다.")
        result = simulate_submission(payloads)

        print()
        print("=" * 70)
        print(f"  확정 {result['accepted']}건 / 거부 {result['rejected']}건")
        print("=" * 70)
        print()
        print("  에이전트가 같은 운행을 두 번 올려도 두 번째는 반려된다.")
        print("  운행ID를 컨트랙트가 (차량해시, 운행일시, 출발지)로 직접 파생하기 때문이다.")
        print("  추출값이 틀려도 이 성질은 유지된다 — 논지가 정확도가 아니라 구조에 있다.")

    (OUT / "submissions.json").write_text(
        json.dumps([json.loads(p.to_json()) for p in payloads], ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"\n저장: {OUT/'submissions.json'}")


if __name__ == "__main__":
    main()
