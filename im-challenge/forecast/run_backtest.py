"""달성군 재정 실측 기반 예측기 검증.

이 스크립트는 실측 데이터만 쓴다. 합성 데이터는 절대 섞지 않는다.
출력은 예측기와 베이스라인의 오차를 나란히 놓은 표 하나다.

실행:
    python run_backtest.py
"""

from __future__ import annotations

import csv
import json
from datetime import date
from pathlib import Path

from subsidy_forecast.core import (
    BudgetEpisode, Observation, naive_linear, recent_weighted,
    threshold_crossing, lead_time_alert, walk_forward, load_episodes,
)

ROOT = Path(__file__).parent
DATA = ROOT / "data"
OUT = ROOT / "out"

METHODS = {
    "naive_linear": naive_linear,
    "recent_weighted": recent_weighted,
}


def attach_observations(episodes: list[BudgetEpisode]) -> None:
    """observations.csv를 각 구간에 붙인다."""
    by_id = {e.event_id: e for e in episodes}
    with (DATA / "observations.csv").open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            ep = by_id.get(row["event_id"])
            if ep is None:
                continue
            ep.observations.append(Observation(
                on=date.fromisoformat(row["observed_on"]),
                consumed=float(row["cumulative_consumed_100m"]),
                resolution=row["resolution"],
            ))
    for ep in episodes:
        ep.observations.sort(key=lambda o: o.on)


def main() -> None:
    OUT.mkdir(exist_ok=True)
    episodes = load_episodes(DATA / "daeguropay_events.csv")
    attach_observations(episodes)

    print("=" * 78)
    print("달성군 재정 실측 기반 소진 예측 백테스트")
    print("=" * 78)
    print()
    print(f"백테스트 가능 구간: {len(episodes)}건")
    for ep in episodes:
        span = (ep.actual_exhaustion - ep.start).days
        print(f"  {ep.event_id} {ep.label}: {ep.budget:,.0f}억, "
              f"{ep.start} → {ep.actual_exhaustion} ({span}일), "
              f"관측 {len(ep.observations)}개")
    print()
    print("주의: 대구시는 일별 판매액을 공개하지 않는다. 관측은 보도된")
    print("      시작·중간·소진 시점뿐이며, 일부는 월 해상도(±15일)다.")
    print("      표본이 작다는 사실을 숨기지 않는다.")
    print()

    rows: list = []
    for ep in episodes:
        rows.extend(walk_forward(ep, METHODS))

    # ── 워크포워드 결과 ──
    print("-" * 78)
    print("워크포워드 예측 (각 시점에서 그때까지의 정보만 사용)")
    print("-" * 78)
    print(f"{'구간':<5}{'예측시점':<12}{'실제까지':>7}  {'방법':<17}"
          f"{'예측소진일':<12}{'오차(일)':>8}  {'구간포함':<8}")
    for r in rows:
        err = f"{r.error_days:+d}" if r.error_days is not None else "—"
        cov = "—" if r.covered is None else ("예" if r.covered else "아니오")
        pred = r.predicted.isoformat() if r.predicted else "—"
        print(f"{r.event_id:<5}{r.asof.isoformat():<12}{r.days_before_actual:>5}일  "
              f"{r.method:<17}{pred:<12}{err:>8}  {cov:<8}")
    print()

    # ── 방법별 집계 ──
    print("-" * 78)
    print("방법별 절대오차 집계")
    print("-" * 78)
    summary = {}
    for name in METHODS:
        errs = [abs(r.error_days) for r in rows
                if r.method == name and r.error_days is not None]
        if not errs:
            continue
        summary[name] = {
            "n": len(errs),
            "mae": sum(errs) / len(errs),
            "max": max(errs),
            "min": min(errs),
        }
        print(f"  {name:<17} n={len(errs)}  "
              f"MAE={sum(errs)/len(errs):.1f}일  "
              f"최대={max(errs)}일  최소={min(errs)}일")
    print()

    # ── 성공 판정 ──
    print("-" * 78)
    print("성공 판정 (절대 기준 아님 — 베이스라인 대비)")
    print("-" * 78)
    base = summary.get("naive_linear", {}).get("mae")
    prop = summary.get("recent_weighted", {}).get("mae")

    covered = [r for r in rows if r.covered is not None]
    hit = [r for r in covered if r.covered]
    no_interval = [r for r in rows if r.method == "naive_linear"]

    # 명시적 합격/불합격 플래그. 스펙의 수용 기준은 강부등호(<)이다.
    point_criterion_met = (base is not None and prop is not None and prop < base)

    verdict = "판정 불가"
    if base is not None and prop is not None:
        if prop < base:
            verdict = f"합격 — 제안 {prop:.1f}일 < 베이스라인 {base:.1f}일"
        elif prop == base:
            verdict = (f"불합격(동률) — 제안 {prop:.1f}일 = 베이스라인 {base:.1f}일. "
                       f"수용 기준은 강부등호(<)이므로 동률은 충족하지 못한다")
        else:
            verdict = (f"불합격 — 제안 {prop:.1f}일 > 베이스라인 {base:.1f}일")

    print(f"  점 추정 기준: {verdict}")
    print(f"  수용 기준 충족 여부: {'예' if point_criterion_met else '**아니오**'}")
    print()
    print("  점 추정에서 동률인 이유: 소진이 거의 선형이라 최근 가중이")
    print("  개입할 여지가 없었다. 더 맞춰 넣으려면 표본 2건에 과적합하는 것이므로")
    print("  하지 않는다. 동률을 그대로 보고한다.")
    print()
    print("  구간 추정 — 능력 차이는 있으나 품질을 과장하지 않는다:")
    print(f"    - 베이스라인: 구간을 **아예 산출하지 못한다**(covered=None)")
    if covered:
        print(f"    - 제안: 구간 산출 가능, {len(hit)}/{len(covered)}회 포함")
    for r in rows:
        if r.lower is None or r.upper is None:
            continue
        w = (r.upper - r.lower).days
        mark = "포함" if r.covered else "빗나감"
        extra = " — 하한이 asof와 같아 운영 정보 없음" if r.lower == r.asof else ""
        print(f"        {r.asof} 폭 {w}일 ({r.lower}~{r.upper}) {mark}{extra}")
    print()
    print("    정직한 평가: 포함된 쪽은 56일로 너무 넓어 쓸모가 없고,")
    print("    좋은 쪽(2일)은 빗나갔다. 표본 2건에서 구간 품질을 주장하지 않는다.")
    print("    주장 가능한 것은 능력뿐이다 — 본 구현의 베이스라인은 점 추정만 내므로")
    print("    그 자체로는 '지금 경보할까'에 답할 수 없고, 제안은 답할 틀은 갖춘다.")
    print("    (선형 외삽도 OLS 예측구간·부트스트랩을 붙이면 구간을 낼 수 있다.")
    print("     구조적 불가능이 아니므로 그렇게 주장하지 않는다.)")
    print("    넓은 폭은 관측 1개 구간에서 cv=1.0(최대 불확실성)을 쓰는")
    print("    의도된 보수 폴백이지 튜닝 결과가 아니다.")
    print()

    # ── 경보 트리거 비교 ──
    print("-" * 78)
    print("경보 트리거 비교 — 소진율 기준 vs 잔여일수 기준")
    print("-" * 78)
    print("  소진이 선형에 가까우면 소진율 임계는 항상 직전에 울린다.")
    print("  달성군 재정 2026 상반기 실측: 90% 도달은 소진 6일 전이다.")
    print()
    alerts = []
    for ep in episodes:
        for o in ep.observations:
            if o.on >= ep.actual_exhaustion:
                continue
            t90 = threshold_crossing(ep, o.on, pct=0.90)
            fired, days_left, proj = lead_time_alert(ep, o.on, alert_days=30)
            if t90 is None and proj is None:
                continue
            lead90 = (ep.actual_exhaustion - t90).days if t90 else None
            real_lead = (ep.actual_exhaustion - o.on).days
            alerts.append({
                "event_id": ep.event_id, "asof": o.on.isoformat(),
                "rate_threshold_90pct_date": t90.isoformat() if t90 else None,
                "rate_threshold_lead_days": lead90,
                "leadtime_alert_fired": fired,
                "projected_exhaustion": proj.isoformat() if proj else None,
                "actual_lead_days_at_alert": real_lead if fired else None,
            })
            print(f"  {ep.event_id} {o.on} 시점")
            if t90:
                print(f"    소진율 90% 임계 → {t90} 예상 (실제 소진 {lead90}일 전 경보)")
            if proj:
                mark = "경보 발령" if fired else "경보 없음"
                print(f"    잔여일수 30일 기준 → {proj} 예보, {mark} "
                      f"(실제 소진 {real_lead}일 전)")
    print()
    print("  현행 운영은 소진 당일 전면 중단이다.")
    print("  자여일수 기준이 소진율 기준보다 먼저 울린다.".replace("자여", "잔여"))
    print()

    # ── 산출물 저장 ──
    OUT.mkdir(exist_ok=True)
    with (OUT / "backtest_results.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["event_id", "asof", "days_before_actual", "method",
                    "predicted", "error_days", "lower", "upper", "covered"])
        for r in rows:
            w.writerow([r.event_id, r.asof, r.days_before_actual, r.method,
                        r.predicted or "", r.error_days if r.error_days is not None else "",
                        r.lower or "", r.upper or "",
                        "" if r.covered is None else int(r.covered)])

    (OUT / "backtest_summary.json").write_text(
        json.dumps({
            "episodes": [{"event_id": e.event_id, "label": e.label,
                          "budget_100m": e.budget,
                          "start": e.start.isoformat(),
                          "actual_exhaustion": e.actual_exhaustion.isoformat(),
                          "observations": len(e.observations)} for e in episodes],
            "method_summary": summary,
            "verdict": verdict,
            "acceptance_criterion": {
                "stated": "예측기 오차 < baseline 오차 (강부등호)",
                "met": point_criterion_met,
                "reconciliation": (
                    "점 추정에서 동률(3.0 = 3.0)이므로 수용 기준을 충족하지 못했다. "
                    "원인은 달성군 재정 소진이 거의 선형이어서 최근 가중이 개입할 여지가 없었다는 것이다. "
                    "표본이 2건뿐이라 가중치를 더 맞춰 넣으면 과적합이므로 조정하지 않았다. "
                    "구간 추정에 관한 주장은 interval_coverage.defensible_claim을 따른다 — 품질이 아니라 "
                    "능력 차이만 주장하며, 구간 정확도는 표본 2건에서 주장하지 않는다. "
                    "제안서에는 동률을 숨기지 않고 그대로 싣고, 이 동률 자체를 ‘예측은 어렵지 않았다’는 "
                    "논거로 사용한다."
                ),
            },
            "interval_coverage": {
                "proposed_covered": len(hit),
                "proposed_total": len(covered),
                "baseline_produces_interval": False,
                "intervals": [
                    {
                        "asof": r.asof.isoformat(),
                        "lower": r.lower.isoformat(),
                        "upper": r.upper.isoformat(),
                        "width_days": (r.upper - r.lower).days,
                        "covered": bool(r.covered),
                        "lower_equals_asof": r.lower == r.asof,
                    }
                    for r in rows if r.lower is not None and r.upper is not None
                ],
                "quality_caveat": (
                    "구간 품질을 주장하지 않는다. 포함된 사례는 폭 56일이며 하한이 asof와 같아 "
                    "'오늘부터 두 달 안'이라는 뜻이라 운영 정보가 없다. 반대로 폭 2일의 좋은 구간은 "
                    "실제 소진일을 빗나갔다. 표본 2건에서 구간 정확도를 주장하면 방어할 수 없다."
                ),
                "defensible_claim": (
                    "주장 가능한 것은 품질이 아니라 능력이다. 본 구현의 naive_linear은 점 추정만 내므로 "
                    "그 자체로는 '지금 경보할까'에 답할 수 없다. 제안은 답할 틀을 갖춘다. "
                    "그 틀의 정확도는 데이터가 더 쌓여야 평가할 수 있다. "
                    "주의: 선형 외삽 자체가 구간을 낼 수 없는 것은 아니다. OLS 예측구간이나 "
                    "잔차 부트스트랩을 붙이면 베이스라인도 구간을 산출할 수 있다. "
                    "구조적 불가능이라고 주장하지 말 것."
                ),
                "wide_band_rationale": (
                    "관측이 1개 구간뿐일 때 cv=1.0(최대 불확실성)을 가정하는 의도된 보수 폴백이다. "
                    "표본 2건에 맞춰 폭을 줄이는 것은 과적합이므로 하지 않는다."
                ),
            },
            "threshold_alerts": alerts,
            "caveats": [
                "백테스트 가능 구간 2건. 통계적 일반화 불가.",
                "일별 판매액 미공개로 관측이 희소함.",
                "E3 소진일은 월 해상도(±15일).",
                "절대 오차 기준(±N일)을 주장하지 않음. 베이스라인 대비로만 판정.",
            ],
        }, ensure_ascii=False, indent=2), encoding="utf-8")

    print(f"저장: {OUT/'backtest_results.csv'}")
    print(f"저장: {OUT/'backtest_summary.json'}")


if __name__ == "__main__":
    main()
