"""행복택시 보조금 합성 시계열 생성기와 3정책 비교 시뮬레이션.

경고 — 역할 경계
----------------
이 모듈의 출력으로 **예측 정확도를 주장하지 않는다.**
합성 데이터는 생성기의 가정을 그대로 반영하므로, 그것으로 예측기를
검증하면 자기 가정을 자기가 맞히는 순환논증이 된다.

합성은 오직 정책 비교에만 쓴다:
    "같은 유입·같은 예산에서 균등/선착순/우선순위는 누구에게
     얼마를 남기는가"
이 질문은 반사실이므로 실측으로 답할 수 없다. 대구시는 선착순
하나만 집행했고 나머지 둘의 결과는 관측되지 않는다.

실측 검증은 core.py + run_backtest.py가 담당한다.

생성기 파라미터 공개
--------------------
재현성을 위해 아래 값을 문서와 제안서에 그대로 싣는다.
숨기면 심사위원이 통째로 할인한다.
"""

from __future__ import annotations

import random
from dataclasses import dataclass, field, asdict
from datetime import date, timedelta


# ─────────────────────────────────────────────────────────────
# 생성기 파라미터 — 전량 공개
# ─────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class GeneratorParams:
    """합성 행복택시 보조금 시계열 생성 파라미터.

    근거를 밝힐 수 있는 값만 쓴다. 근거 없는 값은 '임의'로 표기한다.

    Attributes:
        seed: 난수 시드. 고정해야 재현된다.
        citizens: 참여 기사 수. 임의(데모 규모).
        days: 시뮬레이션 일수. 반기 집행을 가정해 180일.
        monthly_cap: 1인 월 정산 한도. 행복택시 보조금 실제 규정 10만 보조금.
        min_unit: 최소 정산 단위. 행복택시 보조금 실제 규정 100 보조금.
        budget: 정산 예산 총액(보조금 환산). 임의(데모 규모).
        accrual_mean: 1인 1일 평균 청구. 승용차요일제 준수 + 운휴일
            대중교통 이용을 합친 값으로 가정. 임의.
        accrual_cv: 청구량 변동계수. 기사별 활동량 편차. 임의.
        participation: 임의의 날에 활동할 확률. 주 5일 기준 근사.
        weekend_drop: 주말 활동 감소 계수. 운휴일 제도가 평일 중심임을
            반영. 임의.
        conversion_propensity: 정산 가능 잔액이 있을 때 실제로 정산을
            시도할 일일 확률. 임의.
        heavy_user_ratio: 상위 활동 기사 비율. 지역화폐 소비가 일부
            적극 이용자에 집중되는 현상을 반영. 달성군 재정 실물카드
            10분 소진 사례가 정황 근거.
        heavy_user_multiplier: 적극 이용자의 활동량 배수. 임의.
    """
    seed: int = 20260920
    citizens: int = 2000
    days: int = 180
    monthly_cap: int = 100_000
    min_unit: int = 100
    budget: int = 135_000_000
    accrual_mean: float = 900.0
    accrual_cv: float = 0.45
    participation: float = 0.62
    weekend_drop: float = 0.35
    conversion_propensity: float = 0.14
    heavy_user_ratio: float = 0.15
    heavy_user_multiplier: float = 3.2

    def as_public_table(self) -> list[tuple[str, object, str]]:
        """문서에 싣는 (이름, 값, 근거) 표."""
        return [
            ("seed", self.seed, "재현용 고정값"),
            ("citizens", self.citizens, "임의 — 데모 규모"),
            ("days", self.days, "반기 집행 가정"),
            ("monthly_cap", self.monthly_cap, "행복택시 보조금 실제 규정 월 10만"),
            ("min_unit", self.min_unit, "행복택시 보조금 실제 규정 최소 100"),
            ("budget", self.budget, "임의 — 총 청구의 약 65%. 수요 초과 구간을 만들기 위한 값"),
            ("accrual_mean", self.accrual_mean, "임의 — 요일제+대중교통 합산 가정"),
            ("accrual_cv", self.accrual_cv, "임의 — 기사별 활동 편차"),
            ("participation", self.participation, "주 5일 활동 근사"),
            ("weekend_drop", self.weekend_drop, "임의 — 운휴일 제도 평일 중심"),
            ("conversion_propensity", self.conversion_propensity, "임의"),
            ("heavy_user_ratio", self.heavy_user_ratio,
             "달성군 재정 실물카드 10분 소진 — 적극 이용자 집중 정황"),
            ("heavy_user_multiplier", self.heavy_user_multiplier, "임의"),
        ]


# ─────────────────────────────────────────────────────────────
# 합성 시계열
# ─────────────────────────────────────────────────────────────

@dataclass
class AccrualRecord:
    """하루치 청구."""
    day: int
    citizen: int
    amount: int


def generate_accruals(p: GeneratorParams, start: date) -> list[AccrualRecord]:
    """일별·기사별 청구 시계열을 생성한다.

    구조:
        - 기사마다 고유한 활동 성향(rate_i)을 로그정규로 뽑는다
        - 적극 이용자(heavy_user_ratio)는 성향에 배수를 곱한다
        - 매일 participation 확률로 활동하고, 주말은 weekend_drop 적용
        - 청구량은 성향 주변에서 변동
    """
    rng = random.Random(p.seed)
    n_heavy = int(p.citizens * p.heavy_user_ratio)
    heavy = set(rng.sample(range(p.citizens), n_heavy))

    sigma = (p.accrual_cv ** 2 + 1) ** 0.5
    rates = []
    for c in range(p.citizens):
        base = rng.lognormvariate(0.0, min(0.9, sigma - 1)) * p.accrual_mean
        if c in heavy:
            base *= p.heavy_user_multiplier
        rates.append(base)

    out: list[AccrualRecord] = []
    for d in range(p.days):
        cur = start + timedelta(days=d)
        weekend = cur.weekday() >= 5
        part = p.participation * (p.weekend_drop if weekend else 1.0)
        for c in range(p.citizens):
            if rng.random() > part:
                continue
            amt = int(rates[c] * rng.uniform(0.55, 1.45))
            amt = (amt // p.min_unit) * p.min_unit
            if amt > 0:
                out.append(AccrualRecord(d, c, amt))
    return out


# ─────────────────────────────────────────────────────────────
# 3정책
# ─────────────────────────────────────────────────────────────

@dataclass
class PolicyResult:
    """정책 하나의 시뮬레이션 결과."""
    name: str
    exhausted_on_day: int | None
    total_converted: int
    citizens_served: int
    citizens_with_unfunded: int
    total_unfunded: int
    gini: float
    daily_converted: list[int] = field(default_factory=list)
    daily_remaining: list[int] = field(default_factory=list)
    per_citizen_converted: list[int] = field(default_factory=list)


def _gini(values: list[int]) -> float:
    """정산액 분배의 지니계수. 0=완전균등, 1=완전집중."""
    if not values:
        return 0.0
    xs = sorted(values)
    n = len(xs)
    total = sum(xs)
    if total == 0:
        return 0.0
    cum = sum((i + 1) * x for i, x in enumerate(xs))
    return (2 * cum) / (n * total) - (n + 1) / n


def simulate(
    p: GeneratorParams,
    accruals: list[AccrualRecord],
    policy: str,
    start: date,
) -> PolicyResult:
    """한 정책으로 예산 배분을 시뮬레이션한다.

    정책 정의:
        first_come: 선착순. 요청 순서대로 예산이 남아 있는 만큼 지급.
            **현행 대구시 운영이 사실상 이것이다.** 먼저 정산한 사람이
            다 가져가고 나중 사람은 0을 받는다.
        equal: 균등. 일별 예산을 참여자 수로 나눠 상한을 정한다.
            대구시가 하반기에 1인 한도를 50만→30만으로 낮춘 조치가
            이 방향의 사후적·반기 1회 버전이다.
        priority: 우선순위. **가장 오래 기다린 기사부터** 지급한다.
            기준은 잔액 크기가 아니라 최초 미지급 발생일이다.
            잔액 크기로 정렬하면 많이 쌓인 적극 이용자가 먼저 받아
            선착순과 결과가 같아진다. 대기 시간으로 정렬해야
            "오래 기다린 사람 먼저"가 실제로 구현된다.

    모든 정책에서 청구 자체는 막지 않는다. 예산이 없으면 미지급
    (unfunded)으로 쌓인다 — 이것이 컨트랙트의 accrued 상태에 대응한다.
    """
    by_day: dict[int, list[AccrualRecord]] = {}
    for r in accruals:
        by_day.setdefault(r.day, []).append(r)

    eligible = [0] * p.citizens      # 청구되었으나 아직 정산 안 된 잔액
    converted = [0] * p.citizens     # 정산 완료 누적
    month_used = [0] * p.citizens    # 이번 달 정산액 (월 한도용)
    waiting_since: list[int | None] = [None] * p.citizens  # 최초 미지급일

    remaining = p.budget
    exhausted_on: int | None = None
    daily_conv: list[int] = []
    daily_rem: list[int] = []

    rng = random.Random(p.seed + 7)

    for d in range(p.days):
        cur = start + timedelta(days=d)
        if cur.day == 1:
            month_used = [0] * p.citizens

        for r in by_day.get(d, []):
            if eligible[r.citizen] == 0 and waiting_since[r.citizen] is None:
                waiting_since[r.citizen] = d
            eligible[r.citizen] += r.amount

        # 오늘 정산을 시도하는 기사
        seekers = [c for c in range(p.citizens)
                   if eligible[c] >= p.min_unit
                   and month_used[c] < p.monthly_cap
                   and rng.random() < p.conversion_propensity]

        if policy == "priority":
            # 대기 시작일이 이른 순. 잔액 크기가 아니다.
            seekers.sort(key=lambda c: (waiting_since[c] if waiting_since[c]
                                        is not None else d))
        elif policy == "equal":
            seekers.sort(key=lambda c: converted[c])
        # first_come은 생성 순서 유지 (= 무작위 도착 순서)

        # 일 배분 상한.
        #
        # 선착순은 상한이 없다 — 먼저 온 사람이 원하는 만큼 가져간다.
        # 그게 현행 운영이고, 예산이 날짜로 끝나는 이유다.
        #
        # 균등과 우선순위는 둘 다 일 총액을 제한한다. 다른 것은
        # 그 한도 안에서 누구부터 주느냐이다.
        #   균등     → 참여자 수로 나누어 1인당 상한을 건다
        #   우선순위 → 1인당 상한 없이, 오래 기다린 순서대로 채운다
        #
        # 일 총액 제한이 없으면 우선순위는 선착순과 같아진다.
        # 예산이 바닥나기 전까지는 전원이 다 받고, 바닥난 뒤에는
        # 줄 돈이 없어 정렬이 무의미해지기 때문이다.
        per_head_cap = None
        day_budget = None
        if policy in ("equal", "priority") and seekers:
            days_left = max(1, p.days - d)
            day_budget = max(p.min_unit, remaining // days_left)
            if policy == "equal":
                per_head_cap = max(p.min_unit, day_budget // max(1, len(seekers)))
                per_head_cap = (per_head_cap // p.min_unit) * p.min_unit

        today = 0
        for c in seekers:
            if remaining < p.min_unit:
                break
            if day_budget is not None and today >= day_budget:
                break  # 오늘치 배분 소진. 나머지는 내일로 밀린다.
            want = min(eligible[c], p.monthly_cap - month_used[c])
            if per_head_cap is not None:
                want = min(want, per_head_cap)
            if day_budget is not None:
                want = min(want, day_budget - today)
            want = (want // p.min_unit) * p.min_unit
            pay = min(want, (remaining // p.min_unit) * p.min_unit)
            if pay < p.min_unit:
                continue
            eligible[c] -= pay
            converted[c] += pay
            month_used[c] += pay
            remaining -= pay
            today += pay
            # 잔액을 다 뺄 기사은 대기열에서 빠진다
            if eligible[c] < p.min_unit:
                waiting_since[c] = None

        if remaining < p.min_unit and exhausted_on is None:
            exhausted_on = d

        daily_conv.append(today)
        daily_rem.append(remaining)

    unfunded = [e for e in eligible if e > 0]
    return PolicyResult(
        name=policy,
        exhausted_on_day=exhausted_on,
        total_converted=sum(converted),
        citizens_served=sum(1 for c in converted if c > 0),
        citizens_with_unfunded=len(unfunded),
        total_unfunded=sum(unfunded),
        gini=_gini(converted),
        daily_converted=daily_conv,
        daily_remaining=daily_rem,
        per_citizen_converted=converted,
    )
