"""진단: 왜 선착순과 우선순위가 같은 결과를 내는가.

가설: 예산이 일 단위로 구속(binding)하지 않으면 정렬 순서는 결과를
바꾸지 못한다. 그날 정산을 시도한 사람 전원이 원하는 만큼 받으면
누가 먼저인지는 무의미하다.

이 가설이 맞다면 선착순과 우선순위가 같은 것은 버그가 아니라
시뮬레이션이 드러낸 사실이다.
"""

from datetime import date, timedelta

from subsidy_forecast.synthetic import GeneratorParams, generate_accruals

p = GeneratorParams()
START = date(2026, 1, 1)
accruals = generate_accruals(p, START)

by_day = {}
for r in accruals:
    by_day.setdefault(r.day, []).append(r)

import random

eligible = [0] * p.citizens
month_used = [0] * p.citizens
remaining = p.budget
rng = random.Random(p.seed + 7)

binding_days = 0
total_days_with_seekers = 0
first_binding_day = None

for d in range(p.days):
    cur = START + timedelta(days=d)
    if cur.day == 1:
        month_used = [0] * p.citizens

    for r in by_day.get(d, []):
        eligible[r.citizen] += r.amount

    seekers = [c for c in range(p.citizens)
               if eligible[c] >= p.min_unit
               and month_used[c] < p.monthly_cap
               and rng.random() < p.conversion_propensity]

    if not seekers:
        continue
    total_days_with_seekers += 1

    demand = 0
    for c in seekers:
        want = min(eligible[c], p.monthly_cap - month_used[c])
        demand += (want // p.min_unit) * p.min_unit

    if demand > remaining:
        binding_days += 1
        if first_binding_day is None:
            first_binding_day = d

    paid = 0
    for c in seekers:
        if remaining < p.min_unit:
            break
        want = min(eligible[c], p.monthly_cap - month_used[c])
        want = (want // p.min_unit) * p.min_unit
        pay = min(want, (remaining // p.min_unit) * p.min_unit)
        if pay < p.min_unit:
            continue
        eligible[c] -= pay
        month_used[c] += pay
        remaining -= pay
        paid += pay

print("=" * 70)
print("진단: 예산이 일 단위로 구속하는 날이 며칠인가")
print("=" * 70)
print()
print(f"정산 시도자가 있던 날: {total_days_with_seekers}일")
print(f"그날 수요가 잔여 예산을 초과한 날: {binding_days}일")
print(f"최초 구속일: D+{first_binding_day}")
print()
if binding_days <= 1:
    print("결론: 예산이 구속하는 날이 사실상 마지막 하루뿐이다.")
    print("      그전까지는 시도자 전원이 원하는 만큼 받으므로")
    print("      정렬 순서(선착순 vs 우선순위)가 결과를 바꾸지 못한다.")
    print()
    print("      이것은 버그가 아니라 시뮬레이션이 드러낸 사실이다.")
    print("      순서 정책은 '그날 줄 돈이 모자랄 때'만 의미가 있다.")
    print("      분배를 실제로 바꾸는 것은 1인당 상한을 거는 균등 정책뿐이다.")
else:
    print("결론: 구속일이 여러 날이므로 정렬 순서가 결과에 영향을 줘야 한다.")
    print("      그런데도 동일하다면 정렬 구현을 다시 봐야 한다.")
