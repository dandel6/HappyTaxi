"""budget 파라미터 민감도 분석 — 3정책 비교 결과가 예산 가정에 얼마나 민감한가.

왜 필요한가
-----------
GeneratorParams.budget 은 근거 없는 임의값이다(기본 135,000,000 = 총 청구의 64.7%).
그런데 3정책 비교의 결론 전체가 이 한 값 위에 서 있다. 값이 바뀌면 순위가
뒤집히는지 확인하지 않으면, 제안서의 정책 비교표는 "임의로 고른 한 점에서만
참인 주장"이 된다.

이 스크립트는 budget 을 총 청구 대비 비율로 바꿔가며 세 가지를 본다:
    1. 지니 순위 (우선순위 > 선착순 > 균등) 가 유지되는가
    2. 다른 순위 관계가 뒤집히는 구간이 있는가
    3. 시드를 바꿔도 같은 결론인가 (= 시뮬레이션 잡음이 아닌가)

budget 을 바꾸면 청구 시계열은 그대로이고 배분만 달라진다.
generate_accruals 는 budget 을 참조하지 않으므로 같은 유입에 대한
순수한 재정 규모 효과만 측정된다.

실행:
    python run_sensitivity.py
"""

from __future__ import annotations

import json
import statistics as st
from dataclasses import replace
from datetime import date
from pathlib import Path

from subsidy_forecast.synthetic import (
    GeneratorParams, generate_accruals, simulate,
)

ROOT = Path(__file__).parent
OUT = ROOT / "out"
START = date(2026, 1, 1)

POLICIES = ["first_come", "equal", "priority"]
LABELS = {"first_come": "선착순", "equal": "균등", "priority": "우선순위"}

# 제안서에 싣는 세 값
HEADLINE_RATIOS = [0.50, 0.65, 0.80]

# 교차점 탐색용 확장 구간
SWEEP_RATIOS = [0.40, 0.50, 0.60, 0.65, 0.70, 0.80, 0.90, 1.00, 1.10]

# 시드 변동이 결론을 바꾸는지 확인. 첫 값이 기본 시드.
SEEDS = [20260920, 101, 202, 303, 404, 505, 606, 707]


def run(seed: int, ratio: float) -> tuple[int, dict]:
    """한 시드·한 비율에서 3정책을 모두 돌린다."""
    bp = replace(GeneratorParams(), seed=seed)
    accruals = generate_accruals(bp, START)
    total = sum(r.amount for r in accruals)
    p = replace(bp, budget=int(total * ratio))
    return total, {pol: simulate(p, accruals, pol, START) for pol in POLICIES}


def _day(r) -> str:
    return "미소진" if r.exhausted_on_day is None else f"D+{r.exhausted_on_day}"


def main() -> None:
    OUT.mkdir(exist_ok=True)
    base_seed = SEEDS[0]

    # ── 1. 기본 시드에서의 헤드라인 표 ──────────────────────────
    print("=" * 74)
    print("1. budget 민감도 — 기본 시드")
    print("=" * 74)
    total, _ = run(base_seed, 1.0)
    print(f"총 청구 {total:,} 보조금 (시드 {base_seed})")
    print(f"기본 budget 135,000,000 = 총 청구의 {135_000_000/total*100:.1f}%\n")

    print(f"{'비율':>5s} {'budget':>14s} {'정책':>7s} {'소진일':>7s} "
          f"{'미지급자':>7s} {'지니':>6s} {'정산총액':>14s}")
    print("-" * 74)

    headline = {}
    for ratio in HEADLINE_RATIOS:
        total, res = run(base_seed, ratio)
        for pol in POLICIES:
            r = res[pol]
            headline[(ratio, pol)] = r
            print(f"{ratio*100:4.0f}% {int(total*ratio):14,d} {LABELS[pol]:>7s} "
                  f"{_day(r):>7s} {r.citizens_with_unfunded:7d} {r.gini:6.3f} "
                  f"{r.total_converted:14,d}")
        print()

    # ── 2. 순위 안정성 ────────────────────────────────────────
    print("=" * 74)
    print("2. 순위 관계 — 뒤집히는 구간이 있는가")
    print("=" * 74)

    for ratio in HEADLINE_RATIOS:
        order = sorted(POLICIES, key=lambda x: -headline[(ratio, x)].gini)
        line = " > ".join(f"{LABELS[o]} {headline[(ratio,o)].gini:.3f}" for o in order)
        flag = "유지" if order[0] == "priority" else "뒤집힘"
        print(f"  지니     {ratio*100:3.0f}%  {line}   [{flag}]")
    print()
    for ratio in HEADLINE_RATIOS:
        order = sorted(POLICIES, key=lambda x: headline[(ratio, x)].citizens_with_unfunded)
        line = " < ".join(f"{LABELS[o]} {headline[(ratio,o)].citizens_with_unfunded}" for o in order)
        print(f"  미지급자 {ratio*100:3.0f}%  {line}")
    print()
    for ratio in HEADLINE_RATIOS:
        def k(x):
            d = headline[(ratio, x)].exhausted_on_day
            return 10**9 if d is None else d
        order = sorted(POLICIES, key=lambda x: -k(x))
        line = " > ".join(f"{LABELS[o]} {_day(headline[(ratio,o)])}" for o in order)
        print(f"  소진일   {ratio*100:3.0f}%  {line}")

    # ── 3. 시드 변동 ──────────────────────────────────────────
    print()
    print("=" * 74)
    print(f"3. 시드 변동 — 잡음인가 구조인가 (시드 {len(SEEDS)}개)")
    print("=" * 74)

    robust = {}
    for ratio in HEADLINE_RATIOS:
        g = {pol: [] for pol in POLICIES}
        unf = {pol: [] for pol in POLICIES}
        for sd in SEEDS:
            _, res = run(sd, ratio)
            for pol in POLICIES:
                g[pol].append(res[pol].gini)
                unf[pol].append(res[pol].citizens_with_unfunded)

        gaps = [a - b for a, b in zip(g["priority"], g["first_come"])]
        top = sum(1 for i in range(len(SEEDS))
                  if max(POLICIES, key=lambda x: g[x][i]) == "priority")
        best_unf = [min(POLICIES, key=lambda x: unf[x][i]) for i in range(len(SEEDS))]

        robust[ratio] = {
            "gini_mean": {p: round(st.mean(g[p]), 4) for p in POLICIES},
            "gini_sd": {p: round(st.pstdev(g[p]), 4) for p in POLICIES},
            "priority_top_gini_seeds": f"{top}/{len(SEEDS)}",
            "gap_priority_minus_firstcome_min": round(min(gaps), 4),
            "fewest_unfunded_policy": max(set(best_unf), key=best_unf.count),
        }

        print(f"  {ratio*100:3.0f}%")
        for pol in POLICIES:
            print(f"     {LABELS[pol]:>5s} 지니 {st.mean(g[pol]):.3f} ± {st.pstdev(g[pol]):.3f}")
        print(f"     우선순위 최고집중: {top}/{len(SEEDS)} 시드, "
              f"선착순 대비 최소격차 {min(gaps):+.3f}")
        print(f"     미지급자 최소 정책: {LABELS[max(set(best_unf), key=best_unf.count)]}")

    # ── 4. 교차점 탐색 ────────────────────────────────────────
    print()
    print("=" * 74)
    print("4. 교차점 — 우선순위 > 선착순 은 어디까지 성립하는가")
    print("=" * 74)
    print(f"{'비율':>5s} {'우선순위':>8s} {'선착순':>7s} {'균등':>6s} "
          f"{'격차':>8s} {'유지시드':>8s}")
    print("-" * 74)

    sweep = {}
    probe = SEEDS[:4]
    for ratio in SWEEP_RATIOS:
        g = {pol: [] for pol in POLICIES}
        for sd in probe:
            _, res = run(sd, ratio)
            for pol in POLICIES:
                g[pol].append(res[pol].gini)
        gaps = [a - b for a, b in zip(g["priority"], g["first_come"])]
        win = sum(1 for x in gaps if x > 0)
        sweep[ratio] = round(st.mean(gaps), 4)
        print(f"{ratio*100:4.0f}% {st.mean(g['priority']):8.3f} "
              f"{st.mean(g['first_come']):7.3f} {st.mean(g['equal']):6.3f} "
              f"{st.mean(gaps):+8.3f} {win:5d}/{len(probe)}")

    print()
    print("  예산이 총 청구을 넘어서면(100%+) 희소성이 사라져 세 정책이 같아진다.")
    print("  그 지점에서 격차가 0으로 수렴하는 것은 순위 역전이 아니라 문제의 소멸이다.")

    # ── 저장 ──────────────────────────────────────────────────
    payload = {
        "note": "budget 민감도. 청구 시계열은 budget과 무관하므로 순수 재정 규모 효과.",
        "base_seed": base_seed,
        "total_accruals": total,
        "default_budget_ratio": round(135_000_000 / total, 4),
        "headline": {
            f"{int(r*100)}%": {
                LABELS[p]: {
                    "exhausted_on_day": headline[(r, p)].exhausted_on_day,
                    "citizens_with_unfunded": headline[(r, p)].citizens_with_unfunded,
                    "gini": round(headline[(r, p)].gini, 4),
                    "total_converted": headline[(r, p)].total_converted,
                } for p in POLICIES
            } for r in HEADLINE_RATIOS
        },
        "robustness_across_seeds": {f"{int(r*100)}%": robust[r] for r in HEADLINE_RATIOS},
        "gini_gap_priority_minus_firstcome_by_ratio": {
            f"{int(r*100)}%": sweep[r] for r in SWEEP_RATIOS
        },
    }
    (OUT / "budget_sensitivity.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n저장: {OUT/'budget_sensitivity.json'}")


if __name__ == "__main__":
    main()
