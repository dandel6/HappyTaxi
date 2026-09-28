// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {HappyTaxi} from "../src/HappyTaxi.sol";
import {
    HappyTaxiSupport,
    HappyTaxiHandler,
    HappyTaxiM1,
    HappyTaxiM2,
    HappyTaxiM3,
    HappyTaxiM4
} from "../test/HappyTaxi.t.sol";

/*//////////////////////////////////////////////////////////////////////////
                    변이본에 invariant 캠페인을 그대로 적용
////////////////////////////////////////////////////////////////////////////

test/HappyTaxi.t.sol 의 HappyTaxiMutationTest 는 결정론적 시퀀스로 변이를 잡는다.
여기는 다른 질문에 답한다: 손으로 짠 시퀀스가 아니라 퍼저가 스스로 잡아내는가.

이 네 컨트랙트는 실패하는 것이 정상이다. 그래서 기본 프로파일에서 제외한다.
    forge test                          → test/ 만. 전부 통과해야 한다.
    FOUNDRY_PROFILE=mutants forge test  → 여기. 네 개 다 실패해야 한다.

통과해 버리면 그게 나쁜 신호다. 해당 불변식이 그 검사를 지키고 있지 않다는 뜻이다.

//////////////////////////////////////////////////////////////////////////*/

abstract contract MutantCampaignBase is HappyTaxiSupport {
    HappyTaxi internal taxi;
    HappyTaxiHandler internal handler;
    address[] internal actors;

    function _deployMutant() internal virtual returns (HappyTaxi);

    function setUp() public {
        vm.warp(uint256(START_DAY) * 1 days);

        taxi = _deployMutant();
        _bootstrap(taxi);

        address[] memory a = _makeDrivers(8);
        _registerAll(taxi, a);
        for (uint256 i = 0; i < a.length; ++i) {
            actors.push(a[i]);
        }

        handler = new HappyTaxiHandler(taxi, a, admin, submitter, county, settler);

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

    function invariant_ACCT_1_conservation() public view {
        assertTrue(holds_ACCT_1(taxi, actors), "INV_ACCT_1");
    }

    function invariant_ACCT_2_budgetMonotonic() public view {
        assertTrue(holds_ACCT_2(taxi), "INV_ACCT_2");
    }

    function invariant_ACCT_3_allocatedWhereabouts() public view {
        assertTrue(holds_ACCT_3(taxi, actors), "INV_ACCT_3");
    }

    function invariant_CAP_1_periodCap() public view {
        assertTrue(holds_CAP_1(taxi, actors), "INV_CAP_1");
    }

    function invariant_ONCE_1_rideClaimedOnce() public view {
        assertEq(handler.ghost_accrueSucceeded(), handler.ghost_distinctRideIds(), "INV_ONCE_1");
    }

    function invariant_COVERAGE_capRatioNeverExceeds100pct() public view {
        assertLe(handler.ghost_maxCapRatioBps(), 10_000, "cap ratio > 100%");
    }

    function invariant_QUOTA_1_periodQuotaMatchesRequests() public view {
        (address[] memory cs, uint32[] memory ps, uint256[] memory amts) = handler.quotaSnapshot();
        assertTrue(holds_QUOTA_1(taxi, cs, ps, amts), "INV_QUOTA_1");
    }

    function invariant_QUOTA_2_cancelNeverPanics() public view {
        assertEq(handler.ghost_cancelPanic(), 0, "cancelSettlement underflowed");
    }
}

/// @notice M1 — [I1] 기간 상한 revert 제거. INV_CAP_1 이 깨져야 한다.
contract M1Campaign is MutantCampaignBase {
    function _deployMutant() internal override returns (HappyTaxi) {
        return HappyTaxi(address(new HappyTaxiM1(admin, EPOCH_DAY)));
    }
}

/// @notice M2 — [I2] rideUsed 기록 제거. INV_ONCE_1 이 깨져야 한다.
contract M2Campaign is MutantCampaignBase {
    function _deployMutant() internal override returns (HappyTaxi) {
        return HappyTaxi(address(new HappyTaxiM2(admin, EPOCH_DAY)));
    }
}

/// @notice M3 — [I3] _allocate 예산 절삭 제거. INV_ACCT_2 가 깨져야 한다.
contract M3Campaign is MutantCampaignBase {
    function _deployMutant() internal override returns (HappyTaxi) {
        return HappyTaxi(address(new HappyTaxiM3(admin, EPOCH_DAY)));
    }
}

/// @notice M4 — cancelSettlement 이 현재 기간에서 차감. INV_QUOTA_2 가 깨져야 한다.
///
/// @dev 이건 다른 셋과 성격이 좀 다르다. M1~M3은 한 번의 잘못된 호출로 바로 깨지지만,
///      M4는 (1) 요청, (2) 기간 경계 통과 또는 정책 변경, (3) 같은 기사의 다른 요청,
///      (4) 첫 요청 취소 네 단계가 그 순서로 맞아야 INV_QUOTA_1이 깨진다.
///      (3)이 없으면 차감이 언더플로로 돌아가 try/catch에 삼켜지고 상태가 그대로라
///      상태 술어형 불변식은 원리적으로 그걸 볼 수 없다.
///      그래서 INV_QUOTA_2(cancel 은 panic 하지 않는다)를 따로 둔다 —
///      삼켜진 언더플로 자체를 고스트로 세서 안전성 명제로 바꾸는 방법이다.
///      핸들러의 changeSettlePeriod 타깃이 (2)를 캠페인 내내 계속 만든다.
contract M4Campaign is MutantCampaignBase {
    function _deployMutant() internal override returns (HappyTaxi) {
        return HappyTaxi(address(new HappyTaxiM4(admin, EPOCH_DAY)));
    }
}
