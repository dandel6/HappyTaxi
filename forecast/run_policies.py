"""3정책 비교 시뮬레이션 — 합성 행복택시 보조금 시계열 전용.

이 스크립트의 출력으로 예측 정확도를 주장하지 않는다.
합성 데이터는 반사실 비교에만 쓴다. 실측 검증은 run_backtest.py.

실행:
    python run_policies.py
"""

from __future__ import annotations

import json
from datetime import date
from pathlib import Path

from subsidy_forecast.synthetic import (
    GeneratorParams, generate_accruals, simulate,
)

ROOT = Path(__file__).parent
OUT = ROOT / "out"
START = date(2026, 1, 1)
POLICIES = ["first_come", "equal", "priority"]
LABELS = {
    "first_come": "선착순 (현행)",
    "equal": "균등",
    "priority": "우선순위",
}


def main() -> None:
    OUT.mkdir(exist_ok=True)
    p = GeneratorParams()

    print("=" * 78)
    print("3정책 비교 시뮬레이션 (합성 행복택시 보조금 시계열)")
    print("=" * 78)
    print()
    print("경고: 합성 데이터입니다. 이 결과로 예측 정확도를 주장하지 않습니다.")
    print("      반사실 비교 전용 — 대구시는 선착순 하나만 집행했고")
    print("      나머지 둘의 결과는 현실에서 관측되지 않습니다.")
    print()

    print("-" * 78)
    print("생성기 파라미터 (전량 공개)")
    print("-" * 78)
    for name, val, basis in p.as_public_table():
        print(f"  {name:<24}{str(val):<12}{basis}")
    print()

    accruals = generate_accruals(p, START)
    total_accrued = sum(a.amount for a in accruals)
    print(f"생성된 청구 건수: {len(accruals):,}건")
    print(f"총 청구액: {total_accrued:,} 보조금")
    print(f"정산 예산: {p.budget:,} 보조금 "
          f"(청구의 {p.budget/total_accrued*100:.1f}%)")
    print()
    print("  예산이 청구보다 작다 — 이것이 문제의 본질이다.")
    print("  발행은 여러 기관에서 일어나고 정산 예산은 시 하나가 댄다.")
    print()

    results = {}
    for pol in POLICIES:
        results[pol] = simulate(p, accruals, pol, START)

    print("-" * 78)
    print("정책별 결과")
    print("-" * 78)
    hdr = f"{'정책':<16}{'소진일':>8}{'정산총액':>14}{'수혜자':>8}{'미지급자':>9}{'미지급액':>14}{'지니':>7}"
    print(hdr)
    for pol in POLICIES:
        r = results[pol]
        ex = f"D+{r.exhausted_on_day}" if r.exhausted_on_day is not None else "미소진"
        print(f"{LABELS[pol]:<16}{ex:>8}{r.total_converted:>14,}"
              f"{r.citizens_served:>8,}{r.citizens_with_unfunded:>9,}"
              f"{r.total_unfunded:>14,}{r.gini:>7.3f}")
    print()

    # 해석
    fc = results["first_come"]
    eq = results["equal"]
    pr = results["priority"]
    print("-" * 78)
    print("해석")
    print("-" * 78)
    def _ex(r):
        return f"D+{r.exhausted_on_day}" if r.exhausted_on_day is not None else "미소진"

    print(f"  소진 시점:   선착순 {_ex(fc)} / 균등 {_ex(eq)} / 우선순위 {_ex(pr)}")
    print(f"  지니계수:   선착순 {fc.gini:.3f} / 균등 {eq.gini:.3f} / 우선순위 {pr.gini:.3f}")
    print(f"  미지급자:   선착순 {fc.citizens_with_unfunded:,}명 / "
          f"균등 {eq.citizens_with_unfunded:,}명 / 우선순위 {pr.citizens_with_unfunded:,}명")
    print()
    print("  읽는 법:")
    print("   · 선착순은 상한이 없어 이른 수요가 예산을 당긴다. 예산이 날짜로 끝난다.")
    print("   · 균등은 1인당 상한을 걸어 기간 끝까지 버틴다. 집중도가 가장 낮다.")
    print("   · 우선순위는 소진을 가장 길게 늦추지만 지니가 가장 높다 —")
    print("     오래 기다린 사람은 많이 쌓인 적극 이용자이기도 해서이다.")
    print("     공평해 보이는 기준이 실제로는 집중을 키울 수 있다.")
    print()
    print("  어느 정책도 예산 총액을 늘리지 못한다. 바꾸는 것은 분배뿐이다.")
    print("  이 시뮬레이션은 정답을 고르지 않는다. 운영자가 고르도록")
    print("  세 결과를 나란히 보여줄 뿐이다 — 판단 지원이지 자동 통제가 아니다.")
    print()

    # 저장
    payload = {
        "disclaimer": "합성 데이터. 예측 정확도 주장에 사용 금지. 정책 비교 전용.",
        "generator_params": {k: v for k, v, _ in
                             [(n, val, b) for n, val, b in p.as_public_table()]},
        "generator_basis": {n: b for n, _, b in p.as_public_table()},
        "total_accrued": total_accrued,
        "budget": p.budget,
        "results": {
            pol: {
                "label": LABELS[pol],
                "exhausted_on_day": r.exhausted_on_day,
                "total_converted": r.total_converted,
                "citizens_served": r.citizens_served,
                "citizens_with_unfunded": r.citizens_with_unfunded,
                "total_unfunded": r.total_unfunded,
                "gini": round(r.gini, 4),
            } for pol, r in results.items()
        },
    }
    (OUT / "policy_comparison.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"저장: {OUT/'policy_comparison.json'}")

    # 차트
    try:
        _chart(results, p)
        print(f"저장: {OUT/'policy_comparison.png'}")
    except ImportError:
        print("matplotlib 없음 — 차트 생략. pip install matplotlib")


def _chart(results: dict, p: GeneratorParams) -> None:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib import font_manager

    for cand in ["Malgun Gothic", "AppleGothic", "NanumGothic"]:
        if any(f.name == cand for f in font_manager.fontManager.ttflist):
            plt.rcParams["font.family"] = cand
            break
    plt.rcParams["axes.unicode_minus"] = False

    fig, axes = plt.subplots(1, 2, figsize=(13, 5))

    ax = axes[0]
    for pol in POLICIES:
        r = results[pol]
        ax.plot(r.daily_remaining, label=LABELS[pol], linewidth=2)
    ax.set_title("예산 잔액 추이")
    ax.set_xlabel("경과일")
    ax.set_ylabel("잔여 예산 (보조금)")
    ax.legend()
    ax.grid(alpha=0.3)

    ax = axes[1]
    for pol in POLICIES:
        r = results[pol]
        vals = sorted(r.per_citizen_converted, reverse=True)
        ax.plot(vals, label=f"{LABELS[pol]} (지니 {r.gini:.3f})", linewidth=2)
    ax.set_title("기사별 정산액 분포 (내림차순)")
    ax.set_xlabel("기사 순위")
    ax.set_ylabel("정산액 (보조금)")
    ax.legend()
    ax.grid(alpha=0.3)

    fig.suptitle("행복택시 보조금 3정책 비교 — 합성 데이터 (예측 정확도 주장 아님)",
                 fontsize=12)
    fig.tight_layout()
    fig.savefig(OUT / "policy_comparison.png", dpi=140)


if __name__ == "__main__":
    main()
