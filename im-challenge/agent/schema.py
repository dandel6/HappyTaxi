"""운행 기록 추출 스키마 — LLM 출력을 이 모양으로 강제한다.

왜 스키마 강제가 필요한가
-------------------------
LLM에게 "미터요금 뽑아줘"라고 하면 "약 11,000원 정도로 보입니다" 같은 산문이 온다.
그걸 정규식으로 파싱하면 모델이 말투를 바꿀 때마다 파이프라인이 깨진다.

outlines는 생성 단계에서 문법을 제약해 스키마 밖 토큰이 아예 나올 수 없게 만든다.
즉 "파싱 실패"라는 실패 모드 자체를 없앤다. 다만 **값이 맞다는 보장은 아니다** —
모델이 11,000을 21,000으로 잘못 읽어도 스키마는 통과한다.

그 구멍을 컨트랙트가 막는다. 이 모듈의 논지는 "AI가 틀려도 장부는 안 깨진다"이고,
근거는 추출 정확도가 아니라 운행ID 파생이 추출값과 무관하다는 구조다.

스키마 컬럼 출처
----------------
대구 빅데이터활용센터 데이터 설명서 4-7 "달성 행복택시 데이터".
컬럼명만 참조했고 실데이터에는 접근하지 않았다.
"""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field


class RideExtraction(BaseModel):
    """LLM이 운행 기록 1건에서 뽑아야 하는 값.

    컨트랙트 attest 함수가 요구하는 최소 집합으로 좁혔다.
    스키마에는 더 많은 컬럼이 있지만, 온체인에 필요 없는 값을 뽑게 하면
    틀릴 기회만 늘어난다.

    extra="forbid" 가 중요하다. OpenAI 호환 구조화 출력의 strict 모드는
    스키마에 "additionalProperties": false 가 없으면 400을 돌려준다.
    pydantic은 이 설정이 있어야 그 키를 넣는다.
    이걸 빼놓고 strict=True를 보내면 서버가 요청을 거절하고,
    그 실패가 조용히 정규식 백엔드로 떨어져 "LLM이 돌았다"고 착각하게 된다.
    """

    model_config = ConfigDict(extra="forbid")

    vehicle_no: str = Field(
        description="차량번호. 스키마 '차량번호'. 예: 12가3456",
    )
    ride_datetime: str = Field(
        description="운행일시 ISO8601. 예: 2026-09-01T08:15:00",
    )
    origin_village: str = Field(
        description="출발지 마을명. 스키마 '출발지' 또는 '운행지역 대표별칭'",
    )
    meter_fare_krw: int = Field(
        ge=0,
        le=1_000_000,
        description="당회운행요금(미터기 자동인식), 원 단위 정수",
    )
    distance_m: int = Field(
        ge=0,
        le=1_000_000,
        description="운행거리(m)",
    )
    passengers: int = Field(
        ge=0,
        le=20,
        description="승차자수",
    )
    fare_source: str = Field(
        description="보조금 입력 방식. 'meter'(미터기 자동인식) 또는 'manual'(수동입력)",
    )


# outlines에 넘기는 JSON Schema. pydantic이 만들어 준다.
RIDE_SCHEMA = RideExtraction.model_json_schema()
