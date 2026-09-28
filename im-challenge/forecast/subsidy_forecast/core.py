"""소진 예측 핵심 모듈.

설계 원칙
---------
1. 실측과 합성을 절대 섞지 않는다.
   - 달성군 재정 실측(events.csv) → 예측기 오차 검증 전용
   - 행복택시 보조금 합성(synthetic.py) → 정책 비교 전용
   제안요약서에서 합성 데이터로 예측 정확도를 주장하지 않는다.

2. 관측은 희소(sparse)하다.
   대구시는 일별 판매액을 공개하지 않는다. 공개된 것은
   판매 시작일, 중간 보도(절반 소진 등), 완전 소진일뿐이다.
   실제 운영에서도 마찬가지이므로 희소 관측을 전제로 설계한다.

3. 점 추정보다 구간이 중요하다.
   "언제 소진되는가"의 정답 하나보다, "지금 경고를 울려야 하는가"에
   답하는 상한/하한이 정책적으로 쓸모 있다.
"""

from __future__ import annotations

import csv
import math
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path


# ─────────────────────────────────────────────────────────────
# 관측 데이터
# ─────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Observation:
    """특정 시점의 누적 소진액 관측.

    Attributes:
        on: 관측 일자
        consumed: 그 시점까지 누적 소진액 (억원)
        resolution: 'day' | 'month' — 출처의 날짜 정밀도.
            월 해상도 관측은 오차 계산 시 ±15일 불확실성을 갖는다.
    """
    on: date
    consumed: float
    resolution: str = "day"


@dataclass
class BudgetEpisode:
    """하나의 예산 집행 구간 (예: 2026 상반기 2,000억).

    Attributes:
        event_id: 데이터셋 상 식별자
        label: 사람이 읽는 이름
        budget: 총 예산 (억원)
        start: 판매 시작일
        actual_exhaustion: 실제 소진일 (미소진이면 None)
        observations: 시간순 관측 목록
        per_person_cap: 1인당 한도 (원). 정책 비교에서 사용
    """
    event_id: str
    label: str
    budget: float
    start: date
    actual_exhaustion: date | None
    observations: list[Observation] = field(default_factory=list)
    per_person_cap: int | None = None

    def observations_until(self, cutoff: date) -> list[Observation]:
        """cutoff 시점에 알 수 있었던 관측만 반환.

        워크포워드 백테스트에서 미래 정보 누출(lookahead bias)을 막는
        유일한 장치다. 이 함수를 우회해 observations를 직접 읽으면
        백테스트 결과가 무의미해진다.
        """
        return [o for o in self.observations if o.on <= cutoff]


# ─────────────────────────────────────────────────────────────
# 예측기
# ─────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Forecast:
    """소진 예측 결과.

    Attributes:
        exhaustion: 점 추정 소진일. 추정 불가면 None
        earliest: 낙관/비관 구간의 이른 쪽 (소진이 빠를 경우)
        latest: 늦은 쪽
        rate: 추정에 쓰인 일평균 소진율 (억원/일)
        method: 예측기 이름
        basis: 몇 개 관측을 썼는지
    """
    exhaustion: date | None
    earliest: date | None
    latest: date | None
    rate: float
    method: str
    basis: int

    def lead_days(self, reference: date) -> int | None:
        """reference 시점 기준, 예측 소진일까지 남은 일수."""
        if self.exhaustion is None:
            return None
        return (self.exhaustion - reference).days


def naive_linear(ep: BudgetEpisode, asof: date) -> Forecast:
    """베이스라인: 시작일부터 현재까지의 전체 평균 소진율로 선형 외삽.

    이것이 비교 기준이다. 단순하지만 소진이 실제로 선형에 가까우면
    상당히 정확하다. 제안 예측기가 이걸 못 이기면 그 사실을 그대로
    보고한다 — 이기는 척하지 않는다.

    한계: 구간을 주지 않는다. 점 추정 하나뿐이라 "지금 경고할까"에
    답하지 못한다.
    """
    obs = ep.observations_until(asof)
    if not obs:
        return Forecast(None, None, None, 0.0, "naive_linear", 0)

    latest = obs[-1]
    elapsed = (latest.on - ep.start).days
    if elapsed <= 0 or latest.consumed <= 0:
        return Forecast(None, None, None, 0.0, "naive_linear", len(obs))

    rate = latest.consumed / elapsed
    remaining = ep.budget - latest.consumed
    if remaining <= 0:
        return Forecast(latest.on, latest.on, latest.on, rate, "naive_linear", len(obs))

    days_left = remaining / rate
    est = latest.on + timedelta(days=round(days_left))
    return Forecast(est, None, None, rate, "naive_linear", len(obs))


def recent_weighted(
    ep: BudgetEpisode,
    asof: date,
    half_life_days: float = 21.0,
    band_factor: float = 0.30,
) -> Forecast:
    """제안 예측기: 최근 구간에 가중치를 준 소진율 + 불확실성 구간.

    두 가지가 베이스라인과 다르다.

    (1) 최근 가중.
        구간별 소진율을 따로 구하고, 최근 구간일수록 큰 가중치를 준다.
        가중치는 반감기 `half_life_days`의 지수 감쇠.
        이유: 지역화폐 소비는 초기 러시 후 둔화하거나, 소진 임박 시
        재가속(막차 수요)한다. 전체 평균은 이 변화를 놓친다.
        실제로 달성군 재정 2026 상반기는 마지막 날 160억이 한 번에
        빠져나갔다 — 전체 평균으로는 설명되지 않는 패턴이다.

    (2) 구간 추정.
        점 추정 하나가 아니라 [earliest, latest]를 낸다.
        폭은 관측 수와 소진율 변동성에 따라 결정된다.
        관측이 적을수록 넓어진다.
        이 구간이 있어야 "하한이 N주 뒤면 지금 경고" 같은 운영 판단이
        가능하다. 본 구현의 naive_linear은 점 추정만 낸다.
        단, 선형 외삽 기법 자체가 구간을 못 내는 것은 아니다 —
        OLS 예측구간이나 잔차 부트스트랩을 붙이면 가능하다.
        "구조적으로 불가능"이라고 주장하지 말 것.

    Args:
        half_life_days: 가중치 반감기. 21일은 3주로, 지역화폐 월 단위
            충전 주기의 약 2/3. 민감도는 README 참조.
        band_factor: 구간 폭 계수. 소진율 변동계수에 곱해진다.
    """
    obs = ep.observations_until(asof)
    if len(obs) < 1:
        return Forecast(None, None, None, 0.0, "recent_weighted", 0)

    # 구간별 소진율 계산. 시작점(0 소진)을 첫 구간의 기준으로 삼는다.
    points = [Observation(ep.start, 0.0)] + obs
    segments: list[tuple[date, float]] = []  # (구간 끝일, 일평균 소진율)
    for prev, cur in zip(points, points[1:]):
        days = (cur.on - prev.on).days
        if days <= 0:
            continue
        seg_rate = (cur.consumed - prev.consumed) / days
        if seg_rate < 0:
            continue  # 누적값이 줄어드는 건 데이터 오류. 무시한다.
        segments.append((cur.on, seg_rate))

    if not segments:
        return Forecast(None, None, None, 0.0, "recent_weighted", len(obs))

    # 지수 가중 평균. 최근 구간일수록 가중치가 크다.
    anchor = segments[-1][0]
    decay = math.log(2) / half_life_days
    weights = [math.exp(-decay * (anchor - d).days) for d, _ in segments]
    rates = [r for _, r in segments]
    wsum = sum(weights)
    rate = sum(w * r for w, r in zip(weights, rates)) / wsum

    if rate <= 0:
        return Forecast(None, None, None, 0.0, "recent_weighted", len(obs))

    latest = obs[-1]
    remaining = ep.budget - latest.consumed
    if remaining <= 0:
        return Forecast(latest.on, latest.on, latest.on, rate, "recent_weighted", len(obs))

    days_left = remaining / rate
    est = latest.on + timedelta(days=round(days_left))

    # 구간 폭: 소진율의 가중 변동계수에 기반.
    # 관측이 1개뿐이면 변동성을 알 수 없으므로 보수적으로 큰 폭을 준다.
    if len(rates) >= 2:
        mean_r = sum(w * r for w, r in zip(weights, rates)) / wsum
        var = sum(w * (r - mean_r) ** 2 for w, r in zip(weights, rates)) / wsum
        cv = math.sqrt(var) / mean_r if mean_r > 0 else 1.0
    else:
        cv = 1.0  # 관측 1개 — 변동성 미상. 최대 불확실성 가정.

    spread = max(1.0, days_left * min(cv * (1 + band_factor), 1.0))
    earliest = latest.on + timedelta(days=round(max(0.0, days_left - spread)))
    latest_d = latest.on + timedelta(days=round(days_left + spread))

    return Forecast(est, earliest, latest_d, rate, "recent_weighted", len(obs))


def threshold_crossing(
    ep: BudgetEpisode, asof: date, pct: float = 0.90,
    forecaster=recent_weighted,
) -> date | None:
    """예산의 pct 비율이 소진되는 시점을 예측한다.

    주의 — 이것은 경보 트리거로 쓰기에 부적합하다.
    달성군 재정 2026 상반기 실측으로 계산하면:
        50% 도달 = 소진 29일 전
        80% 도달 = 소진 12일 전
        90% 도달 = 소진  6일 전
    소진이 선형에 가까우므로 소진율 임계는 예산 규모와 무관하게
    항상 소진 직전에 울린다. 90%를 넘었을 때는 이미 늦었다.

    이 함수는 반사실 비교에서 "소진율 기준 경보가 왜 쓸모없는가"를
    보이기 위해 남겨둔다. 실제 트리거는 lead_time_alert()를 쓴다.
    """
    fc = forecaster(ep, asof)
    if fc.rate <= 0:
        return None
    obs = ep.observations_until(asof)
    if not obs:
        return None
    latest = obs[-1]
    target = ep.budget * pct
    if latest.consumed >= target:
        return latest.on  # 이미 통과
    return latest.on + timedelta(days=round((target - latest.consumed) / fc.rate))


def lead_time_alert(
    ep: BudgetEpisode, asof: date, alert_days: int = 30,
    forecaster=recent_weighted,
) -> tuple[bool, int | None, date | None]:
    """경보 트리거: 예상 소진일까지 alert_days 이내면 경보.

    소진율 임계(90% 등)와 결정적으로 다르다.
    소진율은 예산을 얼마나 썼는지를 보고,
    이 함수는 얼마나 남았는지를 시간으로 본다.

    선형 소비에서 소진율 임계는 항상 직전에 울리지만,
    시간 기준은 예보가 서는 즉시 울린다.

    달성군 재정 2026 상반기 대입:
        3/2 관측(50% 소진) 시점의 예보는 3/30 소진.
        실제는 4/1로 오차 2일.
        alert_days=30이면 이날 바로 경보 — 실제 소진 30일 전이다.
        같은 시점의 90% 임계 예측은 3/24로 여유가 6일뿐이다.

    Returns:
        (경보 여부, 예상 소진까지 남은 일수, 예상 소진일)
    """
    fc = forecaster(ep, asof)
    if fc.exhaustion is None:
        return (False, None, None)
    days_left = (fc.exhaustion - asof).days
    return (days_left <= alert_days, days_left, fc.exhaustion)


# ────────────────────────────────────────────────────────────
# 워크포워드 백테스트
# ────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class BacktestPoint:
    """한 시점에서의 예측과 실제의 대조."""
    event_id: str
    asof: date
    days_before_actual: int
    method: str
    predicted: date | None
    error_days: int | None
    lower: date | None
    upper: date | None
    covered: bool | None  # 구간이 실제를 포함했는가. 점 추정만 내는 방법은 None


def walk_forward(ep: BudgetEpisode, methods: dict) -> list[BacktestPoint]:
    """각 관측 시점에서 그때까지의 정보만으로 예측하고 실제와 비교한다.

    관측이 n개면 예측 시점도 n개다. 달성군 재정는 일별 데이터가
    공개되지 않아 관측이 희소하므로, 이벤트당 예측 시점이 2~3개에
    그친다. 이 한계를 결과표에 그대로 적는다.
    """
    if ep.actual_exhaustion is None:
        return []

    rows: list[BacktestPoint] = []
    for o in ep.observations:
        if o.on >= ep.actual_exhaustion:
            continue  # 소진 당일 이후 예측은 의미 없음
        for name, fn in methods.items():
            fc = fn(ep, o.on)
            err = None
            if fc.exhaustion is not None:
                err = (fc.exhaustion - ep.actual_exhaustion).days
            covered = None
            if fc.earliest is not None and fc.latest is not None:
                covered = fc.earliest <= ep.actual_exhaustion <= fc.latest
            rows.append(BacktestPoint(
                event_id=ep.event_id,
                asof=o.on,
                days_before_actual=(ep.actual_exhaustion - o.on).days,
                method=name,
                predicted=fc.exhaustion,
                error_days=err,
                lower=fc.earliest,
                upper=fc.latest,
                covered=covered,
            ))
    return rows


# ─────────────────────────────────────────────────────────────
# 데이터셋 적재
# ─────────────────────────────────────────────────────────────

def load_episodes(csv_path: Path) -> list[BudgetEpisode]:
    """events.csv에서 백테스트 가능한 구간만 적재한다.

    usable_for_backtest=false 행은 건너뛴다. 그 행들은 수요 초과의
    정황 증거로 제안서에 인용되지만, 날짜 해상도가 부족해
    소진일 예측 대상이 아니다.
    """
    episodes: list[BudgetEpisode] = []
    with csv_path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            if row["usable_for_backtest"].strip().lower() != "true":
                continue
            episodes.append(BudgetEpisode(
                event_id=row["event_id"],
                label=row["label"],
                budget=float(row["budget_100m_krw"]),
                start=date.fromisoformat(row["sale_start"]),
                actual_exhaustion=date.fromisoformat(row["exhaustion_date"]),
                per_person_cap=int(row["per_person_cap_krw"]) if row["per_person_cap_krw"] else None,
            ))
    return episodes
