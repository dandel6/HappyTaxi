// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/*//////////////////////////////////////////////////////////////////////////
                  HappyTaxi — 달성 행복택시 보조금 정산 원장
////////////////////////////////////////////////////////////////////////////

배경:
    달성군은 버스 취약지 주민에게 택시 이용을 지원한다. 주민이 회당 1,000원을 부담하고
    차액을 군이 보전한다. 2026-06 조례 개정으로 지원 마을이 49개에서 71개로 늘었다.
    언론은 재정 부담 증가와 정산 시스템 보완 필요를 과제로 지적했다.

논지(한 줄):
    예산이 0이어도 기사의 보조금 청구권은 온체인에 확정되고, 예산이 확보되면 소급 확정된다.
    지원 마을이 49→71개로 늘면 청구는 늘고 예산은 회계연도에 묶인다. 그 간극이 생겼을 때
    "정산을 멈춘다"가 아니라 "확정하되 지급을 미룬다"가 되어야 한다.

잔액 3분할 = 상태 머신:
    accruedBalance    운행 후 확정된 기사 청구권. 예산 미배정.
    claimableBalance  예산 배정 완료. 정산 요청 가능.
    lockedBalance     정산 요청됨. 정산기관 응답 대기.

    _accrue()     : ? → accrued          예산과 무관. 운행 사실이 곧 청구권이다.
    _allocate()   : accrued → claimable  예산 있는 만큼만. 평시 즉시, 고갈기엔 0.
    fundBacklog() : 예산 확보 후 밀린 accrued를 소급 확정.

보조금 입력 방식 — 데이터 설명서 4-7 "달성 행복택시 데이터" 스키마 기준:
    SubsidySource.MeterAuto       당회운행요금(미터기 자동인식) 기준
    SubsidySource.ManualEntry     수동입력운행요금(기사·지자체 수동입력) 기준

    둘 뿐이다. 제도에 근거를 찾지 못한 항목은 구조 보존을 위해서라도 넣지 않는다.
    모든 청구가 기간 상한의 적용 대상이므로 [I1]에 예외가 없다.

    스키마가 자동·수동 두 경로를 따로 들고 "예상요금차이비교(%)"까지 추적한다는 것은
    군이 이미 두 값의 괴리를 관리 대상으로 보고 있다는 뜻이다. 그래서 입력 방식을
    발행원으로 삼아 방식별 상한을 따로 걸 수 있게 했다.

8개 정책 불변식 — 모든 정책성 require에 [I#] 태그를 붙인다.
    [I1] 입력방식별 기간 상한   방식별로 기사 1인 기간당 상한을 넘겨 청구할 수 없다
    [I2] 운행ID당 1회 청구      같은 (차량, 운행일시, 출발지)로 두 번 청구할 수 없다
    [I3] 예산 초과 정산 금지    배정·정산 누계가 편성 예산을 넘을 수 없다
    [I4] 잔액 아래 회수 불가    clawback이 보유 잔액을 넘길 수 없다
    [I5] 일시정지 시 차단       정지된 측의 함수는 상태를 바꾸지 못한다.
                                스위치가 둘이다: submissionPaused(제출측) / settlementPaused(정산측).
    [I6] 역할 분리              축이 둘이다.
                               축 1(역할↔역할)  관리 / 운영기관 / 군 / 정산기관 네 그룹은
                                               서로 겸할 수 없다. 그룹 안 겸직은 허용.
                               축 2(보유자↔수혜자)  운영기관 역할 보유자는
                                               동시에 등록 기사일 수 없다.

    검증 수준:
        I1 I2 I3 I4 → Foundry invariant 스위트(핸들러 + 고스트) + 변이 테스트
        I5 I6       → 유닛 revert 테스트 + 구조적 차단

★ 가정 — 군 규정 확인 전까지 확정된 것이 아니다 ★
    (1) 보조금 = max(0, 운행요금 − 승객부담액). 승객부담액 기본 1,000원.
        조례가 정률 보전이나 거리 구간제를 쓸 수도 있다. passengerShare는 설정값으로 뺐다.
    (2) 회당 상한 / 기사별 기간 상한이 존재한다고 가정했다. 실제 규정 미확인.
    (3) 기간은 30일 고정 버킷으로 근사했다. 달력 월이 아니다(아래 "기간 모델").
    (4) 지원 마을 목록은 언론에 개수(71)만 있어 자리표시자 ID로 구현했다.
        setVillageSupport로 실제 목록을 주입해야 한다.

명시적 비목표:
    - ERC20 토큰화/전송 없음. 보조금 청구권은 양도 불가. 기사↔군 사이 원장이다.
    - 업그레이드 프록시 없음. 로컬 Anvil 시연용이다.
    - 그레고리력 변환 없음(아래 "기간 모델" 참조).
    - 재진입 가드 없음. 외부 호출(call/transfer)이 한 곳도 없다.
    - 실데이터 미사용. 스키마 컬럼명만 참조했고 현장 방문형 데이터에는 접근하지 않았다.

기간 모델:
    기사별 월 상한을 달력 월로 다루려면 온체인 달력 변환이 필요하고, 그건 테스트 표면만
    늘린다. 고정 길이 버킷으로 근사한다:
        accrualPeriodOf(day) = (day - periodEpochDay) / accrualPeriodDays   기본 30
        settlePeriodOf(day)  = (day - periodEpochDay) / settlePeriodDays    기본 30
    차이: 달력 월 경계와 최대 며칠 어긋난다. 총량 통제력은 동일하고 경계일만 밀린다.

rideDay 규약:
    KST(UTC+9) 기준 1970-01-01부터의 일수. 제출자가 KST로 환산해서 넘긴다.
    운행일시(rideTimestamp)는 초 단위 원본을 그대로 받아 운행ID 파생에만 쓴다.

구현 상태:
    _accrue / _allocate / cancelSettlement 는 virtual이다. 변이 테스트(M1~M4)가 이 셋만
    오버라이드해 검사를 한 줄씩 제거한 변이본을 만든다.

//////////////////////////////////////////////////////////////////////////*/

contract HappyTaxi is AccessControl {
    /*//////////////////////////////////////////////////////////////
                                  TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice 보조금 입력 방식. 둘 다 [I1] 기간 상한의 적용 대상이다. 예외는 없다.
    enum SubsidySource {
        MeterAuto, // 당회운행요금(미터기 자동인식)
        ManualEntry // 수동입력운행요금(기사·지자체 수동입력)
    }

    enum SettlementStatus {
        None,
        Requested, // lockedBalance에 잡혀 있음. 정산기관 응답 대기.
        Settled, // 지급 확정. 예산에서 실제로 나감.
        Cancelled // 지급 실패 → 익일 취소. claimable로 환원됨.
    }

    struct Driver {
        bool registered;
        bytes32 vehicleHash; // 차량번호 해시. 원본은 개인정보라 온체인에 올리지 않는다.
        uint32 joinedDay; // rideDay와 같은 KST 에폭일 규약
    }

    struct SubsidyConfig {
        uint256 perRideCap; // 회당 보조금 상한. ★가정(2)
        uint256 periodCap; // [I1] 기간당 기사 1인 상한. 0이면 해당 방식 청구 중단.
        uint16 maxPassengers; // 인정 최대 승차자수. 스키마 "승차자수" 컬럼 대응.
    }

    struct Settlement {
        address driver;
        uint256 amount;
        uint32 requestedDay;
        uint32 periodId; // 요청 시점에 확정된 정산 기간 버킷. cancelSettlement 주석 참조.
        SettlementStatus status;
        bytes32 payoutRef; // 지급 대상 계좌/배치 식별자 해시
    }

    /*//////////////////////////////////////////////////////////////
                                  ROLES
    //////////////////////////////////////////////////////////////*/

    /// @notice 운행 제출 창구. TIMS 로그를 읽어 운행 기록을 올린다(운영기관).
    /// @dev 기사 본인에게 주면 안 된다. 자기 운행을 자기가 증명하는 구조가 되어
    ///      "운행 날조 후 청구"가 1트랜잭션이 된다. 기사는 수혜 주소이지 호출자가 아니다.
    ///      스키마에 "운영기관명" 컬럼이 있다는 것이 제출 주체가 따로 있다는 방증이다.
    bytes32 public constant RIDE_SUBMITTER_ROLE = keccak256("RIDE_SUBMITTER_ROLE");

    /// @notice 정산 요청 창구. 기사를 대리해 월 단위로 지급을 청구한다(운영기관).
    /// @dev RIDE_SUBMITTER와 별도 상수로 둔 이유:
    ///      초기 배포는 운영기관 한 곳이 제출·요청을 다 맡는게 현실적이다.
    ///      그러나 나중에 둘을 분리하려면 컴트랙트를 고쳐야 하는 구조면 이전 비용이 큼지다.
    ///      상수를 미리 쪼개놓으면 grantRole/revokeRole 두 번으로 분리된다.
    ///      단, [I6] 관점에서 둘은 같은 그룹(운영기관)이라 서로 겸직을 허용한다.
    ///      정산기관·군·관리와의 배타는 그대로 유지된다.
    bytes32 public constant SETTLEMENT_REQUESTER_ROLE = keccak256("SETTLEMENT_REQUESTER_ROLE");

    /// @notice 달성군. 예산 편성(depositBudget)과 소급 확정(fundBacklog)만 할 수 있다.
    bytes32 public constant COUNTY_ROLE = keccak256("COUNTY_ROLE");

    /// @notice 정산기관. 지급 요청의 확정/취소만 할 수 있다.
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");

    /// @notice 일시정지 권한. 사고 대응용이라 [I6] 상호배타 집합에서 의도적으로 제외한다.
    ///         정지는 아무 가치도 이전시키지 않으므로 겸직해도 부정 경로가 생기지 않고,
    ///         오히려 배타로 묶으면 사고 시 정지할 사람이 없어지는 위험이 더 크다.
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice fundBacklog 배치 상한. 가스 한계지 정책값이 아니라 상수로 박아둔다.
    uint256 public constant MAX_BATCH = 200;

    /*//////////////////////////////////////////////////////////////
                         [I5] 이중 정지 스위치
    //////////////////////////////////////////////////////////////*/

    /// @notice 제출측 정지. 기사 등록·운행 제출 경로를 멈춰세운다.
    ///         사고 유형: 제출 창구 키 유출, TIMS 피드 오염, 미터기 판독 오류 대량 발생.
    bool public submissionPaused;

    /// @notice 정산측 정지. 기사 지급 요청과 정산기관 확정을 멈춰세운다.
    ///         사고 유형: 지급 레일 장애, 정산기관 키 유출, 계좌 대사 불일치.
    bool public settlementPaused;

    /// @dev 둘을 나눈 이유는 사고가 한쪽에서만 나기 때문이다.
    ///      단일 스위치면 지급 레일이 끊겼을 때 기사의 운행 기록까지 멈춰야 하고,
    ///      그러면 이미 태운 손님에 대한 청구권이 아예 남지 않는다.
    ///      기사는 운행을 이미 했는데 기록이 없어 나중에 소급 지급도 못 받는다.
    ///      이 출품작의 논지와 정면으로 충돌한다.

    modifier whenSubmissionActive() {
        if (submissionPaused) revert SubmissionIsPaused();
        _;
    }

    modifier whenSettlementActive() {
        if (settlementPaused) revert SettlementIsPaused();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              LEDGER STATE
    //////////////////////////////////////////////////////////////*/

    mapping(address => Driver) public drivers;

    /// @notice 청구권만 확정된 잔액. 예산 미배정. 이 값의 총합이 곧 "미지급 채무"다.
    mapping(address => uint256) public accruedBalance;

    /// @notice 예산 배정 완료. 정산 요청 가능.
    mapping(address => uint256) public claimableBalance;

    /// @notice 정산 요청되어 정산기관 응답 대기 중. 기사도 군도 건드릴 수 없다.
    mapping(address => uint256) public lockedBalance;

    /*//////////////////////////////////////////////////////////////
                              BUDGET STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice 편성 총액 누계. 감액은 지원하지 않는다(감액=회수는 clawback 경로).
    uint256 public budgetTotal;

    /// @notice accrued→claimable로 배정된 누계. [I3]의 상한선.
    uint256 public budgetAllocated;

    /// @notice 실제 지급되어 예산에서 빠져나간 누계.
    uint256 public budgetSettled;

    /*//////////////////////////////////////////////////////////////
                           POLICY / CAP STATE
    //////////////////////////////////////////////////////////////*/

    mapping(SubsidySource => SubsidyConfig) public subsidyConfig;

    /// @notice [I1] 기사 × 기간 × 입력방식별 누적 청구액. 모든 청구가 여기 기록된다.
    mapping(address => mapping(uint32 => mapping(SubsidySource => uint256))) public accruedInPeriod;

    /// @notice [I2] 파생된 운행ID 소진 플래그. false→true 단조.
    ///         되돌리는 함수는 컨트랙트 어디에도 존재하지 않는다(grep으로 증명 가능).
    mapping(bytes32 => bool) public rideUsed;

    /// @notice 지원 대상 마을. ★가정(5) — 언론에 개수(71)만 있어 실제 목록은 미확인.
    ///         운영 이관 시 setVillageSupport로 조례 별표의 마을 코드를 주입해야 한다.
    mapping(uint16 => bool) public supportedVillage;

    /// @notice 지원 마을 개수 카운터. 조례 개정 후 71이 되어야 한다(현재는 자리표시자).
    uint16 public supportedVillageCount;

    /// @notice 승객이 지불해야 할 금액(지자체 설정금액). 스키마 동명 컬럼. 기본 1,000원.
    uint256 public passengerShare;

    /// @notice 정산 최소 단위. 기본 100원.
    uint256 public minSettleUnit;

    /// @notice 기간당 기사 1인 정산 한도. ★가정(2)
    uint256 public settlePeriodCap;

    /// @notice 기사 × 정산기간 누적 정산 요청액. cancelSettlement 시 되돌린다.
    mapping(address => mapping(uint32 => uint256)) public settledInPeriod;

    /// @notice 기간 버킷 기준일(KST 에폭일). 위 "기간 모델" 주석 참조.
    uint32 public periodEpochDay;
    uint32 public accrualPeriodDays; // 기본 30
    uint32 public settlePeriodDays; // 기본 30

    /*//////////////////////////////////////////////////////////////
                        SETTLEMENT / AUDIT STATE
    //////////////////////////////////////////////////////////////*/

    mapping(bytes32 => Settlement) public settlements;
    uint256 public settleNonce;

    /// @notice 회계 항등식 검증용 누계. 테스트 고스트가 아니라 컨트랙트 상태로 둔다.
    uint256 public totalAccruedEver;
    uint256 public totalClawedBack;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error DriverNotRegistered(address driver);
    error DriverAlreadyRegistered(address driver);
    error InvalidVehicleHash();
    error RideAlreadyClaimed(bytes32 rideId); // [I2]
    error VillageNotSupported(uint16 villageId);
    error FutureRide(uint32 rideDay, uint32 today);
    error RideBeforeJoin(uint32 rideDay, uint32 joinedDay);
    error PeriodCapExceeded(SubsidySource source, uint256 attempted, uint256 cap); // [I1]
    error InsufficientClaimable(uint256 requested, uint256 available); // [I3]
    error InsufficientLocked(uint256 requested, uint256 available);
    error ClawbackExceedsBalance(uint256 requested, uint256 available); // [I4]
    error SettleUnitViolation(uint256 amount, uint256 unit);
    error SettleCapExceeded(uint256 attempted, uint256 cap);
    error BadSettlementStatus(bytes32 settleId, SettlementStatus actual);
    error CancelTooEarly(uint32 requestedDay, uint32 today);
    error RoleSeparationViolated(address account, bytes32 conflicting); // [I6] 축 1 — 역할 간
    error RoleBeneficiaryConflict(address account, bytes32 conflicting); // [I6] 축 2 — 보유자↔수혜자
    error SubmissionIsPaused(); // [I5] 제출측 정지 중
    error SubmissionNotPaused(); // [I5] 이미 풀려 있는데 unpause 시도
    error SettlementIsPaused(); // [I5] 정산측 정지 중
    error SettlementNotPaused(); // [I5]
    error ZeroPassengers();
    error PassengersExceedMax(uint16 passengers, uint16 maxPassengers);
    error FareBelowPassengerShare(uint256 fare, uint256 share);
    error EmptyBatch();
    error BatchTooLarge(uint256 length, uint256 maxLength);
    error DayBeforeEpoch(uint32 day, uint32 epochDay);
    error BadConfig();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event DriverRegistered(address indexed driver, bytes32 vehicleHash, uint32 joinedDay);
    event VehicleChanged(address indexed driver, bytes32 oldVehicle, bytes32 newVehicle);
    event VillageSupportChanged(uint16 indexed villageId, bool supported, uint16 totalSupported);

    /// @dev 예산이 0이어도 반드시 발생한다. 데모 화면의 "미지급 청구 현황"은 이 이벤트만 읽는다.
    /// @dev sourceRef는 rideIdOf 주석에 따라 ID 계산에는 안 들어가고 여기에만 실린다.
    ///      TIMS 원본 레코드 해시를 싣는 자리이고, 감사 시 이벤트 로그만으로
    ///      청구 건과 원본 로그를 대사할 수 있어야 한다.
    event SubsidyAccrued(
        address indexed driver,
        SubsidySource indexed source,
        bytes32 indexed rideId,
        uint256 amount,
        uint32 rideDay,
        uint16 originVillage,
        uint256 grossFare,
        bytes32 sourceRef
    );
    event Allocated(address indexed driver, uint256 amount, uint256 budgetRemaining);
    event BudgetDeposited(uint256 amount, uint256 budgetTotal);
    event BacklogFunded(uint256 driverCount, uint256 totalAllocated, uint256 unfundedRemaining);
    /// @dev driverSigHash — 기사가 이 청구에 동의했다는 서명의 해시.
    ///      운영기관이 대리 요청하는 구조라 청구 의사가 온체인 서명으로 남지 않는다.
    ///      그 공백을 감사 추적으로 메운다 — 분쟁 시 운영기관은 이 해시에 대응하는
    ///      서명 원본(종이 동의서 스캔·전자서명)을 제시할 수 있어야 한다.
    ///      컴트랙트는 이 값을 검증하지 않는다. 검증하려면 기사 공개키를 온체인에 들고
    ///      EIP-712 구조체를 정의해야 하는데, 그건 기사 지갑 방식으로 돌아가자는 뜻이다.
    ///      지금은 "무엇에 동의했는가"를 불변으로 박아두는 데까지만 한다.
    event SettlementRequested(
        bytes32 indexed settleId,
        address indexed driver,
        address indexed requestedBy,
        uint256 amount,
        bytes32 payoutRef,
        bytes32 driverSigHash
    );
    event SettlementConfirmed(bytes32 indexed settleId, address indexed driver, uint256 amount);
    event SettlementCancelled(bytes32 indexed settleId, address indexed driver, uint256 amount);
    event ClawedBack(address indexed driver, uint256 fromAccrued, uint256 fromClaimable, bytes32 reasonHash);
    event SubsidyConfigured(SubsidySource indexed source, uint256 perRideCap, uint256 periodCap, uint16 maxPassengers);
    event SettlePolicyConfigured(uint256 minUnit, uint256 periodCap, uint32 periodDays);
    event PassengerShareConfigured(uint256 share);

    /// @dev 스위치별로 이벤트를 나눈다. 단일 Paused(address) 였으면 감사 로그만 보고는
    ///      어느 쪽이 멈췄는지 분간할 수 없다.
    event SubmissionPaused(address indexed by);
    event SubmissionUnpaused(address indexed by);
    event SettlementPausedEvent(address indexed by);
    event SettlementUnpausedEvent(address indexed by);

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param admin 조례 소관 부서. DEFAULT_ADMIN_ROLE만 가진다.
    /// @param epochDay 기간 버킷 기준일(KST 에폭일). 조례 시행일을 넣으면 경계가 가장 덜 어긋난다.
    ///
    /// 검사:
    ///   1. admin != 0                 권한 없는 컨트랙트가 되면 복구 불가
    ///   2. [I6] 여기서 SUBMITTER/COUNTY/SETTLEMENT를 부여하지 않는다.
    ///           배포 스크립트가 각각 다른 주소로 grantRole 해야 한다.
    ///   3. 기간 길이 기본값을 여기서 못 박는다. 0이면 periodOf()가 0 나눗셈으로 죽는다.
    constructor(address admin, uint32 epochDay) {
        if (admin == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        periodEpochDay = epochDay;
        accrualPeriodDays = 30;
        settlePeriodDays = 30;

        passengerShare = 1_000; // ★가정(1) 주민 회당 부담 1,000원
        minSettleUnit = 100;
        settlePeriodCap = 2_000_000; // ★가정(2)
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN / CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice 입력 방식별 회당 상한·기간 상한·승차자수 상한 설정.
    ///
    /// 검사:
    ///   1. onlyRole(DEFAULT_ADMIN_ROLE)   상한은 조례 사항이라 제출·군·정산기관이 못 만진다 [I6]
    ///   2. periodCap == 0 || periodCap >= perRideCap
    ///                                     상한이 회당 상한보다 작으면 1회도 청구 못 하는 죽은 설정.
    ///                                     0은 "해당 방식 청구 중단"이라는 의도된 값이므로 허용.
    ///
    /// @dev 생성자는 subsidyConfig를 전혀 초기화하지 않는다. 모든 방식이 0으로 시작하므로
    ///      관리자가 이 함수를 부르기 전까지는 청구가 전부 상한 0에 걸려 반려된다.
    ///      조례 수치는 컴트랙트가 아니라 배포 스크립트·테스트 픽스쳐가 주입한다.
    function setSubsidyConfig(SubsidySource source, uint256 perRideCap, uint256 periodCap, uint16 maxPassengers)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (periodCap != 0 && periodCap < perRideCap) revert BadConfig();

        subsidyConfig[source] =
            SubsidyConfig({perRideCap: perRideCap, periodCap: periodCap, maxPassengers: maxPassengers});

        emit SubsidyConfigured(source, perRideCap, periodCap, maxPassengers);
    }

    /// @notice 승객부담액 설정. 스키마 "승객이 지불해야 할 금액(지자체 설정금액)" 대응.
    /// @dev 0도 허용한다. 특정 대상(고령자 등)에 전액 지원이 있을 수 있어 막지 않는다. ★가정(1)
    function setPassengerShare(uint256 share) external onlyRole(DEFAULT_ADMIN_ROLE) {
        passengerShare = share;
        emit PassengerShareConfigured(share);
    }

    /// @notice 지원 대상 마을 등록/해제. ★가정(5)
    /// @dev 조례 별표의 실제 마을 코드를 확인하지 못해 uint16 자리표시자 ID를 쓴다.
    ///      2026-06 개정 후 71개가 되어야 하며, supportedVillageCount로 확인할 수 있다.
    function setVillageSupport(uint16 villageId, bool supported) external onlyRole(DEFAULT_ADMIN_ROLE) {
        bool cur = supportedVillage[villageId];
        if (cur == supported) return; // 멱등. 카운터 오염 방지.
        supportedVillage[villageId] = supported;
        if (supported) supportedVillageCount += 1;
        else supportedVillageCount -= 1;
        emit VillageSupportChanged(villageId, supported, supportedVillageCount);
    }

    /// @notice 정산 규칙(최소 단위 / 기간 한도) 설정.
    ///
    /// 검사:
    ///   1. onlyRole(DEFAULT_ADMIN_ROLE)
    ///   2. minUnit > 0             0이면 requestSettlement의 나머지 연산이 0 나눗셈
    ///   3. periodCap % minUnit == 0
    ///                              상한이 단위의 배수가 아니면 마지막 정산이 영원히 불가능한
    ///                              잔여가 생긴다. 기사 민원으로 직결되는 종류의 버그다.
    ///   4. periodDays > 0          settlePeriodOf()의 0 나눗셈 방지
    function setSettlePolicy(uint256 minUnit, uint256 periodCap, uint32 periodDays)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (minUnit == 0 || periodDays == 0) revert BadConfig();
        if (periodCap % minUnit != 0) revert BadConfig();

        minSettleUnit = minUnit;
        settlePeriodCap = periodCap;
        settlePeriodDays = periodDays;

        emit SettlePolicyConfigured(minUnit, periodCap, periodDays);
    }

    /*//////////////////////////////////////////////////////////////
                      [I5] 정지 진입점 — 스위치 2개
    //////////////////////////////////////////////////////////////*/

    /// @notice 제출측 정지. PAUSER_ROLE만.
    /// @dev 권한은 나누지 않았다. 사고 대응 속도가 중요한 스위치라 호출자를 늘리면
    ///      한쪽만 꺼야 할 때 담당자를 찾느라 시간을 쓴다. 대신 이벤트로 사후 분간한다.
    function pauseSubmission() external onlyRole(PAUSER_ROLE) {
        if (submissionPaused) revert SubmissionIsPaused();
        submissionPaused = true;
        emit SubmissionPaused(msg.sender);
    }

    function unpauseSubmission() external onlyRole(PAUSER_ROLE) {
        if (!submissionPaused) revert SubmissionNotPaused();
        submissionPaused = false;
        emit SubmissionUnpaused(msg.sender);
    }

    /// @notice 정산측 정지. PAUSER_ROLE만.
    function pauseSettlement() external onlyRole(PAUSER_ROLE) {
        if (settlementPaused) revert SettlementIsPaused();
        settlementPaused = true;
        emit SettlementPausedEvent(msg.sender);
    }

    function unpauseSettlement() external onlyRole(PAUSER_ROLE) {
        if (!settlementPaused) revert SettlementNotPaused();
        settlementPaused = false;
        emit SettlementUnpausedEvent(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                          [I6] ROLE SEPARATION
    //////////////////////////////////////////////////////////////*/

    /// @notice AccessControl의 부여 경로를 가로채 직무분리(SoD)를 강제한다.
    ///
    /// 왜 여기인가:
    ///   grantRole()만 오버라이드하면 다른 내부 부여 경로가 남는다.
    ///   OZ v5에서 모든 부여는 _grantRole()로 수렴하므로 여기가 유일한 좁은 목이다.
    ///
    /// 상호배타는 개별 역할이 아니라 **그룹** 단위다. 그룹이 다르면 겸직할 수 없다.
    ///
    ///   그룹 1  DEFAULT_ADMIN                                  관리(상한 설정·회수)
    ///   그룹 2  RIDE_SUBMITTER + SETTLEMENT_REQUESTER           운영기관(제출·요청)
    ///   그룹 3  COUNTY                                          달성군(편성·소급확정)
    ///   그룹 4  SETTLEMENT                                      정산기관(지급확정·취소)
    ///
    ///   2 ∩ 3   제출자가 예산을 스스로 배정하면 "운행 날조 후 지급"이 1트랜잭션
    ///   2 ∩ 4   제출자가 지급 확정까지 하면 자기가 올린 청구를 자기가 현금화
    ///   3 ∩ 4   군이 지급 확정까지 하면 배정·집행 대사(對査)가 사라진다
    ///   1 ∩ 나머지  관리자가 상한을 올린 뒤 스스로 청구하는 경로 차단
    ///   PAUSER    그룹 0(배타 제외). 정지는 가치를 이전시키지 않는다.
    ///
    /// 왜 그룹인가:
    ///   제출과 요청은 둘 다 운영기관의 일이다. 초기 배포에서 한 주소가 둘 다 갖는 게
    ///   현실적이고, 그걸 배타로 막으면 서로 다른 지갑 두 개를 운영해야 한다.
    ///   대신 제출·요청과 **지급 확정**의 분리를 못 박아놓으면 [I6]이 무너진다.
    ///   그래서 그룹 2 안에서는 겸직을 허용하고, 그룹 간 겸직은 그대로 금지한다.
    ///   운영기관이 운행을 날조해 요청해도 예산 배정(군)과 지급 확정(정산기관)
    ///   두 관문이 남아 있다.
    ///
    /// [I6]의 상호배타는 **축이 둘**이다. 둘 다 막아야 직무분리가 닫힌다.
    ///
    ///   축 1 — 역할 간 (role ↔ role)
    ///     한 주소가 서로 다른 그룹의 역할을 겸할 수 없다.
    ///     예: 운영기관이 정산기관을 겸하면 자기가 올린 청구를 자기가 확정한다.
    ///
    ///   축 2 — 역할 보유자 ↔ 수혜자 (role ↔ drivers 등록)
    ///     그룹 2(운영기관) 역할 보유자가 동시에 등록 기사일 수 없다.
    ///     축 1만 막으면 관리자가 기사 주소에 RIDE_SUBMITTER를 주는 순간
    ///     "자기 운행을 자기가 증명"하는 구조가 성립한다.
    ///     역할은 역할끼리만 비교하므로 그 경로는 축 1이 볼 수 없다.
    ///
    ///   두 축은 대칭이라 진입점이 둘이다:
    ///     _requireExclusive   역할을 나중에 주는 경우를 막는다
    ///     registerDriver      기사를 나중에 등록하는 경우를 막는다
    ///   한 쪽만 두면 순서를 바꿔 우회할 수 있다.
    ///
    /// @dev 이 함수 하나가 [I6]을 "런타임에 부여 자체가 불가능"으로 만든다.
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        _requireExclusive(role, account);
        return super._grantRole(role, account);
    }

    /// @dev 역할 → 배타 그룹 번호. 0은 배타 대상 아님(PAUSER).
    function _groupOf(bytes32 role) private pure returns (uint8) {
        if (role == DEFAULT_ADMIN_ROLE) return 1;
        if (role == RIDE_SUBMITTER_ROLE || role == SETTLEMENT_REQUESTER_ROLE) return 2;
        if (role == COUNTY_ROLE) return 3;
        if (role == SETTLEMENT_ROLE) return 4;
        return 0;
    }

    /// @dev account가 **다른 그룹**의 역할을 이미 갖고 있으면 revert.
    ///      같은 그룹 안의 겸직과 멱등 재부여는 통과시킨다.
    function _requireExclusive(bytes32 role, address account) private view {
        uint8 g = _groupOf(role);
        if (g == 0) return;

        if (g != 1 && hasRole(DEFAULT_ADMIN_ROLE, account)) {
            revert RoleSeparationViolated(account, DEFAULT_ADMIN_ROLE);
        }
        if (g != 2 && hasRole(RIDE_SUBMITTER_ROLE, account)) {
            revert RoleSeparationViolated(account, RIDE_SUBMITTER_ROLE);
        }
        if (g != 2 && hasRole(SETTLEMENT_REQUESTER_ROLE, account)) {
            revert RoleSeparationViolated(account, SETTLEMENT_REQUESTER_ROLE);
        }
        if (g != 3 && hasRole(COUNTY_ROLE, account)) {
            revert RoleSeparationViolated(account, COUNTY_ROLE);
        }
        if (g != 4 && hasRole(SETTLEMENT_ROLE, account)) {
            revert RoleSeparationViolated(account, SETTLEMENT_ROLE);
        }

        // ── 축 2 — 역할 보유자 ↔ 수혜자 ──
        // 그룹 2는 운행을 올리고 지급을 청구하는 역할이다.
        // 그걸 수혜자인 기사가 가지면 자기 운행을 자기가 증명하고 자기가 청구하게 된다.
        // 예산 배정(군)과 지급 확정(정산기관)이 남아 있어도, 운행 날조의 진입점을
        // 기사 본인에게 열어주는 것이라 막는다.
        if (g == 2 && drivers[account].registered) {
            revert RoleBeneficiaryConflict(account, role);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice 기사 등록 + 차량 지정.
    ///
    /// 검사:
    ///   1. onlyRole(RIDE_SUBMITTER_ROLE)  [I6] 운영기관이 사업자·차량 확인을 마친 뒤 올린다.
    ///                                     기사 self-register를 허용하면 차량 없는 계정이 청구한다.
    ///   2. whenSubmissionActive           [I5] 제출측
    ///   3. driver != 0
    ///   4. !drivers[d].registered         재등록으로 joinedDay를 리셋하면 [I1] 기간 버킷이 밀려
    ///                                     이미 소진한 상한이 공짜로 복원된다.
    ///   5. vehicleHash != 0               0은 "미지정"과 구분되지 않아 운행ID 파생이 오염된다.
    ///   6. joinedDay >= periodEpochDay    accrualPeriodOf() 언더플로 방지
    ///   7. 그룹 2 역할 미보유                [I6] 축 2. _requireExclusive의 대칭 진입점이다.
    ///                                     저쪽은 "기사에게 역할 주기"를 막고
    ///                                     여기는 "역할 보유자를 기사로 등록하기"를 막는다.
    ///                                     한 쪽만 두면 순서를 바꿔 우회할 수 있다.
    ///                                     RIDE_SUBMITTER만 보면 SETTLEMENT_REQUESTER만 가진
    ///                                     주소가 빠져나가므로 그룹 전체를 본다.
    ///
    /// @dev joinedDay를 파라미터로 받는 이유: 제출자가 과거 등록분을 소급 입력해야 한다.
    function registerDriver(address driver, bytes32 vehicleHash, uint32 joinedDay)
        external
        onlyRole(RIDE_SUBMITTER_ROLE) // 1
        whenSubmissionActive // 2 [I5] 제출측
    {
        if (driver == address(0)) revert ZeroAddress(); // 3

        Driver storage d = drivers[driver];
        if (d.registered) revert DriverAlreadyRegistered(driver); // 4
        if (vehicleHash == bytes32(0)) revert InvalidVehicleHash(); // 5
        if (joinedDay < periodEpochDay) revert DayBeforeEpoch(joinedDay, periodEpochDay); // 6

        // 7 [I6] 축 2 — 운영기관 역할 보유자는 기사로 등록할 수 없다.
        if (hasRole(RIDE_SUBMITTER_ROLE, driver)) revert RoleBeneficiaryConflict(driver, RIDE_SUBMITTER_ROLE);
        if (hasRole(SETTLEMENT_REQUESTER_ROLE, driver)) {
            revert RoleBeneficiaryConflict(driver, SETTLEMENT_REQUESTER_ROLE);
        }

        d.registered = true;
        d.vehicleHash = vehicleHash;
        d.joinedDay = joinedDay;

        emit DriverRegistered(driver, vehicleHash, joinedDay);
    }

    /// @notice 차량 변경. 기사가 차를 바꾸면 이후 운행ID 파생 기준이 바뀐다.
    ///
    /// 검사:
    ///   1. onlyRole(RIDE_SUBMITTER_ROLE)  [I6]
    ///   2. whenSubmissionActive           [I5] 제출측
    ///   3. registered
    ///   4. newVehicle != 0 이고 기존 값과 다름
    ///
    /// @dev 알려진 한계: 과거 운행 제출이 항상 "현재" vehicleHash로 판정되므로,
    ///      차량 변경 후 변경 이전 운행을 올리면 다른 운행ID가 나온다.
    ///      해결하려면 차량 이력을 (fromDay, hash) 배열로 들고 운행일 시점 값을 찾아야 한다.
    ///      제출자가 변경 전 운행을 먼저 올리는 운영 순서를 전제한다. 기타사항에 명시.
    function setVehicle(address driver, bytes32 newVehicle)
        external
        onlyRole(RIDE_SUBMITTER_ROLE) // 1
        whenSubmissionActive // 2 [I5] 제출측
    {
        Driver storage d = drivers[driver];
        if (!d.registered) revert DriverNotRegistered(driver); // 3
        if (newVehicle == bytes32(0) || newVehicle == d.vehicleHash) revert InvalidVehicleHash(); // 4

        bytes32 old = d.vehicleHash;
        d.vehicleHash = newVehicle;

        emit VehicleChanged(driver, old, newVehicle);
    }

    /*//////////////////////////////////////////////////////////////
                    ACCRUAL — 운행 제출 2경로
    //////////////////////////////////////////////////////////////*/

    /// @notice 운행ID 파생. 외부에서 ID를 받지 않는 것이 [I2]의 핵심이다.
    ///
    /// 구성: keccak(차량번호해시, 운행일시, 출발지)
    ///
    /// 왜 외부 입력을 안 받는가:
    ///   제출자가 임의 ID를 넘길 수 있으면 같은 운행에 대해 ID만 바꿔 무한 중복 청구가 가능하다.
    ///   그러면 [I2]는 "제출자가 착하면 성립"하는 명제로 전락한다.
    ///   컨트랙트가 ID를 파생하면 [I2]는 제출자 행동과 무관하게 구조적으로 성립한다.
    ///
    /// 왜 SubsidySource를 ID에 넣지 않는가:
    ///   넣으면 같은 운행을 MeterAuto로 한 번, ManualEntry로 한 번 청구할 수 있다.
    ///   스키마가 자동·수동을 함께 들고 "예상요금차이비교(%)"로 대사한다는 것은
    ///   둘이 같은 운행의 두 관측치라는 뜻이다. 두 번 지급할 대상이 아니다.
    ///
    /// @dev 스키마에 순번이나 TIMS 고유키 컬럼이 있으면 그걸 우선 써야 한다.
    ///      현재 파생은 "같은 차량이 같은 초에 같은 마을에서 두 번 출발할 수 없다"는
    ///      물리적 전제에 기대고 있다. 고유키가 있으면 그 전제 자체가 불필요해진다.
    function rideIdOf(bytes32 vehicleHash, uint64 rideTimestamp, uint16 originVillage)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(vehicleHash, rideTimestamp, originVillage));
    }

    /// @notice 보조금 산정. ★가정(1) — 실제 산정식은 군 규정 확인 전까지 확정이 아니다.
    ///
    /// 가정한 식: subsidy = min(운행요금 − 승객부담액, 회당 상한)
    ///
    /// 검사:
    ///   - fare >= passengerShare      승객부담액보다 싼 운행은 보조 대상이 아니다.
    ///                                 0으로 절삭하지 않고 revert하는 이유는 절삭하면
    ///                                 운행ID만 소진되고 보조금은 0인 건이 장부에 남아
    ///                                 나중에 요금이 정정돼도 재청구가 막히기 때문이다.
    function subsidyFor(SubsidySource source, uint256 fare) public view returns (uint256) {
        if (fare < passengerShare) revert FareBelowPassengerShare(fare, passengerShare);
        uint256 raw = fare - passengerShare;
        uint256 cap = subsidyConfig[source].perRideCap;
        return raw > cap ? cap : raw;
    }

    /// @notice 미터기 자동인식 요금 기준 운행 제출. 스키마 "당회운행요금".
    ///
    /// 검사:
    ///   1. onlyRole(RIDE_SUBMITTER_ROLE)                  [I6]
    ///   2. whenSubmissionActive                           [I5] 제출측
    ///   3. registered(driver)
    ///   4. rideDay <= currentDay()                        미래 운행 청구 차단.
    ///                                                     없으면 제출자가 내달치를 오늘 몰아 올려
    ///                                                     미래 기간의 [I1] 상한을 선점한다.
    ///   5. rideDay >= drivers[d].joinedDay                등록 전 운행 청구 차단.
    ///   6. supportedVillage[originVillage]                자격 판정의 전부.
    ///                                                     지원 대상 마을이 아니면 보조 사유가 없다.
    ///   7. !rideUsed[rideId]                              [I2]
    ///   8. accruedInPeriod + amount <= periodCap          [I1]
    ///
    /// 상태 변경 순서(이 순서를 바꾸면 안 된다):
    ///   rideUsed=true → accruedInPeriod += → accruedBalance += → totalAccruedEver +=
    ///   → emit SubsidyAccrued → _allocate()
    ///
    ///   _allocate를 맨 뒤에 두는 이유가 이 출품작의 전부다.
    ///   앞의 다섯 줄은 예산과 무관하게 이미 확정된다. _allocate가 0을 배정해도 되돌리지 않는다.
    function submitRideMeter(
        address driver,
        uint64 rideTimestamp,
        uint32 rideDay,
        uint16 originVillage,
        uint256 meterFare,
        bytes32 sourceRef
    )
        external
        onlyRole(RIDE_SUBMITTER_ROLE) // 1
        whenSubmissionActive // 2 [I5] 제출측
    {
        Driver storage d = _checkRideCommon(driver, rideDay, originVillage); // 3 4 5 6

        uint256 amount = subsidyFor(SubsidySource.MeterAuto, meterFare);
        bytes32 rideId = rideIdOf(d.vehicleHash, rideTimestamp, originVillage);

        // 7 [I2] 중복과 8 [I1] 상한은 _accrue 안에서 본다. 두 제출 경로가 공유하는 검사라
        // 외부 함수에 복사해 두면 양쪽이 각자 틀어질 수 있다.
        _accrue(driver, SubsidySource.MeterAuto, amount, rideDay, rideId, originVillage, meterFare, sourceRef);

        // 자격과 재정의 경계. 위 줄까지가 확정된 뒤에만 불린다.
        _allocate(driver, amount);
    }

    /// @notice 수동입력 요금 기준 운행 제출. 스키마 "수동입력운행요금(기사·지자체 수동입력)".
    ///
    /// 검사: submitRideMeter의 1~8과 동일. 추가로
    ///   9.  passengers > 0                                0명 운행은 운행ID만 소진시켜
    ///                                                     그 운행의 진짜 청구를 영구히 막는다.
    ///   10. passengers <= maxPassengers                   초과분을 절삭하지 않고 revert한다.
    ///                                                     절삭하면 제출자가 잘못된 데이터를 올린
    ///                                                     사실이 조용히 묻히고, 스키마의
    ///                                                     예상요금차이비교(%) 대사에서 원인 추적이 끊긴다.
    ///
    /// @dev 수동입력을 별도 경로로 둔 이유: 스키마가 자동·수동을 다른 컬럼으로 들고
    ///      둘의 차이를 %로 추적한다. 방식별로 상한을 달리 걸 수 있어야 그 추적이 의미를 갖는다.
    ///      예컨대 수동 경로에만 더 낮은 회당 상한을 걸어 남용을 억제할 수 있다.
    function submitRideManual(
        address driver,
        uint64 rideTimestamp,
        uint32 rideDay,
        uint16 originVillage,
        uint256 manualFare,
        uint16 passengers,
        bytes32 sourceRef
    )
        external
        onlyRole(RIDE_SUBMITTER_ROLE) // 1
        whenSubmissionActive // 2 [I5] 제출측
    {
        Driver storage d = _checkRideCommon(driver, rideDay, originVillage); // 3 4 5 6

        SubsidyConfig storage cfg = subsidyConfig[SubsidySource.ManualEntry];
        if (passengers == 0) revert ZeroPassengers(); // 9
        if (passengers > cfg.maxPassengers) revert PassengersExceedMax(passengers, cfg.maxPassengers); // 10

        uint256 amount = subsidyFor(SubsidySource.ManualEntry, manualFare);
        bytes32 rideId = rideIdOf(d.vehicleHash, rideTimestamp, originVillage);

        _accrue(driver, SubsidySource.ManualEntry, amount, rideDay, rideId, originVillage, manualFare, sourceRef); // 7 8
        _allocate(driver, amount);
    }

    /// @dev 두 제출 경로의 공통 검사 3~6. 한 곳에 모아 두 경로가 갈라지지 않게 한다.
    function _checkRideCommon(address driver, uint32 rideDay, uint16 originVillage)
        internal
        view
        returns (Driver storage d)
    {
        d = drivers[driver];
        if (!d.registered) revert DriverNotRegistered(driver); // 3

        uint32 today = currentDay();
        if (rideDay > today) revert FutureRide(rideDay, today); // 4
        if (rideDay < d.joinedDay) revert RideBeforeJoin(rideDay, d.joinedDay); // 5
        if (!supportedVillage[originVillage]) revert VillageNotSupported(originVillage); // 6
    }

    /// @notice 두 제출 경로의 공통 본체.
    ///
    /// @param activityId 호출자가 rideIdOf로 파생한 운행ID.
    ///
    /// @dev 이 함수는 revert할 수 있다([I2] 중복·[I1] 상한을 여기서 본다).
    ///      그러나 이 함수가 끝난 뒤 부르는 _allocate는 revert하지 않는다.
    ///      그 경계가 "자격 실패"와 "재정 부족"의 경계고, 이 컴트랙트의 논지 경계다.
    ///
    /// @dev 기간 상한을 건너뛰는 경로가 없다. 모든 청구가 accruedInPeriod에 기록되고
    ///      [I1] 검사를 받는다. 예외 방식을 두지 않았으므로 INV_CAP_1도 순회 제외가 없다.
    function _accrue(
        address driver,
        SubsidySource source,
        uint256 amount,
        uint32 rideDay,
        bytes32 activityId,
        uint16 originVillage,
        uint256 grossFare,
        bytes32 sourceRef
    ) internal virtual {
        // --- 검사 구간. 쓰기 전에 전부 끝낸다 ---
        if (rideUsed[activityId]) revert RideAlreadyClaimed(activityId); // 7 [I2]

        uint32 period = accrualPeriodOf(rideDay);
        uint256 cap = subsidyConfig[source].periodCap;
        uint256 nextInPeriod = accruedInPeriod[driver][period][source] + amount;
        if (nextInPeriod > cap) revert PeriodCapExceeded(source, nextInPeriod, cap); // 8 [I1]

        // --- 쓰기 구간. 순서는 submitRideMeter 주석의 "상태 변경 순서" 그대로 ---
        rideUsed[activityId] = true;
        accruedInPeriod[driver][period][source] = nextInPeriod;
        accruedBalance[driver] += amount;
        totalAccruedEver += amount;

        emit SubsidyAccrued(driver, source, activityId, amount, rideDay, originVillage, grossFare, sourceRef);
    }

    /*//////////////////////////////////////////////////////////////
                    ALLOCATION — 자격과 재정의 경계
    //////////////////////////////////////////////////////////////*/

    /// @notice accrued를 예산 잔여 범위 안에서만 claimable로 옮긴다.
    ///
    /// 설계 결정: 평시 즉시 배정은 유지하되 별도 내부 함수로 뺀다.
    ///   재정 상태를 만지는 유일한 지점을 여기 한 곳으로 모아 분리를 코드 구조로 드러낸다.
    ///
    /// 검사:
    ///   1. revert하지 않는다            예산 부족은 실패가 아니라 "0 배정"이라는 정상 결과다.
    ///                                   revert하면 예산 고갈 시 운행 제출까지 막혀서
    ///                                   기사가 이미 태운 손님에 대한 기록조차 남길 수 없게 된다.
    ///                                   이 한 줄을 어기면 출품작의 논지가 무너진다.
    ///   2. take = min(want, accruedBalance[d], budgetTotal - budgetAllocated)   [I3]
    ///   3. take == 0이면 상태 변경도 이벤트도 없이 0 반환
    function _allocate(address driver, uint256 want) internal virtual returns (uint256 allocated) {
        // 1: 이 함수에는 revert가 한 줄도 없다. 예산 부족은 실패가 아니라 0 배정이다.
        uint256 free = budgetTotal - budgetAllocated;

        uint256 take = want;
        if (take > accruedBalance[driver]) take = accruedBalance[driver];
        if (take > free) take = free; // 2 [I3] 이 한 줄이 예산 초과 배정을 막는다

        if (take == 0) return 0; // 3 상태 변경도 이벤트도 없다

        accruedBalance[driver] -= take;
        claimableBalance[driver] += take;
        budgetAllocated += take;

        emit Allocated(driver, take, budgetTotal - budgetAllocated);
        return take;
    }

    /*//////////////////////////////////////////////////////////////
                           COUNTY — 예산
    //////////////////////////////////////////////////////////////*/

    /// @notice 예산 편성. 실제 원화 이체는 오프체인이고 여기는 한도 등록이다.
    ///
    /// 검사:
    ///   1. onlyRole(COUNTY_ROLE)        [I6]
    ///   2. amount > 0
    ///   3. 어느 스위치에도 걸지 않는다  의도적이다. 사고로 정지된 상태에서도 예산 편성을
    ///                                   막을 이유가 없고, 오히려 재개 준비를 막는다.
    ///                                   편성은 눈금을 올리는 행위일 뿐 가치를 이동시키지 않는다.
    function depositBudget(uint256 amount)
        external
        onlyRole(COUNTY_ROLE) // 1 [I6]
    {
        // 3: 정지 modifier가 하나도 없는 것이 의도된 설계다.
        if (amount == 0) revert ZeroAmount(); // 2

        budgetTotal += amount;

        // 여기서 자동으로 배정하지 않는다. 편성과 소급 확정은 별개의 결정이다.
        emit BudgetDeposited(amount, budgetTotal);
    }

    /// @notice 예산 확보 후 밀린 accrued를 소급 확정. "추후 지급"을 코드로 만든 것.
    ///
    /// 검사:
    ///   1. onlyRole(COUNTY_ROLE)        [I6]
    ///   2. 어느 스위치에도 걸지 않는다  [I5] 예외. 아래 dev 주석에 근거를 적는다.
    ///   3. list.length > 0 && <= 200    가스 상한.
    ///   4. 배정 총액 <= maxSpend        호출자가 이번 회차 집행 규모를 스스로 제한.
    ///   5. 배분 순서 = 배열 순서(선착순)  온체인 정렬 없음.
    ///
    /// @dev [I5] 어느 스위치에도 걸지 않는 이유 (확정):
    ///
    ///      이 함수는 이미 확정된 과거 accrued에 예산을 붙이는 소급 지급 경로다.
    ///      새로운 자격을 만들지 않는다.
    ///
    ///      논지가 "정지 중에도 청구권은 살아 있고 예산이 확보되면 소급 확정된다"인데,
    ///      소급 지급 자체가 정지에 걸리면 그 논지가 조건부가 된다.
    ///
    ///      오염된 청구분이 걱정이라면 도구가 따로 있다:
    ///        · 호출자가 list 에서 해당 기사를 뺀다 (사전 배제)
    ///        · 이미 배정됐으면 clawback 으로 회수한다 (사후 회수)
    ///
    ///      알고 선택한 비용: 배정 표면이 두 갈래로 쪼개진다.
    ///        · submitRide* → _allocate  제출측 스위치에 걸린다
    ///        · fundBacklog → _allocate  어느 스위치에도 안 걸린다
    function fundBacklog(address[] calldata list, uint256 maxSpend)
        external
        onlyRole(COUNTY_ROLE) // 1 [I6]
        returns (uint256 totalAllocated)
    {
        // 2: 정지 modifier가 하나도 없는 것이 의도된 설계다. 위 @dev 참조.
        uint256 n = list.length;
        if (n == 0) revert EmptyBatch(); // 3
        if (n > MAX_BATCH) revert BatchTooLarge(n, MAX_BATCH); // 3

        for (uint256 i = 0; i < n; ++i) {
            uint256 headroom = maxSpend - totalAllocated; // 4
            if (headroom == 0) break;

            uint256 want = accruedBalance[list[i]];
            if (want > headroom) want = headroom;

            // 5: 배열 순서 그대로. 정렬 없음.
            totalAllocated += _allocate(list[i], want);
        }

        emit BacklogFunded(n, totalAllocated, unfundedDebt());
    }

    /*//////////////////////////////////////////////////////////////
                     SETTLEMENT — 비동기 2단계
    //////////////////////////////////////////////////////////////*/

    /// @notice 정산 요청. claimable → locked.
    ///
    /// ┌─ 요청 주체를 운영기관 대리로 정한 근거 ─────────────────────────────┐
    /// │ 기사 지갑 방식과 비교해 이쪽을 택했다.                                        │
    /// │                                                                            │
    /// │ 기사 지갑: 청구 의사가 온체인 서명으로 남는다. 그러나 버스 취약지 기사에게        │
    /// │   지갑·키·가스 운영을 요구하고, 건당 보조금 1만원인데 요청마다 트랜잭션이다.   │
    /// │   고령 기사 비중을 감안하면 사실상 작동하지 않는다.                            │
    /// │                                                                            │
    /// │ 운영기관 대리: 월 배치로 묶어 가스가 저렴하고 현행 절차와 맞는다.            │
    /// │   스키마의 "운영기관명" 컬럼이 대리 주체가 이미 존재함을 보여준다.             │
    /// │   비용은 제출과 요청이 같은 그룹에 붙는다는 것이다.                         │
    /// │                                                                            │
    /// │ [I6]은 유지된다. 운영기관이 운행을 날조해 요청해도                          │
    /// │ 예산 배정(군)과 지급 확정(정산기관) 두 관문이 남아 있다.                     │
    /// │ 요청·확정·취소를 한 역할이 독점하는 구조는 여전히 불가능하다.                 │
    /// │                                                                            │
    /// │ 잃은 것: 청구 의사가 온체인 서명으로 남지 않는다.                            │
    /// │ 보완: driverSigHash를 이벤트에 실어 감사 추적을 남긴다. 검증은 안 한다 —       │
    /// │ 검증하려면 EIP-712와 기사 공개키가 필요하고, 그건 지갑 방식으로 돌아가자는 뜻이다. │
    /// └───────────────────────────────────────────────────────────┘
    ///
    /// 검사:
    ///   1. onlyRole(SETTLEMENT_REQUESTER_ROLE)           [I6] 그룹 2(운영기관)
    ///   2. whenSettlementActive                          [I5] 정산측
    ///   3. registered(driver)
    ///   4. amount >= minSettleUnit
    ///   5. amount % minSettleUnit == 0
    ///   6. claimableBalance[driver] >= amount            accrued는 쓸 수 없다.
    ///                                                    이 한 줄이 "예산 없으면 지급 불가,
    ///                                                    그래도 청구권은 남음"을 구현한다.
    ///   7. settledInPeriod + amount <= settlePeriodCap
    ///
    ///   [I3] 별도 require를 넣지 않는 이유:
    ///        claimable은 이미 budgetAllocated를 거쳐 배정된 돈이므로 6번이 [I3]을 함의한다.
    function requestSettlement(address driver, uint256 amount, bytes32 payoutRef, bytes32 driverSigHash)
        external
        onlyRole(SETTLEMENT_REQUESTER_ROLE) // 1 [I6]
        whenSettlementActive // 2 [I5] 정산측
        returns (bytes32 settleId)
    {
        if (!drivers[driver].registered) revert DriverNotRegistered(driver); // 3
        if (amount < minSettleUnit) revert SettleUnitViolation(amount, minSettleUnit); // 4
        if (amount % minSettleUnit != 0) revert SettleUnitViolation(amount, minSettleUnit); // 5

        uint256 avail = claimableBalance[driver];
        if (avail < amount) revert InsufficientClaimable(amount, avail); // 6 ([I3]을 함의)

        uint32 today = currentDay();
        uint32 period = settlePeriodOf(today);
        uint256 next = settledInPeriod[driver][period] + amount;
        if (next > settlePeriodCap) revert SettleCapExceeded(next, settlePeriodCap); // 7

        claimableBalance[driver] = avail - amount;
        lockedBalance[driver] += amount;
        settledInPeriod[driver][period] = next;

        settleId = keccak256(abi.encode(driver, settleNonce++));
        settlements[settleId] = Settlement({
            driver: driver,
            amount: amount,
            requestedDay: today,
            // 여기서 버킷을 박아둔다. 나중에 settlePeriodOf로 다시 계산하면
            // 그 사이에 setSettlePolicy가 settlePeriodDays를 바꿀 경우 다른 버킷을 가리킨다.
            periodId: period,
            status: SettlementStatus.Requested,
            payoutRef: payoutRef
        });

        emit SettlementRequested(settleId, driver, msg.sender, amount, payoutRef, driverSigHash);
    }

    /// @notice 정산기관 지급 확정. locked 소멸 = 예산에서 실제 유출.
    ///
    /// 검사:
    ///   1. onlyRole(SETTLEMENT_ROLE)                     [I6]
    ///   2. whenSettlementActive                          [I5] 정산측
    ///   3. status == Requested                           재호출 시 budgetSettled 이중 계상 방지.
    ///   4. lockedBalance[driver] >= amount               방어적. 위반하면 회계 항등식이 이미 깨진 것.
    function confirmSettlement(bytes32 settleId)
        external
        onlyRole(SETTLEMENT_ROLE) // 1 [I6]
        whenSettlementActive // 2 [I5] 정산측
    {
        Settlement storage s = settlements[settleId];
        if (s.status != SettlementStatus.Requested) revert BadSettlementStatus(settleId, s.status); // 3

        address driver = s.driver;
        uint256 amount = s.amount;

        uint256 locked = lockedBalance[driver];
        if (locked < amount) revert InsufficientLocked(amount, locked); // 4

        lockedBalance[driver] = locked - amount;
        budgetSettled += amount;
        s.status = SettlementStatus.Settled;

        emit SettlementConfirmed(settleId, driver, amount);
    }

    /// @notice 지급 실패 → 익일 취소. locked → claimable 환원.
    ///
    /// 검사:
    ///   1. onlyRole(SETTLEMENT_ROLE)                     [I6]
    ///   2. status == Requested
    ///   3. currentDay() > requestedDay                   "익일". 같은 날 취소를 허용하면
    ///                                                    정산기관이 기사의 기간 한도를 즉시
    ///                                                    리셋시켜 주는 통로가 되어 6번이 무력화된다.
    ///   4. 어느 스위치에도 걸지 않는다                   의도적. 정산측 정지는 "지급 레일이
    ///                                                    끊겼다"는 뜻인데, 그게 바로 지급 실패를
    ///                                                    대량으로 만드는 상황이다.
    ///                                                    정확히 그때 취소가 필요하다.
    ///
    /// @dev settledInPeriod를 되돌리는 이유: 취소는 기사 과실이 아니라 시스템 실패다.
    ///
    ///      차감 대상 버킷은 s.periodId다. settlePeriodOf(s.requestedDay)를 다시 계산하지 않는다.
    ///      그 함수는 호출 시점의 settlePeriodDays로 나누므로, 요청과 취소 사이에
    ///      setSettlePolicy가 그 값을 바꾸면 요청 때 더한 버킷과 다른 버킷을 가리킨다.
    ///      그러면 보통 0인 버킷에서 빼게 돼 언더플로로 죽고, 요청은 Requested에 영구히 박힌다.
    ///      lockedBalance가 동결되는 것이라 revert보다 나쁜 결과다.
    ///
    ///      언더플로가 불가능한 건 "차감 버킷이 요청 버킷과 같다"는 전제 위에서만 성립한다.
    ///      periodId를 요청 시점에 저장해 그 전제를 구조로 바꿔놓았다.
    ///      검증: M4 변이(현재 기간에서 차감)를 INV_QUOTA_2가 결정적으로 잡는다.
    ///      INV_QUOTA_1은 대부분의 시드에서 놓친다 — 잘못된 버킷 차감은 보통 언더플로 panic으로
    ///      되돌아가 상태를 전혀 바꾸지 않고, 상태 술어형 불변식은 그걸 볼 수 없기 때문이다.
    ///
    /// @dev virtual 인 이유는 _accrue / _allocate 와 같다. M4 변이본이 이 함수만 오버라이드한다.
    function cancelSettlement(bytes32 settleId)
        external
        virtual
        onlyRole(SETTLEMENT_ROLE) // 1 [I6]
    {
        // 4: 정지 modifier가 하나도 없는 것이 의도된 설계다.
        Settlement storage s = settlements[settleId];
        if (s.status != SettlementStatus.Requested) revert BadSettlementStatus(settleId, s.status); // 2

        uint32 today = currentDay();
        if (today <= s.requestedDay) revert CancelTooEarly(s.requestedDay, today); // 3

        address driver = s.driver;
        uint256 amount = s.amount;

        lockedBalance[driver] -= amount;
        claimableBalance[driver] += amount;
        settledInPeriod[driver][s.periodId] -= amount; // 요청 시점에 박아둔 버킷
        s.status = SettlementStatus.Cancelled;

        emit SettlementCancelled(settleId, driver, amount);
    }

    /*//////////////////////////////////////////////////////////////
                     [I4] CLAWBACK — 부정청구 회수
    //////////////////////////////////////////////////////////////*/

    /// @notice 부정 청구 회수. 보조금 환수 조항의 온체인 대응물.
    ///
    /// 검사:
    ///   1. onlyRole(DEFAULT_ADMIN_ROLE)   [I6] 제출자가 회수까지 하면 증거 인멸이 1트랜잭션이 된다.
    ///   2. 어느 스위치에도 걸지 않는다    [I5] 예외. 아래 dev 주석에 근거를 적는다.
    ///   3. amount > 0
    ///   4. amount <= accruedBalance[d] + claimableBalance[d]      [I4]
    ///      locked는 제외한다. 이미 정산기관에 넘어간 청구권이라 여기서 빼면
    ///      confirmSettlement이 없는 돈을 지급하게 되고 INV_ACCT_1이 깨진다.
    ///      회수하려면 먼저 cancelSettlement으로 환원시켜야 한다.
    ///
    /// 차감 순서(중요):
    ///   accrued 먼저, 부족분만 claimable에서.
    ///   claimable에서 뺄 때만 budgetAllocated를 함께 줄여 예산을 반납한다.
    ///
    ///   순서를 뒤집어도 회계 항등식은 전부 그대로 성립한다. 즉 차감 순서는 회계 위반이 아니라
    ///   정책 차이다. 상태 술어형 불변식은 이걸 원리적으로 볼 수 없고, 전후 차분만 볼 수 있다.
    ///   잡는 건 test_I4_clawbackOrderAndBound 다.
    ///
    /// @dev rideUsed는 되돌리지 않는다. 부정 청구였어도 그 운행ID는 소진 상태로 남겨
    ///      같은 운행으로 재청구하는 경로를 막는다. [I2]는 clawback 이후에도 성립해야 한다.
    ///
    /// @dev [I5] 어느 스위치에도 걸지 않는 이유 (확정):
    ///      회수는 사고 대응 그 자체다. 부정을 발견해서 정지했는데 정지됐다는 이유로
    ///      회수를 못 하면, 구멍을 메우려고 구멍을 다시 열어야 한다.
    ///
    ///      정지로 막아도 보안상 이득이 없다:
    ///        · 정지 권한은 PAUSER_ROLE이고 DEFAULT_ADMIN과 다른 주소일 수 있다.
    ///        · 그러나 PAUSER_ROLE은 [I6] 상호배타 집합 밖이라
    ///          _requireExclusive가 inSet == false 로 조기 반환한다.
    ///        · PAUSER_ROLE의 관리 역할은 DEFAULT_ADMIN_ROLE이므로,
    ///          관리자는 자신에게 PAUSER_ROLE을 부여한 뒤 정지를 풀 수 있다.
    ///        · 단, 두 트랜잭션 경로다: grantRole(PAUSER_ROLE, self) → unpauseSubmission()
    ///      검증: test_I5_adminCanSelfGrantPauserAndUnpause
    function clawback(address driver, uint256 amount, bytes32 reasonHash)
        external
        onlyRole(DEFAULT_ADMIN_ROLE) // 1 [I6]
    {
        // 2: 정지 modifier가 하나도 없는 것이 의도된 설계다. 위 @dev 참조.
        if (amount == 0) revert ZeroAmount(); // 3

        uint256 a = accruedBalance[driver];
        uint256 cl = claimableBalance[driver];
        // 4 [I4]: locked는 더하지 않는다. 이미 정산기관에 넘어간 청구권이다.
        if (amount > a + cl) revert ClawbackExceedsBalance(amount, a + cl);

        uint256 fromAccrued = amount < a ? amount : a; // accrued 먼저
        uint256 fromClaimable = amount - fromAccrued; // 부족분만 claimable에서

        accruedBalance[driver] = a - fromAccrued;
        claimableBalance[driver] = cl - fromClaimable;
        budgetAllocated -= fromClaimable; // 예산 반납
        totalClawedBack += amount;

        // accruedInPeriod는 되돌리지 않는다. rideUsed를 안 되돌리는 것과 같은 이유다 —
        // 부정 청구 후 회수로 상한 여유가 복원되면 "부정 → 회수 → 재청구"가 공짜가 된다.
        emit ClawedBack(driver, fromAccrued, fromClaimable, reasonHash);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEWS / PURE
    //////////////////////////////////////////////////////////////*/

    /// @notice [I1] 청구 기간 버킷 인덱스.
    /// @dev periodEpochDay 이전 날짜는 revert한다. 언더플로를 조용히 wrap시키면
    ///      기간 인덱스가 uint32 최대치로 튀어 상한이 사실상 무한이 된다.
    function accrualPeriodOf(uint32 day) public view returns (uint32) {
        if (day < periodEpochDay) revert DayBeforeEpoch(day, periodEpochDay);
        return (day - periodEpochDay) / accrualPeriodDays;
    }

    /// @notice 정산 기간 버킷 인덱스. 언더플로 처리 근거는 accrualPeriodOf와 동일.
    function settlePeriodOf(uint32 day) public view returns (uint32) {
        if (day < periodEpochDay) revert DayBeforeEpoch(day, periodEpochDay);
        return (day - periodEpochDay) / settlePeriodDays;
    }

    /// @notice 현재 KST 에폭일. block.timestamp(UTC) + 9h → 일수.
    function currentDay() public view returns (uint32) {
        return uint32((block.timestamp + 9 hours) / 1 days);
    }

    /// @notice 기사 총 보유. INV_ACCT_1 검증용.
    function totalBalanceOf(address driver) public view returns (uint256) {
        return accruedBalance[driver] + claimableBalance[driver] + lockedBalance[driver];
    }

    /// @notice 아직 예산이 안 붙은 미지급 채무 규모. 데모 화면의 핵심 숫자.
    /// @dev 이 값은 항상 Σ accruedBalance와 같다.
    ///      다만 그 등식은 INV_ACCT_1과 INV_ACCT_3의 선형 결합이라 독립 명제가 아니고,
    ///      그래서 불변식 스위트에 넣지 않았다. clawback 차감 순서도 잡지 못한다.
    function unfundedDebt() public view returns (uint256) {
        return totalAccruedEver - totalClawedBack - budgetAllocated;
    }

    /// @notice 예산 잔여. _allocate가 쓰는 값과 동일.
    function budgetRemaining() public view returns (uint256) {
        return budgetTotal - budgetAllocated;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                  회계 항등식 — invariant 스위트가 검증할 대상
////////////////////////////////////////////////////////////////////////////

INV_ACCT_1  총량 보존 ([I4]가 여기 포함된다)
    totalAccruedEver - totalClawedBack
        == Σ_d (accruedBalance[d] + claimableBalance[d] + lockedBalance[d]) + budgetSettled

INV_ACCT_2  예산 단조 ([I3])
    budgetSettled <= budgetAllocated <= budgetTotal

INV_ACCT_3  배정분의 소재 ([I3]의 강한 형태)
    budgetAllocated - budgetSettled == Σ_d (claimableBalance[d] + lockedBalance[d])

    배정됐는데 아직 안 나간 예산은 반드시 기사의 claimable+locked로 존재한다.
    이 한 줄이 "예산이 어디로 샜는가"를 구조적으로 불가능하게 만든다.

INV_CAP_1  입력방식별 기간 상한 ([I1])
    ∀ d, p, s ∈ {MeterAuto, ManualEntry}:
        subsidyConfig[s].periodCap == 0 || accruedInPeriod[d][p][s] <= subsidyConfig[s].periodCap

    순회 제외 대상이 없다. 모든 청구가 기간 상한의 적용 대상이므로
    "이건 제외라서 안 센다"는 단서가 붙지 않는다.

INV_ONCE_1  운행ID당 1회 ([I2])
    ghost_accrueSucceeded == ghost_distinctRideIds

    핸들러가 중복 운행ID를 의도적으로 재투입해도 성공 횟수가 늘지 않는다.

INV_QUOTA_1  정산 한도 버킷의 정합성
    ∀ d, p:  settledInPeriod[d][p] == Σ{ 취소되지 않은 요청 중 그 버킷에 배정된 금액 }

    핸들러가 컨트랙트의 periodId를 읽지 않고 요청 순간에 자체 기록한 고스트와 대조한다.
    다만 M4는 대부분의 시드에서 이걸 깨뜨리지 못하고, 아래 INV_QUOTA_2가 결정적으로 잡는다.
    깨지려면 잘못된 버킷에 그 기사의 미결제 한도가 amount 이상 남아 차감이 성공하는
    시퀀스를 밟아야 하는데, 그건 시드에 따라 나오기도 하고 안 나오기도 한다.

INV_QUOTA_2  취소 경로의 산술은 실패하지 않는다
    ghost_cancelPanic == 0

    업무적 revert(BadSettlementStatus / CancelTooEarly / 권한)는 정상이지만
    Panic(uint256)은 장부가 어긋났다는 신호다. try/catch가 삼킨 panic을 따로 세서
    안전성 명제로 바꾸는 방법이다. Settlement.periodId 저장이 주는 보장 그 자체다.

INV_COVERAGE  상한 도달률
    ghost_maxCapRatioBps <= 10_000

    적립 순간에 측정한 상한 소진율. INV_CAP_1과 같은 명제를 다른 경로로 구한 독립 증인.


[I5] 일시정지 — 유닛 테스트로만 검증. 스위치가 둘이다.

  submissionPaused (제출측) — whenSubmissionActive
    registerDriver / setVehicle
    submitRideMeter / submitRideManual

  settlementPaused (정산측) — whenSettlementActive
    requestSettlement / confirmSettlement

  의도적 예외 — 어느 스위치에도 걸리지 않음 (4개 모두 확정)
    depositBudget      재개 준비를 막을 이유가 없다. 편성은 한도 등록일 뿐 가치 이동이 아니다.
    cancelSettlement   정산측 정지는 "지급 레일이 끊겼다"는 뜻이고, 그게 바로 지급 실패를
                       대량으로 만드는 상황이다. 정확히 그때 취소가 필요하다.
    fundBacklog        이미 확정된 과거 accrued에 예산을 붙이는 소급 지급 경로다.
                       소급 지급이 정지에 걸리면 논지가 조건부가 된다.
    clawback           회수는 사고 대응 그 자체다. 정지로 막으면 구멍을 메우려고
                       구멍을 다시 열어야 하는 교착이 된다.
    pause/unpause      당연히
    모든 view


[I6] 역할 분리 — 유닛 테스트로만 검증. 축이 둘이다.

  축 1 — 역할 ↔ 역할
    그룹 1 DEFAULT_ADMIN / 그룹 2 RIDE_SUBMITTER+SETTLEMENT_REQUESTER /
    그룹 3 COUNTY / 그룹 4 SETTLEMENT — 그룹이 다르면 겸직 불가.
    그룹 2 안에서는 겸직 허용(초기 배포 운영기관 한 주소).
    진입점: _requireExclusive

  축 2 — 역할 보유자 ↔ 수혜자
    그룹 2 보유자는 동시에 등록 기사일 수 없다.
    진입점이 두 개인 이유는 순서 우회를 막기 위해서다:
      _requireExclusive  기사에게 역할을 나중에 주는 경우
      registerDriver     역할 보유자를 나중에 기사로 등록하는 경우
    한 쪽만 두면 순서를 바꿔 같은 상태에 도달한다.
    둘 다 그룹 전체를 본다 — RIDE_SUBMITTER만 검사하면
    SETTLEMENT_REQUESTER만 가진 주소가 빠져나간다.

    테스트: 축 1은 grantRole 실패 7건 + 그룹 내 겸직 허용 1건,
            축 2는 양방향 2건, 그리고 권한 없는 호출 revert 2건.


변이 테스트 4건(각각 해당 invariant가 실제로 깨지는 것을 보인다):
    M1  _accrue의 [I1] 상한 require 제거         → INV_CAP_1 깨짐
    M2  _accrue의 rideUsed 기록 제거             → INV_ONCE_1 깨짐
    M3  _allocate의 budgetRemaining min 제거     → INV_ACCT_2 깨짐
    M4  cancelSettlement이 현재 기간에서 차감    → INV_QUOTA_2 깨짐

//////////////////////////////////////////////////////////////////////////*/
