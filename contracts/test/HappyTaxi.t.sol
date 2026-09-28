// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {HappyTaxi} from "../src/HappyTaxi.sol";

/*//////////////////////////////////////////////////////////////////////////
                          공통 지원 — 픽스처 + 불변식 술어
////////////////////////////////////////////////////////////////////////////

불변식을 assert가 아니라 bool을 돌려주는 술어(holds_*)로 쓴 이유:
    정상 컨트랙트에서는 참임을, 변이본에서는 거짓임을 같은 함수로 보여야 한다.
    술어 안에서 뺄셈 전에 크기를 먼저 확인하는 것도 같은 이유다 —
    변이본에서는 언더플로가 실제로 일어날 수 있는데, 그때 술어가 revert해 버리면
    "불변식이 거짓"이 아니라 "테스트가 터짐"으로 보고된다.

//////////////////////////////////////////////////////////////////////////*/

abstract contract HappyTaxiSupport is Test {
    address internal admin = makeAddr("admin");
    address internal submitter = makeAddr("submitter"); // 운영기관
    address internal county = makeAddr("county"); // 달성군
    address internal settler = makeAddr("settler"); // 정산기관
    address internal pauser = makeAddr("pauser");

    uint32 internal constant EPOCH_DAY = 20_000;
    uint32 internal constant START_DAY = 20_335;
    uint32 internal constant JOIN_DAY = 20_135;

    // 승객 부담 1,000원, 운행요금 11,000원 → 보조금 10,000원.
    uint256 internal constant PASSENGER_SHARE = 1_000;
    uint256 internal constant FARE = 11_000;
    uint256 internal constant SUBSIDY = 10_000;

    // 상한은 조례 수치가 아니라 "64콜 내에 도달 가능한 값"으로 잡는다.
    // 너무 크면 캠페인이 상한 근처를 못 밟아 INV_CAP_1이 자동으로 참이 된다.
    uint256 internal constant CAP_METER = 30_000; // 3건이면 소진, 4건째 초과
    uint256 internal constant CAP_MANUAL = 10_000; // 1건이면 소진, 2건째 초과
    uint256 internal constant PER_RIDE_CAP = 10_000;
    uint16 internal constant MAX_PASSENGERS = 4;

    uint16 internal constant VILLAGE_OK = 1; // 지원 대상
    uint16 internal constant VILLAGE_BAD = 999; // 미지원

    /// @dev 기사 동의 서명 해시. 컴트랙트는 검증하지 않고 이벤트에만 실는다.
    bytes32 internal constant SIG = keccak256("DRIVER_CONSENT_DEMO");

    /// @dev 배포 직후 역할 분배와 정책 설정. 변이본도 HappyTaxi 하위형이라 그대로 쓴다.
    function _bootstrap(HappyTaxi t) internal {
        vm.startPrank(admin);
        // 초기 배포: 운영기관 한 주소가 제출과 요청을 다 맡는다.
        // 둘은 [I6] 같은 그룹(2)이라 겸직이 허용된다. 분리하려면 grantRole 한 번이면 된다.
        t.grantRole(t.RIDE_SUBMITTER_ROLE(), submitter);
        t.grantRole(t.SETTLEMENT_REQUESTER_ROLE(), submitter);
        t.grantRole(t.COUNTY_ROLE(), county);
        t.grantRole(t.SETTLEMENT_ROLE(), settler);
        t.grantRole(t.PAUSER_ROLE(), pauser);

        t.setPassengerShare(PASSENGER_SHARE);
        t.setSubsidyConfig(HappyTaxi.SubsidySource.MeterAuto, PER_RIDE_CAP, CAP_METER, MAX_PASSENGERS);
        t.setSubsidyConfig(HappyTaxi.SubsidySource.ManualEntry, PER_RIDE_CAP, CAP_MANUAL, MAX_PASSENGERS);

        // 지원 대상 마을. ★가정(5) — 실제 조례 별표 코드가 아니라 자리표시자다.
        for (uint16 v = 1; v <= 10; ++v) {
            t.setVillageSupport(v, true);
        }
        vm.stopPrank();
    }

    function _makeDrivers(uint256 n) internal returns (address[] memory a) {
        a = new address[](n);
        for (uint256 i = 0; i < n; ++i) {
            a[i] = makeAddr(string.concat("driver", vm.toString(i)));
        }
    }

    /// @dev 차량번호 해시는 기사마다 달라야 한다. 같으면 운행ID가 기사 간에 충돌한다.
    function _vehicleOf(address driver) internal pure returns (bytes32) {
        return keccak256(abi.encode("VEHICLE", driver));
    }

    function _registerAll(HappyTaxi t, address[] memory a) internal {
        vm.startPrank(submitter);
        for (uint256 i = 0; i < a.length; ++i) {
            t.registerDriver(a[i], _vehicleOf(a[i]), JOIN_DAY);
        }
        vm.stopPrank();
    }

    /// @dev 운행일시. 같은 (기사, 날짜, 슬롯)이면 같은 값이 나와야 중복 재투입이 성립한다.
    function _rideTs(uint32 rideDay, uint8 slot) internal pure returns (uint64) {
        return uint64(rideDay) * 86_400 + uint64(slot) * 3_600;
    }

    /*//////////////////////////////////////////////////////////////
                            불변식 술어
    //////////////////////////////////////////////////////////////*/

    function _sums(HappyTaxi t, address[] memory a)
        internal
        view
        returns (uint256 acc, uint256 clm, uint256 lck)
    {
        for (uint256 i = 0; i < a.length; ++i) {
            acc += t.accruedBalance(a[i]);
            clm += t.claimableBalance(a[i]);
            lck += t.lockedBalance(a[i]);
        }
    }

    /// INV_ACCT_1  totalAccruedEver - totalClawedBack == Σ(accrued+claimable+locked) + budgetSettled
    function holds_ACCT_1(HappyTaxi t, address[] memory a) internal view returns (bool) {
        (uint256 acc, uint256 clm, uint256 lck) = _sums(t, a);
        uint256 tot = t.totalAccruedEver();
        uint256 cb = t.totalClawedBack();
        if (cb > tot) return false;
        return tot - cb == acc + clm + lck + t.budgetSettled();
    }

    /// INV_ACCT_2  budgetSettled <= budgetAllocated <= budgetTotal
    function holds_ACCT_2(HappyTaxi t) internal view returns (bool) {
        return t.budgetSettled() <= t.budgetAllocated() && t.budgetAllocated() <= t.budgetTotal();
    }

    /// INV_ACCT_3  budgetAllocated - budgetSettled == Σ(claimable + locked)
    function holds_ACCT_3(HappyTaxi t, address[] memory a) internal view returns (bool) {
        (, uint256 clm, uint256 lck) = _sums(t, a);
        uint256 ba = t.budgetAllocated();
        uint256 bs = t.budgetSettled();
        if (bs > ba) return false;
        return ba - bs == clm + lck;
    }

    /// INV_CAP_1  입력방식별 기간 상한. 순회 제외 대상이 없다.
    function holds_CAP_1(HappyTaxi t, address[] memory a) internal view returns (bool) {
        uint32 pMax = t.accrualPeriodOf(t.currentDay());
        for (uint256 i = 0; i < a.length; ++i) {
            for (uint32 p = 0; p <= pMax; ++p) {
                if (!_capOk(t, a[i], p, HappyTaxi.SubsidySource.MeterAuto)) return false;
                if (!_capOk(t, a[i], p, HappyTaxi.SubsidySource.ManualEntry)) return false;
            }
        }
        return true;
    }

    /// INV_QUOTA_1  settledInPeriod[d][p] == Σ{ 취소되지 않은 요청 중 그 버킷 배정분 }
    ///
    /// @dev 핸들러가 컨트랙트의 periodId를 읽지 않고 요청 순간에 자체 기록한 값과 대조한다.
    ///      기대값을 컨트랙트에서 가져오면 같은 버그를 양쪽에 복사해 항상 참이 된다.
    function holds_QUOTA_1(HappyTaxi t, address[] memory cs, uint32[] memory ps, uint256[] memory expected)
        internal
        view
        returns (bool)
    {
        for (uint256 i = 0; i < cs.length; ++i) {
            if (t.settledInPeriod(cs[i], ps[i]) != expected[i]) return false;
        }
        return true;
    }

    function _capOk(HappyTaxi t, address d, uint32 p, HappyTaxi.SubsidySource s) private view returns (bool) {
        (, uint256 cap,) = t.subsidyConfig(s);
        if (cap == 0) return true; // 0 = 해당 방식 청구 중단. 과거 청구분은 그대로 남는다.
        return t.accruedInPeriod(d, p, s) <= cap;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                                  변이본
////////////////////////////////////////////////////////////////////////////

_accrue / _allocate / cancelSettlement 만 오버라이드해 검사를 한 줄씩 지운다.
본문 나머지는 원본과 글자 단위로 같다. 차이가 딱 한 줄이어야
"그 검사가 그 불변식을 지키고 있었다"가 증명된다.

//////////////////////////////////////////////////////////////////////////*/

/// @notice M1 — [I1] 기간 상한 revert 제거
contract HappyTaxiM1 is HappyTaxi {
    constructor(address a, uint32 e) HappyTaxi(a, e) {}

    function _accrue(
        address driver,
        SubsidySource source,
        uint256 amount,
        uint32 rideDay,
        bytes32 activityId,
        uint16 originVillage,
        uint256 grossFare,
        bytes32 sourceRef
    ) internal override {
        if (rideUsed[activityId]) revert RideAlreadyClaimed(activityId);

        uint32 period = accrualPeriodOf(rideDay);
        uint256 nextInPeriod = accruedInPeriod[driver][period][source] + amount;
        // [M1] if (nextInPeriod > cap) revert PeriodCapExceeded(...);  ← 이 줄을 지웠다

        rideUsed[activityId] = true;
        accruedInPeriod[driver][period][source] = nextInPeriod;
        accruedBalance[driver] += amount;
        totalAccruedEver += amount;

        emit SubsidyAccrued(driver, source, activityId, amount, rideDay, originVillage, grossFare, sourceRef);
    }
}

/// @notice M2 — [I2] rideUsed 기록 제거
contract HappyTaxiM2 is HappyTaxi {
    constructor(address a, uint32 e) HappyTaxi(a, e) {}

    function _accrue(
        address driver,
        SubsidySource source,
        uint256 amount,
        uint32 rideDay,
        bytes32 activityId,
        uint16 originVillage,
        uint256 grossFare,
        bytes32 sourceRef
    ) internal override {
        if (rideUsed[activityId]) revert RideAlreadyClaimed(activityId);

        uint32 period = accrualPeriodOf(rideDay);
        uint256 cap = subsidyConfig[source].periodCap;
        uint256 nextInPeriod = accruedInPeriod[driver][period][source] + amount;
        if (nextInPeriod > cap) revert PeriodCapExceeded(source, nextInPeriod, cap);

        // [M2] rideUsed[activityId] = true;  ← 이 줄을 지웠다
        accruedInPeriod[driver][period][source] = nextInPeriod;
        accruedBalance[driver] += amount;
        totalAccruedEver += amount;

        emit SubsidyAccrued(driver, source, activityId, amount, rideDay, originVillage, grossFare, sourceRef);
    }
}

/// @notice M3 — [I3] _allocate의 예산 절삭 제거
contract HappyTaxiM3 is HappyTaxi {
    constructor(address a, uint32 e) HappyTaxi(a, e) {}

    function _allocate(address driver, uint256 want) internal override returns (uint256) {
        uint256 take = want;
        if (take > accruedBalance[driver]) take = accruedBalance[driver];
        // [M3] if (take > budgetTotal - budgetAllocated) take = free;  ← 이 줄을 지웠다

        if (take == 0) return 0;

        accruedBalance[driver] -= take;
        claimableBalance[driver] += take;
        budgetAllocated += take;

        // 원본은 budgetTotal - budgetAllocated 를 싣지만 변이본에서는 그게 언더플로다.
        emit Allocated(driver, take, 0);
        return take;
    }
}

/// @notice M4 — cancelSettlement이 s.periodId 대신 현재 기간에서 차감
/// @dev Settlement.periodId 저장(A안) 이전의 코드가 정확히 이 모양이었다.
contract HappyTaxiM4 is HappyTaxi {
    constructor(address a, uint32 e) HappyTaxi(a, e) {}

    function cancelSettlement(bytes32 settleId) external override onlyRole(SETTLEMENT_ROLE) {
        Settlement storage s = settlements[settleId];
        if (s.status != SettlementStatus.Requested) revert BadSettlementStatus(settleId, s.status);

        uint32 today = currentDay();
        if (today <= s.requestedDay) revert CancelTooEarly(s.requestedDay, today);

        address driver = s.driver;
        uint256 amount = s.amount;

        lockedBalance[driver] -= amount;
        claimableBalance[driver] += amount;
        // [M4] s.periodId 대신 현재 기간에서 뺀다
        settledInPeriod[driver][settlePeriodOf(today)] -= amount;
        s.status = SettlementStatus.Cancelled;

        emit SettlementCancelled(settleId, driver, amount);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                                  핸들러
//////////////////////////////////////////////////////////////////////////*/

contract HappyTaxiHandler is HappyTaxiSupport {
    HappyTaxi public taxi;
    address[] public actors;

    // --- 고스트 ---
    uint256 public ghost_accrueSucceeded;
    uint256 public ghost_distinctRideIds;
    mapping(bytes32 => bool) internal _seen;

    /// @dev 중복 재투입 시도 횟수. 0이면 INV_ONCE_1은 "실패한 적 없음"이 아니라
    ///      "시도된 적 없음"으로 통과한 공허한 불변식이 된다.
    uint256 public ghost_replayAttempts;

    /// @dev revert 사유별 카운터. try/catch가 삼키므로 Foundry의 reverts 열은 항상 0이다.
    uint256 public ghost_revertDupe; // RideAlreadyClaimed      [I2]
    uint256 public ghost_revertCap; // PeriodCapExceeded        [I1]
    uint256 public ghost_revertClaimable; // InsufficientClaimable [I3] 함의
    uint256 public ghost_revertOther;

    /// @dev 청구 성공 시점의 accruedInPeriod / periodCap 고수위(bps).
    uint256 public ghost_maxCapRatioBps;

    /// @dev cancelSettlement이 산술 panic으로 죽은 횟수. INV_QUOTA_2의 본체.
    uint256 public ghost_cancelPanic;
    bytes4 internal constant PANIC_SELECTOR = 0x4e487b71;

    bytes32[] public settleIds;

    /// @dev 정산 한도 버킷의 독립 장부. 컨트랙트의 periodId를 읽지 않는다.
    mapping(address => mapping(uint32 => uint256)) public ghost_quota;
    address[] internal _qkDriver;
    uint32[] internal _qkPeriod;
    mapping(bytes32 => bool) internal _qkSeen;

    mapping(bytes32 => address) internal _reqDriver;
    mapping(bytes32 => uint256) internal _reqAmount;
    mapping(bytes32 => uint32) internal _reqPeriod;

    // 마지막 성공 청구. 중복 재투입(replay)에 쓴다.
    address internal lastDriver;
    uint32 internal lastDay;
    uint8 internal lastSlot;
    uint16 internal lastVillage;
    bool internal hasLast;

    constructor(HappyTaxi t, address[] memory a, address admin_, address sub, address cnty, address setl) {
        taxi = t;
        admin = admin_;
        submitter = sub;
        county = cnty;
        settler = setl;
        for (uint256 i = 0; i < a.length; ++i) {
            actors.push(a[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              TARGETS
    //////////////////////////////////////////////////////////////*/

    function submitMeter(uint256 actorSeed, uint256 daySeed, uint8 slot, bool replay) external {
        address d;
        uint32 day;
        uint8 sl;
        uint16 village;
        if (replay && hasLast) {
            d = lastDriver;
            day = lastDay;
            sl = lastSlot;
            village = lastVillage;
            ghost_replayAttempts++;
        } else {
            d = actors[_bound(actorSeed, 0, actors.length - 1)];
            (bool ok, uint32 dd) = _pickDay(d, daySeed);
            if (!ok) return;
            day = dd;
            sl = uint8(_bound(uint256(slot), 0, 3));
            village = uint16(_bound(daySeed, 1, 10));
        }

        vm.prank(submitter);
        try taxi.submitRideMeter(d, _rideTs(day, sl), day, village, FARE, bytes32(uint256(0xA1))) {
            _note(d, day, sl, village, HappyTaxi.SubsidySource.MeterAuto);
        } catch (bytes memory err) {
            _noteRevert(err);
        }
    }

    function submitManual(uint256 actorSeed, uint256 daySeed, uint8 slot, uint16 pax, bool replay) external {
        address d;
        uint32 day;
        uint8 sl;
        uint16 village;
        if (replay && hasLast) {
            d = lastDriver;
            day = lastDay;
            sl = lastSlot;
            village = lastVillage;
            ghost_replayAttempts++;
        } else {
            d = actors[_bound(actorSeed, 0, actors.length - 1)];
            (bool ok, uint32 dd) = _pickDay(d, daySeed);
            if (!ok) return;
            day = dd;
            sl = uint8(_bound(uint256(slot), 0, 3));
            village = uint16(_bound(daySeed, 1, 10));
        }
        uint16 p = uint16(_bound(uint256(pax), 1, uint256(MAX_PASSENGERS)));

        vm.prank(submitter);
        try taxi.submitRideManual(d, _rideTs(day, sl), day, village, FARE, p, bytes32(uint256(0xA2))) {
            _note(d, day, sl, village, HappyTaxi.SubsidySource.ManualEntry);
        } catch (bytes memory err) {
            _noteRevert(err);
        }
    }

    /// @dev 상한을 20,000으로 잡는다. 1,000,000이면 첫 편성 한 번으로 예산이 사실상 무한이 되어
    ///      _allocate의 부분 절삭 구간이 생기지 않고 ACCT_2의 경계를 밟을 일이 없다.
    function deposit(uint256 amount) external {
        uint256 amt = _bound(amount, 1, 20_000);
        vm.prank(county);
        try taxi.depositBudget(amt) {} catch {}
    }

    function fund(uint256 maxSpend) external {
        uint256 m = _bound(maxSpend, 0, 1_000_000);
        address[] memory list = actors;
        vm.prank(county);
        try taxi.fundBacklog(list, m) returns (uint256) {} catch {}
    }

    function request(uint256 actorSeed, uint256 amount) external {
        address d = actors[_bound(actorSeed, 0, actors.length - 1)];
        uint256 amt = (_bound(amount, 0, 200_000) / 100) * 100;
        vm.prank(submitter);
        try taxi.requestSettlement(d, amt, bytes32(uint256(0xB1)), SIG) returns (bytes32 id) {
            settleIds.push(id);
            _noteRequest(id, d, amt);
        } catch (bytes memory err) {
            _noteRevert(err);
        }
    }

    function confirm(uint256 seed) external {
        if (settleIds.length == 0) return;
        bytes32 id = settleIds[_bound(seed, 0, settleIds.length - 1)];
        vm.prank(settler);
        try taxi.confirmSettlement(id) {} catch {}
    }

    function cancel(uint256 seed) external {
        if (settleIds.length == 0) return;
        bytes32 id = settleIds[_bound(seed, 0, settleIds.length - 1)];
        vm.prank(settler);
        try taxi.cancelSettlement(id) {
            ghost_quota[_reqDriver[id]][_reqPeriod[id]] -= _reqAmount[id];
        } catch (bytes memory err) {
            bytes4 sel;
            if (err.length >= 4) {
                assembly {
                    sel := mload(add(err, 0x20))
                }
            }
            if (sel == PANIC_SELECTOR) ghost_cancelPanic++;
        }
    }

    function clawbackSome(uint256 actorSeed, uint256 amount) external {
        address d = actors[_bound(actorSeed, 0, actors.length - 1)];
        uint256 cap = taxi.accruedBalance(d) + taxi.claimableBalance(d);
        if (cap == 0) return;
        uint256 amt = _bound(amount, 1, cap);
        vm.prank(admin);
        try taxi.clawback(d, amt, bytes32(uint256(0xC1))) {} catch {}
    }

    /// @dev 요청과 취소 사이에 정산 기간 정책을 바꾼다.
    ///      Settlement.periodId 저장이 막으려는 바로 그 상황이다.
    ///      이 타깃이 없으면 settlePeriodDays가 캠페인 내내 고정되어
    ///      periodId 저장이 실제로 무언가를 막고 있는지 확인할 방법이 없다.
    function changeSettlePeriod(uint8 d) external {
        uint32 nd = uint32(_bound(uint256(d), 1, 60));
        uint256 unit = taxi.minSettleUnit();
        uint256 cap = taxi.settlePeriodCap();
        vm.prank(admin);
        try taxi.setSettlePolicy(unit, cap, nd) {} catch {}
    }

    /// @dev pause/unpause는 핸들러에 넣지 않는다. [I5]를 invariant에서 빼는 이유와 같다.
    function warpDays(uint8 d) external {
        vm.warp(block.timestamp + _bound(uint256(d), 0, 10) * 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                              INTERNALS
    //////////////////////////////////////////////////////////////*/

    /// @dev 제출일을 최근 30일로 좁힌다. 이유 두 가지:
    ///
    ///      1. 운영 현실: 운영기관은 최근 운행을 올리지 200일 전 건을 무작위로 올리지 않는다.
    ///      2. 테스트 팔력: accrualPeriodDays가 30이라 [joinedDay, today] 전구간(200일)을
    ///         쓰면 청구가 8개 기간 버킷으로 흔어져 기사당 버킷당 0.1건꼴이 된다.
    ///         그러면 [I1] 상한에 영원히 도달하지 못해 INV_CAP_1이 자동으로 참이 되고,
    ///         상한 검사를 지운 변이본(M1)과 정상본이 구분되지 않는다.
    ///         실제로 첫 구현에서 M1 캐페인이 통과해 버렸고, 그게 이 주석의 이유다.
    function _pickDay(address d, uint256 seed) internal view returns (bool, uint32) {
        (,, uint32 joined) = taxi.drivers(d);
        uint32 today = taxi.currentDay();
        if (today < joined) return (false, 0);
        uint32 lo = today > joined + 29 ? today - 29 : joined;
        return (true, uint32(_bound(seed, lo, today)));
    }

    function _note(address d, uint32 day, uint8 slot, uint16 village, HappyTaxi.SubsidySource s) internal {
        ghost_accrueSucceeded++;
        bytes32 id = taxi.rideIdOf(_vehicleOf(d), _rideTs(day, slot), village);
        if (!_seen[id]) {
            _seen[id] = true;
            ghost_distinctRideIds++;
        }
        lastDriver = d;
        lastDay = day;
        lastSlot = slot;
        lastVillage = village;
        hasLast = true;

        (, uint256 cap,) = taxi.subsidyConfig(s);
        if (cap > 0) {
            uint256 bps = (taxi.accruedInPeriod(d, taxi.accrualPeriodOf(day), s) * 10_000) / cap;
            if (bps > ghost_maxCapRatioBps) ghost_maxCapRatioBps = bps;
        }
    }

    function _noteRequest(bytes32 id, address d, uint256 amt) internal {
        uint32 p = taxi.settlePeriodOf(taxi.currentDay());
        _reqDriver[id] = d;
        _reqAmount[id] = amt;
        _reqPeriod[id] = p;
        ghost_quota[d][p] += amt;

        bytes32 k = keccak256(abi.encode(d, p));
        if (!_qkSeen[k]) {
            _qkSeen[k] = true;
            _qkDriver.push(d);
            _qkPeriod.push(p);
        }
    }

    function quotaSnapshot()
        external
        view
        returns (address[] memory cs, uint32[] memory ps, uint256[] memory amts)
    {
        uint256 n = _qkDriver.length;
        cs = new address[](n);
        ps = new uint32[](n);
        amts = new uint256[](n);
        for (uint256 i = 0; i < n; ++i) {
            cs[i] = _qkDriver[i];
            ps[i] = _qkPeriod[i];
            amts[i] = ghost_quota[_qkDriver[i]][_qkPeriod[i]];
        }
    }

    function _noteRevert(bytes memory err) internal {
        bytes4 sel;
        if (err.length >= 4) {
            assembly {
                sel := mload(add(err, 0x20))
            }
        }
        if (sel == HappyTaxi.RideAlreadyClaimed.selector) {
            ghost_revertDupe++;
        } else if (sel == HappyTaxi.PeriodCapExceeded.selector) {
            ghost_revertCap++;
        } else if (sel == HappyTaxi.InsufficientClaimable.selector) {
            ghost_revertClaimable++;
        } else {
            ghost_revertOther++;
        }
    }

    function actorList() external view returns (address[] memory) {
        return actors;
    }

    function settleCount() external view returns (uint256) {
        return settleIds.length;
    }
}

/*//////////////////////////////////////////////////////////////////////////
                              INVARIANT 스위트
//////////////////////////////////////////////////////////////////////////*/

contract HappyTaxiInvariantTest is HappyTaxiSupport {
    HappyTaxi internal taxi;
    HappyTaxiHandler internal handler;
    address[] internal actors;

    function setUp() public {
        vm.warp(uint256(START_DAY) * 1 days);

        taxi = new HappyTaxi(admin, EPOCH_DAY);
        _bootstrap(taxi);

        address[] memory a = _makeDrivers(8);
        _registerAll(taxi, a);
        for (uint256 i = 0; i < a.length; ++i) {
            actors.push(a[i]);
        }

        handler = new HappyTaxiHandler(taxi, a, admin, submitter, county, settler);

        // 핸들러가 Test를 상속하므로 상속된 public 함수가 퍼즈 표면에 섞이지 않도록
        // 셀렉터를 명시적으로 고정한다.
        bytes4[] memory sel = new bytes4[](10);
        sel[0] = HappyTaxiHandler.submitMeter.selector;
        sel[1] = HappyTaxiHandler.submitManual.selector;
        sel[2] = HappyTaxiHandler.deposit.selector;
        sel[3] = HappyTaxiHandler.fund.selector;
        sel[4] = HappyTaxiHandler.request.selector;
        sel[5] = HappyTaxiHandler.confirm.selector;
        sel[6] = HappyTaxiHandler.cancel.selector;
        sel[7] = HappyTaxiHandler.clawbackSome.selector;
        sel[8] = HappyTaxiHandler.warpDays.selector;
        sel[9] = HappyTaxiHandler.changeSettlePeriod.selector;

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
    }

    /*//////////////////////////////////////////////////////////////
                        핸들러 비공허성 고정
    //////////////////////////////////////////////////////////////*/

    /// @notice 10개 타겟이 전부 실제로 상태를 움직이는지 결정론적으로 고정한다.
    ///
    /// 왜 afterInvariant가 아니라 별도 테스트인가:
    ///     Foundry는 캠페인이 끝나면 EVM 상태를 setUp 스냅샷으로 되돌린 뒤
    ///     afterInvariant를 부른다. 거기서 읽는 핸들러 고스트는 항상 초기값이다.
    ///     invariant_* 는 캠페인 도중 살아있는 상태를 본다. afterInvariant만 못 볼 뿐이다.
    function test_handlerSmoke_everyTargetMutatesState() public {
        // 1) 예산 0 상태에서 청구 → 전부 accrued로 남아야 한다
        for (uint256 s = 1; s <= 8; ++s) {
            handler.submitMeter(s, s * 4099, uint8(s % 4), false);
        }
        uint256 afterMeter = handler.ghost_accrueSucceeded();
        assertGt(afterMeter, 0, "submitMeter is inert");
        assertEq(taxi.budgetAllocated(), 0, "nothing may be allocated without budget");
        assertGt(taxi.unfundedDebt(), 0, "unfunded debt must be recorded");

        // 2) 중복 재투입 경로가 살아있고, 그게 실제로 막힌다
        handler.submitMeter(1, 4099, 1, true);
        assertGt(handler.ghost_replayAttempts(), 0, "replay path never taken");
        assertEq(handler.ghost_accrueSucceeded(), afterMeter, "duplicate must not accrue");
        assertEq(handler.ghost_accrueSucceeded(), handler.ghost_distinctRideIds(), "INV_ONCE_1");

        // 3) 수동입력 경로
        handler.submitManual(1, 8191, 2, 2, false);
        assertGt(handler.ghost_accrueSucceeded(), afterMeter, "submitManual is inert");

        // 4) 예산 편성 → 소급 확정
        //    deposit은 호출당 20,000으로 접힌다. 보조금 단가가 10,000~50,000이라
        //    한 번으로는 모자란다. 여러 번 불러 누적시킨다.
        for (uint256 i = 0; i < 10; ++i) {
            handler.deposit(500_000);
        }
        assertGt(taxi.budgetTotal(), 0, "deposit is inert");
        handler.fund(500_000);
        assertGt(taxi.budgetAllocated(), 0, "fundBacklog is inert");

        // 5) 정산 요청 → 확정
        handler.request(1, 1_000);
        assertEq(handler.settleCount(), 1, "requestSettlement is inert");
        handler.confirm(0);
        assertGt(taxi.budgetSettled(), 0, "confirmSettlement is inert");

        // 6) 정산 요청 → 익일 취소
        handler.request(2, 1_000);
        assertGt(taxi.lockedBalance(actors[2]), 0, "second request not locked");
        handler.warpDays(2);
        handler.cancel(1);
        assertEq(taxi.lockedBalance(actors[2]), 0, "cancelSettlement is inert");

        // 7) 정책 변경 타깃
        handler.changeSettlePeriod(7);
        assertEq(taxi.settlePeriodDays(), 7, "changeSettlePeriod is inert");

        // 8) 회수
        uint256 clawedBefore = taxi.totalClawedBack();
        for (uint256 s = 0; s < 8; ++s) {
            handler.clawbackSome(s, 500);
        }
        assertGt(taxi.totalClawedBack(), clawedBefore, "clawback is inert");

        assertTrue(holds_ACCT_1(taxi, actors), "INV_ACCT_1");
        assertTrue(holds_ACCT_2(taxi), "INV_ACCT_2");
        assertTrue(holds_ACCT_3(taxi, actors), "INV_ACCT_3");
        assertTrue(holds_CAP_1(taxi, actors), "INV_CAP_1");
    }

    function invariant_ACCT_1_conservation() public view {
        assertTrue(holds_ACCT_1(taxi, actors), "INV_ACCT_1: total conservation broken");
    }

    function invariant_ACCT_2_budgetMonotonic() public view {
        assertTrue(holds_ACCT_2(taxi), "INV_ACCT_2: settled <= allocated <= total broken");
    }

    function invariant_ACCT_3_allocatedWhereabouts() public view {
        assertTrue(holds_ACCT_3(taxi, actors), "INV_ACCT_3: allocated-settled != claimable+locked");
    }

    function invariant_CAP_1_periodCap() public view {
        assertTrue(holds_CAP_1(taxi, actors), "INV_CAP_1: period cap exceeded");
    }

    function invariant_ONCE_1_rideClaimedOnce() public view {
        assertEq(
            handler.ghost_accrueSucceeded(), handler.ghost_distinctRideIds(), "INV_ONCE_1: duplicate ride claimed"
        );
    }

    /// @notice 청구 순간에 측정한 상한 도달률은 100%를 넘을 수 없다.
    /// @dev INV_CAP_1과 같은 명제를 다른 경로로 구한 독립 증인.
    function invariant_COVERAGE_capRatioNeverExceeds100pct() public view {
        assertLe(handler.ghost_maxCapRatioBps(), 10_000, "cap ratio > 100% observed at accrual time");
    }

    /// @notice 정산 한도 버킷 정합성. 요청이 더한 버킷에서 취소가 빼는가.
    function invariant_QUOTA_1_periodQuotaMatchesRequests() public view {
        (address[] memory cs, uint32[] memory ps, uint256[] memory amts) = handler.quotaSnapshot();
        assertTrue(holds_QUOTA_1(taxi, cs, ps, amts), "INV_QUOTA_1: settledInPeriod bucket mismatch");
    }

    /// @notice cancelSettlement은 산술 panic으로 죽지 않는다.
    /// @dev Settlement.periodId 저장이 주는 보장을 직접 진술한다.
    ///      핸들러의 changeSettlePeriod 타깃이 그 상황을 캠페인 동안 계속 만든다.
    function invariant_QUOTA_2_cancelNeverPanics() public view {
        assertEq(handler.ghost_cancelPanic(), 0, "cancelSettlement underflowed: wrong period bucket");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                         유닛 — 해피패스 / [I5] / [I6]
//////////////////////////////////////////////////////////////////////////*/

contract HappyTaxiUnitTest is HappyTaxiSupport {
    HappyTaxi internal taxi;
    address internal alice; // 기사 A
    address internal bob; // 기사 B

    function setUp() public {
        vm.warp(uint256(START_DAY) * 1 days);
        taxi = new HappyTaxi(admin, EPOCH_DAY);
        _bootstrap(taxi);

        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(submitter);
        taxi.registerDriver(alice, _vehicleOf(alice), JOIN_DAY);
        taxi.registerDriver(bob, _vehicleOf(bob), JOIN_DAY);
        vm.stopPrank();
    }

    function _day() internal pure returns (uint32) {
        return START_DAY - 1;
    }

    function _actors() internal view returns (address[] memory a) {
        a = new address[](2);
        a[0] = alice;
        a[1] = bob;
    }

    /// @dev claimable을 정상 경로로 만든다. 예산을 먼저 넣으므로 _allocate가 즉시 배정한다.
    ///      amount는 SUBSIDY(10,000)의 배수여야 하고, MeterAuto 기간 상한(30,000) 안이어야 한다.
    function _fundAlice(uint256 amount) internal {
        vm.prank(county);
        taxi.depositBudget(amount);

        uint256 need = amount / SUBSIDY;
        vm.startPrank(submitter);
        for (uint256 i = 0; i < need; ++i) {
            taxi.submitRideMeter(alice, _rideTs(_day(), uint8(i)), _day(), VILLAGE_OK, FARE, bytes32(0));
        }
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                              해피패스
    //////////////////////////////////////////////////////////////*/

    /// @notice 논지 그 자체: 예산 0에서도 청구권은 확정되고, 나중에 소급 확정된다.
    function test_accrueWithZeroBudget_thenFundBacklog() public {
        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(uint256(1)));

        assertEq(taxi.accruedBalance(alice), SUBSIDY, "accrued");
        assertEq(taxi.claimableBalance(alice), 0, "claimable must stay 0");
        assertEq(taxi.budgetAllocated(), 0, "nothing allocated");
        assertEq(taxi.unfundedDebt(), SUBSIDY, "unfunded debt recorded");

        vm.prank(county);
        taxi.depositBudget(SUBSIDY);

        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(county);
        uint256 allocated = taxi.fundBacklog(list, SUBSIDY);

        assertEq(allocated, SUBSIDY, "allocated retroactively");
        assertEq(taxi.accruedBalance(alice), 0, "accrued drained");
        assertEq(taxi.claimableBalance(alice), SUBSIDY, "now claimable");
        assertEq(taxi.unfundedDebt(), 0, "debt cleared");

        assertTrue(holds_ACCT_1(taxi, _actors()), "ACCT_1");
        assertTrue(holds_ACCT_3(taxi, _actors()), "ACCT_3");
    }

    /// @notice 부분 집행이 정상 결과임을 보인다.
    function test_fundBacklog_partialIsNormal() public {
        vm.startPrank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        taxi.submitRideMeter(bob, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.stopPrank();

        vm.prank(county);
        taxi.depositBudget(15_000); // 둘 다 주기엔 5,000 모자란다

        address[] memory list = new address[](2);
        list[0] = alice;
        list[1] = bob;
        vm.prank(county);
        uint256 allocated = taxi.fundBacklog(list, 15_000);

        assertEq(allocated, 15_000, "spent everything available");
        assertEq(taxi.claimableBalance(alice), 10_000, "alice fully funded first (FIFO)");
        assertEq(taxi.claimableBalance(bob), 5_000, "bob partially funded");
        assertEq(taxi.accruedBalance(bob), 5_000, "bob remainder stays accrued");
        assertTrue(holds_ACCT_2(taxi), "ACCT_2");
        assertTrue(holds_ACCT_3(taxi, _actors()), "ACCT_3");
    }

    function test_settlement_requestThenConfirm() public {
        _fundAlice(30_000);

        vm.prank(submitter);
        bytes32 id = taxi.requestSettlement(alice, 10_000, bytes32(uint256(42)), SIG);

        assertEq(taxi.lockedBalance(alice), 10_000, "locked");
        assertEq(taxi.budgetSettled(), 0, "not settled yet");

        vm.prank(settler);
        taxi.confirmSettlement(id);

        assertEq(taxi.lockedBalance(alice), 0, "unlocked");
        assertEq(taxi.budgetSettled(), 10_000, "settled");
        assertTrue(holds_ACCT_1(taxi, _actors()), "ACCT_1");
        assertTrue(holds_ACCT_3(taxi, _actors()), "ACCT_3");
    }

    /// @notice 익일 취소. 한도도 같이 되돌아온다.
    function test_settlement_cancelRestoresQuota() public {
        _fundAlice(30_000);

        vm.prank(submitter);
        bytes32 id = taxi.requestSettlement(alice, 10_000, bytes32(0), SIG);

        uint32 period = taxi.settlePeriodOf(taxi.currentDay());
        assertEq(taxi.settledInPeriod(alice, period), 10_000, "quota consumed");

        vm.warp(block.timestamp + 1 days);
        vm.prank(settler);
        taxi.cancelSettlement(id);

        assertEq(taxi.claimableBalance(alice), 30_000, "returned to claimable");
        assertEq(taxi.settledInPeriod(alice, period), 0, "quota restored");
        assertTrue(holds_ACCT_1(taxi, _actors()), "ACCT_1");
    }

    function test_cancelSettlement_sameDayReverts() public {
        _fundAlice(10_000);
        vm.prank(submitter);
        bytes32 id = taxi.requestSettlement(alice, 10_000, bytes32(0), SIG);

        uint32 today = taxi.currentDay();
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.CancelTooEarly.selector, today, today));
        taxi.cancelSettlement(id);
    }

    /*//////////////////////////////////////////////////////////////
                          도메인 고유 검사
    //////////////////////////////////////////////////////////////*/

    /// @notice 자격 판정의 전부: 출발 마을이 지원 대상인가.
    function test_villageNotSupportedReverts() public {
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.VillageNotSupported.selector, VILLAGE_BAD));
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_BAD, FARE, bytes32(0));
    }

    /// @notice 지원 마을 카운터. 조례 개정 후 71이 되어야 한다.
    /// @dev 현재는 자리표시자 10개. 실제 목록 주입 여부를 이 값으로 확인한다. ★가정(5)
    function test_villageSupportCounterAndIdempotence() public {
        assertEq(taxi.supportedVillageCount(), 10, "bootstrap registered 10 placeholder villages");

        vm.startPrank(admin);
        taxi.setVillageSupport(1, true); // 멱등. 카운터가 오르면 안 된다.
        assertEq(taxi.supportedVillageCount(), 10, "idempotent re-enable");

        taxi.setVillageSupport(11, true);
        assertEq(taxi.supportedVillageCount(), 11, "new village counted");

        taxi.setVillageSupport(11, false);
        assertEq(taxi.supportedVillageCount(), 10, "removal decrements");
        vm.stopPrank();
    }

    /// @notice 같은 운행을 자동·수동 두 방식으로 이중 청구할 수 없다.
    ///
    /// @dev 이 출품작의 도메인 핵심이다. 스키마가 당회운행요금(자동)과 수동입력운행요금을
    ///      따로 들고 예상요금차이비교(%)로 대사한다는 것은 둘이 같은 운행의 두 관측치라는 뜻이다.
    ///      운행ID에 SubsidySource를 넣지 않은 것이 이 성질을 만든다.
    function test_sameRideCannotBeClaimedUnderBothInputMethods() public {
        uint64 ts = _rideTs(_day(), 0);

        vm.prank(submitter);
        taxi.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0));

        bytes32 rideId = taxi.rideIdOf(_vehicleOf(alice), ts, VILLAGE_OK);

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RideAlreadyClaimed.selector, rideId));
        taxi.submitRideManual(alice, ts, _day(), VILLAGE_OK, FARE, 2, bytes32(0));

        assertEq(taxi.accruedBalance(alice), SUBSIDY, "claimed exactly once");
    }

    /// @notice 승객부담액보다 싼 운행은 보조 대상이 아니다. 0으로 절삭하지 않고 반려한다.
    function test_fareBelowPassengerShareReverts() public {
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.FareBelowPassengerShare.selector, 500, PASSENGER_SHARE));
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, 500, bytes32(0));
    }

    /// @notice 회당 상한이 보조금을 절삭한다. ★가정(2)
    function test_perRideCapClampsSubsidy() public {
        // 요금 100,000 → 차액 99,000 이지만 회당 상한 10,000으로 잘린다
        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, 100_000, bytes32(0));
        assertEq(taxi.accruedBalance(alice), PER_RIDE_CAP, "clamped to per-ride cap");
    }

    /// @notice 수동입력 경로의 승차자수 검사.
    function test_manualPassengerBounds() public {
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.ZeroPassengers.selector);
        taxi.submitRideManual(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, 0, bytes32(0));

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.PassengersExceedMax.selector, 9, MAX_PASSENGERS));
        taxi.submitRideManual(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, 9, bytes32(0));
    }

    /*//////////////////////////////////////////////////////////////
                            불변식 유닛
    //////////////////////////////////////////////////////////////*/

    /// @notice [I2] 같은 운행 재청구는 반려된다.
    function test_I2_duplicateRideReverts() public {
        uint64 ts = _rideTs(_day(), 0);
        vm.prank(submitter);
        taxi.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0));

        bytes32 rideId = taxi.rideIdOf(_vehicleOf(alice), ts, VILLAGE_OK);
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RideAlreadyClaimed.selector, rideId));
        taxi.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(uint256(999))); // 증빙만 바꿔도 막힌다
    }

    /// @notice [I1] 기간 상한. MeterAuto 30,000 → 4건째가 막힌다.
    function test_I1_periodCapReverts() public {
        vm.startPrank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        taxi.submitRideMeter(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, bytes32(0));
        taxi.submitRideMeter(alice, _rideTs(_day(), 2), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                HappyTaxi.PeriodCapExceeded.selector, HappyTaxi.SubsidySource.MeterAuto, 40_000, CAP_METER
            )
        );
        taxi.submitRideMeter(alice, _rideTs(_day(), 3), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.stopPrank();

        assertTrue(holds_CAP_1(taxi, _actors()), "CAP_1 holds on the real contract");
    }

    /// @notice periodCap == 0 은 "해당 방식 청구 중단"이다.
    ///
    /// @dev 생성자가 subsidyConfig를 초기화하지 않으므로 배포 직후 상태가 바로 이것이다.
    ///      관리자가 상한을 넣기 전까지는 어느 청구도 통과하지 않는다 —
    ///      기본값 0이 fail-closed로 작동한다는 뜻이고, 그게 제도 관점에서 맞는 방향이다.
    function test_zeroPeriodCapBlocksSource() public {
        vm.prank(admin);
        taxi.setSubsidyConfig(HappyTaxi.SubsidySource.MeterAuto, PER_RIDE_CAP, 0, MAX_PASSENGERS);

        vm.prank(submitter);
        vm.expectRevert(
            abi.encodeWithSelector(
                HappyTaxi.PeriodCapExceeded.selector, HappyTaxi.SubsidySource.MeterAuto, SUBSIDY, 0
            )
        );
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));

        // 수동입력 경로는 영향을 받지 않는다. 방식별로 독립적으로 꺼질 수 있어야 한다.
        vm.prank(submitter);
        taxi.submitRideManual(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, 2, bytes32(0));
        assertEq(taxi.accruedBalance(alice), SUBSIDY, "manual path unaffected");
    }

    /// @notice [I4] 잔액 위로는 회수할 수 없고, accrued가 먼저 차감된다.
    function test_I4_clawbackOrderAndBound() public {
        _fundAlice(20_000); // 예산 20,000 → claimable 20,000 (2건)

        // 예산을 다 쓴 상태에서 한 건 더 청구하면 accrued로 남는다
        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 2), _day(), VILLAGE_OK, FARE, bytes32(0));

        assertEq(taxi.accruedBalance(alice), 10_000, "setup: accrued");
        assertEq(taxi.claimableBalance(alice), 20_000, "setup: claimable");
        assertEq(taxi.budgetAllocated(), 20_000, "setup: allocated");

        // [I4] 상한: accrued + claimable 위로는 못 간다. locked는 애초에 포함 안 된다.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.ClawbackExceedsBalance.selector, 30_001, 30_000));
        taxi.clawback(alice, 30_001, bytes32(0));

        // 차감 순서 1: accrued 범위 안이면 예산은 움직이지 않는다
        vm.prank(admin);
        taxi.clawback(alice, 10_000, bytes32(0));
        assertEq(taxi.accruedBalance(alice), 0, "accrued drained first");
        assertEq(taxi.claimableBalance(alice), 20_000, "claimable untouched");
        assertEq(taxi.budgetAllocated(), 20_000, "budget NOT returned yet");

        // 차감 순서 2: accrued가 마르면 claimable에서 나가고 그만큼 예산이 반납된다
        vm.prank(admin);
        taxi.clawback(alice, 15_000, bytes32(0));
        assertEq(taxi.claimableBalance(alice), 5_000, "claimable reduced");
        assertEq(taxi.budgetAllocated(), 5_000, "budget returned");

        assertTrue(holds_ACCT_1(taxi, _actors()), "ACCT_1");
        assertTrue(holds_ACCT_2(taxi), "ACCT_2");
        assertTrue(holds_ACCT_3(taxi, _actors()), "ACCT_3");
    }

    /*//////////////////////////////////////////////////////////////
              [I5] 이중 정지 스위치 — 차단 7건 + 예외 4건 + 교차 2건
    //////////////////////////////////////////////////////////////*/

    function _pauseSubmission() internal {
        vm.prank(pauser);
        taxi.pauseSubmission();
    }

    function _unpauseSubmission() internal {
        vm.prank(pauser);
        taxi.unpauseSubmission();
    }

    function _pauseSettlement() internal {
        vm.prank(pauser);
        taxi.pauseSettlement();
    }

    // --- 제출측 4건 ---

    function test_I5_1_registerDriver() public {
        _pauseSubmission();
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.registerDriver(makeAddr("carol"), keccak256("CAR"), JOIN_DAY);
    }

    function test_I5_2_setVehicle() public {
        _pauseSubmission();
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.setVehicle(alice, keccak256("NEWCAR"));
    }

    function test_I5_3_submitRideMeter() public {
        _pauseSubmission();
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
    }

    function test_I5_4_submitRideManual() public {
        _pauseSubmission();
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.submitRideManual(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, 2, bytes32(0));
    }

    // --- 정산측 2건 ---

    function test_I5_6_requestSettlement() public {
        _pauseSettlement();
        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SettlementIsPaused.selector);
        taxi.requestSettlement(alice, 100, bytes32(0), SIG);
    }

    function test_I5_7_confirmSettlement() public {
        _pauseSettlement();
        vm.prank(settler);
        vm.expectRevert(HappyTaxi.SettlementIsPaused.selector);
        taxi.confirmSettlement(bytes32(uint256(1)));
    }

    // --- 예외 4건: 어느 스위치로도 막히지 않는다 ---

    /// @notice 소급 지급은 양쪽 스위치가 다 올라가 있어도 돌아간다.
    ///         이게 논지를 무조건부로 만드는 테스트다.
    function test_I5_8_fundBacklog_worksWhileBothPaused() public {
        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        assertEq(taxi.accruedBalance(alice), SUBSIDY, "setup: unfunded entitlement");

        vm.prank(county);
        taxi.depositBudget(SUBSIDY);

        _pauseSubmission();
        _pauseSettlement();

        address[] memory list = new address[](1);
        list[0] = alice;
        vm.prank(county);
        uint256 allocated = taxi.fundBacklog(list, SUBSIDY);

        assertEq(allocated, SUBSIDY, "retroactive funding must work while both switches are up");
        assertEq(taxi.claimableBalance(alice), SUBSIDY, "now claimable");
    }

    /// @notice 회수는 사고 대응 도구라 정지 중에 오히려 필요하다.
    function test_I5_9_clawback_worksWhileBothPaused() public {
        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));

        _pauseSubmission();
        _pauseSettlement();

        vm.prank(admin);
        taxi.clawback(alice, SUBSIDY, bytes32(0));

        assertEq(taxi.accruedBalance(alice), 0, "clawback must work during incident response");
        assertEq(taxi.totalClawedBack(), SUBSIDY, "recorded");
    }

    function test_I5_10_exceptions_depositAndCancelStillWork() public {
        _fundAlice(20_000);
        vm.prank(submitter);
        bytes32 id = taxi.requestSettlement(alice, 10_000, bytes32(0), SIG);
        vm.warp(block.timestamp + 1 days);

        _pauseSubmission();
        _pauseSettlement();

        vm.prank(county);
        taxi.depositBudget(50_000); // 재개 준비를 막을 이유가 없다

        vm.prank(settler);
        taxi.cancelSettlement(id); // 정확히 정산측이 멈췄을 때 필요한 함수다

        assertEq(taxi.lockedBalance(alice), 0, "unlocked while both switches are up");
    }

    // --- 교차 2건: 분리가 실제로 의미가 있는가 ---

    /// @notice 제출만 정지 → 정산은 끝까지 동작한다.
    function test_I5_11_submissionPausedButSettlementWorks() public {
        _fundAlice(30_000);

        _pauseSubmission();

        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.submitRideMeter(alice, _rideTs(_day(), 5), _day(), VILLAGE_OK, FARE, bytes32(0));

        vm.prank(submitter);
        bytes32 id = taxi.requestSettlement(alice, 10_000, bytes32(0), SIG);
        assertEq(taxi.lockedBalance(alice), 10_000, "request must work while submission is paused");

        vm.prank(settler);
        taxi.confirmSettlement(id);
        assertEq(taxi.budgetSettled(), 10_000, "confirm must work while submission is paused");
    }

    /// @notice 정산만 정지 → 운행 기록은 계속 남는다.
    ///         기사는 이미 손님을 태웠다. 그 사실이 사라지면 소급 지급 근거가 없어진다.
    function test_I5_12_settlementPausedButSubmissionWorks() public {
        _fundAlice(10_000);

        _pauseSettlement();

        vm.prank(submitter);
        vm.expectRevert(HappyTaxi.SettlementIsPaused.selector);
        taxi.requestSettlement(alice, 10_000, bytes32(0), SIG);

        vm.prank(submitter);
        taxi.submitRideMeter(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, bytes32(0));

        assertEq(
            taxi.accruedBalance(alice) + taxi.claimableBalance(alice),
            20_000,
            "submission must keep recording while settlement is paused"
        );
        // 예산이 없으므로 새 청구분은 accrued로 남는다 — 바로 그게 논지다
        assertEq(taxi.accruedBalance(alice), 10_000, "unfunded entitlement is still recorded");
    }

    function test_I5_13_switchesAreIndependent() public {
        _pauseSubmission();
        assertTrue(taxi.submissionPaused(), "submission up");
        assertFalse(taxi.settlementPaused(), "settlement must stay down");

        vm.prank(pauser);
        vm.expectRevert(HappyTaxi.SubmissionIsPaused.selector);
        taxi.pauseSubmission();

        vm.prank(pauser);
        vm.expectRevert(HappyTaxi.SettlementNotPaused.selector);
        taxi.unpauseSettlement();

        _unpauseSubmission();
        assertFalse(taxi.submissionPaused(), "submission down");
    }

    /// @notice clawback 주석의 "관리자는 두 트랜잭션으로 정지를 풀 수 있다"를 실제로 보인다.
    function test_I5_adminCanSelfGrantPauserAndUnpause() public {
        bytes32 rPauser = taxi.PAUSER_ROLE();
        _pauseSubmission();

        // 1) 관리자는 PAUSER가 아니므로 곧바로 풀지 못한다
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, rPauser)
        );
        taxi.unpauseSubmission();

        // 2) PAUSER_ROLE은 [I6] 상호배타 집합 밖이라 _requireExclusive가 조기 반환한다
        vm.prank(admin);
        taxi.grantRole(rPauser, admin);

        // 3) 이제 풀 수 있다 — 한 번이 아니라 두 트랜잭션 경로다
        vm.prank(admin);
        taxi.unpauseSubmission();
        assertFalse(taxi.submissionPaused(), "admin unpaused in two transactions");
    }

    /*//////////////////////////////////////////////////////////////
                  [I6] 역할 분리 — grantRole 실패 6건
    //////////////////////////////////////////////////////////////*/

    /// @dev 역할 상수는 전부 미리 집어둔다. taxi.RIDE_SUBMITTER_ROLE()은 외부 호출이라
    ///      expectRevert 바로 뒤에서 불러지면 "다음 호출"을 그 getter가 가로챈다.
    function _expectSoD(address who, bytes32 conflicting) internal {
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RoleSeparationViolated.selector, who, conflicting));
    }

    function test_I6_1_submitterCannotBecomeAdmin() public {
        address x = makeAddr("x1");
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rAdmin = taxi.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rSub, x);
        _expectSoD(x, rSub);
        taxi.grantRole(rAdmin, x);
        vm.stopPrank();
    }

    /// @notice 그룹 2 안의 겸직은 허용된다. 제출과 요청은 둘 다 운영기관의 일이다.
    ///
    /// @dev 이게 배타로 막히면 초기 배포에서 운영기관이 지갑 두 개를 운영해야 한다.
    ///      나중에 분리하고 싶으면 revokeRole 한 번이면 되므로 확장성은 잃지 않는다.
    function test_I6_operatorMayHoldBothSubmitAndRequest() public {
        address x = makeAddr("operator");
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rReq = taxi.SETTLEMENT_REQUESTER_ROLE();

        vm.startPrank(admin);
        taxi.grantRole(rSub, x);
        taxi.grantRole(rReq, x); // 같은 그룹 — 통과해야 한다
        vm.stopPrank();

        assertTrue(taxi.hasRole(rSub, x), "submitter");
        assertTrue(taxi.hasRole(rReq, x), "requester");

        // 그러나 정산기관은 여전히 겸할 수 없다 — 그게 [I6]의 핵심이다
        bytes32 rSetl = taxi.SETTLEMENT_ROLE();
        vm.prank(admin);
        _expectSoD(x, rSub);
        taxi.grantRole(rSetl, x);
    }

    /// @notice 요청 역할도 정산기관과 배타다.
    function test_I6_7_requesterCannotBecomeSettler() public {
        address x = makeAddr("x7");
        bytes32 rReq = taxi.SETTLEMENT_REQUESTER_ROLE();
        bytes32 rSetl = taxi.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rReq, x);
        _expectSoD(x, rReq);
        taxi.grantRole(rSetl, x);
        vm.stopPrank();
    }

    function test_I6_2_countyCannotBecomeAdmin() public {
        address x = makeAddr("x2");
        bytes32 rCounty = taxi.COUNTY_ROLE();
        bytes32 rAdmin = taxi.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rCounty, x);
        _expectSoD(x, rCounty);
        taxi.grantRole(rAdmin, x);
        vm.stopPrank();
    }

    function test_I6_3_settlerCannotBecomeAdmin() public {
        address x = makeAddr("x3");
        bytes32 rSetl = taxi.SETTLEMENT_ROLE();
        bytes32 rAdmin = taxi.DEFAULT_ADMIN_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rSetl, x);
        _expectSoD(x, rSetl);
        taxi.grantRole(rAdmin, x);
        vm.stopPrank();
    }

    function test_I6_4_submitterCannotBecomeCounty() public {
        address x = makeAddr("x4");
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rCounty = taxi.COUNTY_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rSub, x);
        _expectSoD(x, rSub);
        taxi.grantRole(rCounty, x);
        vm.stopPrank();
    }

    function test_I6_5_submitterCannotBecomeSettler() public {
        address x = makeAddr("x5");
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rSetl = taxi.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rSub, x);
        _expectSoD(x, rSub);
        taxi.grantRole(rSetl, x);
        vm.stopPrank();
    }

    function test_I6_6_countyCannotBecomeSettler() public {
        address x = makeAddr("x6");
        bytes32 rCounty = taxi.COUNTY_ROLE();
        bytes32 rSetl = taxi.SETTLEMENT_ROLE();
        vm.startPrank(admin);
        taxi.grantRole(rCounty, x);
        _expectSoD(x, rCounty);
        taxi.grantRole(rSetl, x);
        vm.stopPrank();
    }

    /// @notice PAUSER는 배타 집합 밖이다. 겸직이 허용되어야 한다.
    function test_I6_pauserIsOrthogonal() public {
        bytes32 rPauser = taxi.PAUSER_ROLE();
        vm.prank(admin);
        taxi.grantRole(rPauser, submitter); // 제출자와 겸직
        assertTrue(taxi.hasRole(rPauser, submitter), "pauser may coexist");
    }

    /// @notice [I6] 축 2 — 등록 기사에게 운영기관 역할을 줄 수 없다.
    ///
    /// @dev 축 1(역할↔역할)만 있을 때는 이게 통과했다.
    ///      역할은 역할끼리만 비교하므로 "이 주소가 기사로 등록돼 있는가"를 볼 수 없었다.
    ///      그 틈으로 관리자가 기사 주소에 RIDE_SUBMITTER를 주면
    ///      자기 운행을 자기가 증명하는 구조가 성립했다.
    function test_I6_registeredDriverCannotBecomeOperator() public {
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rReq = taxi.SETTLEMENT_REQUESTER_ROLE();

        // alice는 setUp에서 이미 기사로 등록돼 있다
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RoleBeneficiaryConflict.selector, alice, rSub));
        taxi.grantRole(rSub, alice);

        // 요청 역할도 마찬가지다. 그룹 전체를 막는다.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RoleBeneficiaryConflict.selector, alice, rReq));
        taxi.grantRole(rReq, alice);

        // 그룹 2가 아닌 역할은 영향을 받지 않는다 — 축 2는 그룹 2 전용이다
        bytes32 rPauser = taxi.PAUSER_ROLE();
        vm.prank(admin);
        taxi.grantRole(rPauser, alice);
        assertTrue(taxi.hasRole(rPauser, alice), "PAUSER is outside the beneficiary axis");
    }

    /// @notice [I6] 축 2 — 운영기관 역할 보유자를 기사로 등록할 수 없다.
    ///
    /// @dev 위 테스트의 대칭이다. 한 쪽만 막으면 순서를 바꿔 우회할 수 있다 —
    ///      역할을 먼저 받은 뒤 기사로 등록하면 같은 상태에 도달한다.
    function test_I6_operatorCannotBeRegisteredAsDriver() public {
        address opSubmit = makeAddr("opSubmit");
        address opRequest = makeAddr("opRequest");
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        bytes32 rReq = taxi.SETTLEMENT_REQUESTER_ROLE();

        vm.startPrank(admin);
        taxi.grantRole(rSub, opSubmit);
        taxi.grantRole(rReq, opRequest);
        vm.stopPrank();

        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RoleBeneficiaryConflict.selector, opSubmit, rSub));
        taxi.registerDriver(opSubmit, keccak256("CAR-A"), JOIN_DAY);

        // 요청 역할만 가진 주소도 막힌다.
        // RIDE_SUBMITTER만 검사했다면 여기가 빠져나가 대칭이 깨졌을 것이다.
        vm.prank(submitter);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RoleBeneficiaryConflict.selector, opRequest, rReq));
        taxi.registerDriver(opRequest, keccak256("CAR-B"), JOIN_DAY);
    }

    /// @notice 기사 본인은 정산을 직접 요청할 수 없다. 운영기관을 거쳐야 한다.
    ///
    /// @dev 대리 구조로 바꾸면서 생긴 새 거동이라 명시적으로 고정한다.
    ///      청구 의사는 driverSigHash로 감사 추적에 남는다.
    function test_I6_driverCannotRequestSettlementDirectly() public {
        bytes32 rReq = taxi.SETTLEMENT_REQUESTER_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, rReq)
        );
        taxi.requestSettlement(alice, 100, bytes32(0), SIG);
    }

    /// @notice 권한 없는 호출은 AccessControl이 막는다.
    ///         특히 기사 본인이 자기 운행을 올리는 경로가 없어야 한다.
    function test_I6_driverCannotSubmitOwnRide() public {
        bytes32 rSub = taxi.RIDE_SUBMITTER_ROLE();
        uint32 d = _day();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, rSub)
        );
        taxi.submitRideMeter(alice, _rideTs(d, 0), d, VILLAGE_OK, FARE, bytes32(0));
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        변이 테스트 M1 / M2 / M3 / M4
////////////////////////////////////////////////////////////////////////////

각 테스트는 두 가지를 같이 보인다:
    1. 정상 컨트랙트에서는 해당 검사가 실제로 막는다
    2. 검사를 한 줄 지운 변이본에서는 같은 시퀀스가 통과하고 불변식이 거짓이 된다

//////////////////////////////////////////////////////////////////////////*/

contract HappyTaxiMutationTest is HappyTaxiSupport {
    address internal alice;

    function setUp() public {
        vm.warp(uint256(START_DAY) * 1 days);
        alice = makeAddr("alice");
    }

    function _prep(HappyTaxi t) internal returns (address[] memory a) {
        _bootstrap(t);
        a = new address[](1);
        a[0] = alice;
        vm.prank(submitter);
        t.registerDriver(alice, _vehicleOf(alice), JOIN_DAY);
    }

    function _day() internal pure returns (uint32) {
        return START_DAY - 1;
    }

    /// @notice M1 — [I1] 상한 revert를 지우면 INV_CAP_1이 깨진다.
    function test_M1_periodCapRemoved_breaksCAP_1() public {
        // 정상본: 상한 30,000에서 4건째가 막힌다
        HappyTaxi ok = new HappyTaxi(admin, EPOCH_DAY);
        address[] memory a = _prep(ok);
        vm.startPrank(submitter);
        ok.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        ok.submitRideMeter(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, bytes32(0));
        ok.submitRideMeter(alice, _rideTs(_day(), 2), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                HappyTaxi.PeriodCapExceeded.selector, HappyTaxi.SubsidySource.MeterAuto, 40_000, CAP_METER
            )
        );
        ok.submitRideMeter(alice, _rideTs(_day(), 3), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.stopPrank();
        assertTrue(holds_CAP_1(ok, a), "M1 control: CAP_1 holds");

        // 변이본: 4건째가 통과하고 상한이 뚫린다
        HappyTaxi mut = HappyTaxi(address(new HappyTaxiM1(admin, EPOCH_DAY)));
        _prep(mut);
        vm.startPrank(submitter);
        mut.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        mut.submitRideMeter(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, bytes32(0));
        mut.submitRideMeter(alice, _rideTs(_day(), 2), _day(), VILLAGE_OK, FARE, bytes32(0));
        mut.submitRideMeter(alice, _rideTs(_day(), 3), _day(), VILLAGE_OK, FARE, bytes32(0)); // 정상본이면 revert
        vm.stopPrank();

        uint32 p = mut.accrualPeriodOf(_day());
        assertEq(
            mut.accruedInPeriod(alice, p, HappyTaxi.SubsidySource.MeterAuto), 40_000, "cap blown through"
        );
        assertFalse(holds_CAP_1(mut, a), "M1: INV_CAP_1 must break");
    }

    /// @notice M2 — rideUsed 기록을 지우면 INV_ONCE_1이 깨진다.
    function test_M2_rideUsedRemoved_breaksONCE_1() public {
        // 정상본: 같은 운행 재청구가 막힌다
        HappyTaxi ok = new HappyTaxi(admin, EPOCH_DAY);
        _prep(ok);
        uint64 ts = _rideTs(_day(), 0);
        vm.startPrank(submitter);
        ok.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0));
        bytes32 id = ok.rideIdOf(_vehicleOf(alice), ts, VILLAGE_OK);
        vm.expectRevert(abi.encodeWithSelector(HappyTaxi.RideAlreadyClaimed.selector, id));
        ok.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.stopPrank();

        // 변이본: 같은 운행이 두 번 통과한다
        HappyTaxi mut = HappyTaxi(address(new HappyTaxiM2(admin, EPOCH_DAY)));
        _prep(mut);

        uint256 succeeded;
        uint256 distinct = 1; // 운행ID는 하나뿐이다

        vm.startPrank(submitter);
        mut.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0));
        succeeded++;
        mut.submitRideMeter(alice, ts, _day(), VILLAGE_OK, FARE, bytes32(0)); // 정상본이면 revert
        succeeded++;
        vm.stopPrank();

        assertEq(mut.accruedBalance(alice), 2 * SUBSIDY, "double claimed");
        assertTrue(succeeded != distinct, "M2: INV_ONCE_1 must break (succeeded != distinct)");
    }

    /// @notice M3 — _allocate의 예산 절삭을 지우면 INV_ACCT_2가 깨진다.
    function test_M3_budgetClampRemoved_breaksACCT_2() public {
        // 정상본: 예산 0이면 배정 0
        HappyTaxi ok = new HappyTaxi(admin, EPOCH_DAY);
        address[] memory a = _prep(ok);
        vm.prank(submitter);
        ok.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));

        assertEq(ok.budgetAllocated(), 0, "M3 control: nothing allocated");
        assertEq(ok.accruedBalance(alice), SUBSIDY, "M3 control: stays accrued");
        assertTrue(holds_ACCT_2(ok), "M3 control: ACCT_2 holds");
        assertTrue(holds_ACCT_3(ok, a), "M3 control: ACCT_3 holds");

        // 변이본: 예산이 0인데 배정이 일어난다
        HappyTaxi mut = HappyTaxi(address(new HappyTaxiM3(admin, EPOCH_DAY)));
        _prep(mut);
        vm.prank(submitter);
        mut.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));

        assertEq(mut.budgetTotal(), 0, "budget is still zero");
        assertEq(mut.budgetAllocated(), SUBSIDY, "but allocation happened");
        assertEq(mut.claimableBalance(alice), SUBSIDY, "driver can now settle unfunded money");
        assertFalse(holds_ACCT_2(mut), "M3: INV_ACCT_2 must break");
    }

    /// @notice M4 — cancelSettlement이 현재 기간에서 차감하면 한도 장부가 어긋난다.
    ///         뒤집어 말하면, s.periodId를 저장하는 설계가 실제로 일을 하고 있다는 증거다.
    function test_M4_cancelUsesCurrentPeriod_breaksQuotaLedger() public {
        // 정상본: 요청 버킷에서 빠진다
        HappyTaxi ok = new HappyTaxi(admin, EPOCH_DAY);
        _prep(ok);
        (uint32 p1, uint32 p2) = _crossPeriodCancel(ok);
        assertTrue(p1 != p2, "scenario must cross a settle period boundary");
        assertEq(ok.settledInPeriod(alice, p1), 0, "M4 control: request bucket released");
        assertEq(ok.settledInPeriod(alice, p2), 10_000, "M4 control: later bucket untouched");

        // 변이본: 현재 버킷을 긁어간다
        HappyTaxi mut = HappyTaxi(address(new HappyTaxiM4(admin, EPOCH_DAY)));
        _prep(mut);
        (uint32 q1, uint32 q2) = _crossPeriodCancel(mut);
        assertEq(mut.settledInPeriod(alice, q1), 10_000, "M4: request bucket stuck forever");
        assertEq(mut.settledInPeriod(alice, q2), 0, "M4: wrong bucket drained");
    }

    /// @dev 요청 → 정산 기간 경계 통과 → 새 기간에서 재요청 → 첫 요청 취소.
    ///      재요청이 있어야 변이본의 차감이 언더플로로 죽지 않고 조용히 잘못된 곳을 긁는다.
    function _crossPeriodCancel(HappyTaxi t) internal returns (uint32 p1, uint32 p2) {
        vm.prank(county);
        t.depositBudget(20_000);

        vm.startPrank(submitter);
        t.submitRideMeter(alice, _rideTs(_day(), 0), _day(), VILLAGE_OK, FARE, bytes32(0));
        t.submitRideMeter(alice, _rideTs(_day(), 1), _day(), VILLAGE_OK, FARE, bytes32(0));
        vm.stopPrank();

        p1 = t.settlePeriodOf(t.currentDay());
        vm.prank(submitter);
        bytes32 id1 = t.requestSettlement(alice, 10_000, bytes32(0), SIG);

        vm.warp(block.timestamp + 31 days); // settlePeriodDays = 30

        p2 = t.settlePeriodOf(t.currentDay());
        vm.prank(submitter);
        t.requestSettlement(alice, 10_000, bytes32(0), SIG);

        vm.prank(settler);
        t.cancelSettlement(id1);
    }
}
