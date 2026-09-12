// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {OffsetDelta} from "../src/libraries/OffsetDelta.sol";

/// @notice Proves the belief offset moves value in the direction the mechanism claims,
///         against a real PoolManager. Section 4.2 of the spec calls this the test that
///         must exist before anything is built on top of it: an inverted sign still
///         compiles and still passes a naive happy-path test, while paying arbitrageurs.
contract SignConventionTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolKey internal plainKey;

    /// @dev delta = 0.01 in Q64.64 (100 bps), the spec's delta_max example.
    int256 internal constant DELTA_100BPS = int256(uint256(1 << 64)) / 100;

    /// @dev Deep, wide liquidity so a 1 ether swap executes without hitting the price
    ///      limit. A partially filled swap confounds the sign measurement.
    int24 internal constant TICK_LOWER = -60000;
    int24 internal constant TICK_UPPER = 60000;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (0x4444 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(plainKey, SQRT_PRICE_1_1);

        ModifyLiquidityParams memory liq = ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, 1000 ether, 0);
        modifyLiquidityRouter.modifyLiquidity(vaneKey, liq, "");
        modifyLiquidityRouter.modifyLiquidity(plainKey, liq, "");

        // Fund the reserve with claims. The hook settles offsets in ERC-6909
        // rather than moving ERC20, so the reserve must be seeded in that form.
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 1000 ether);
        hook.fundReserve(currency1, 1000 ether);
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        returns (int256 d0, int256 d1)
    {
        uint256 before0 = currency0.balanceOfSelf();
        uint256 before1 = currency1.balanceOfSelf();

        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        d0 = int256(currency0.balanceOfSelf()) - int256(before0);
        d1 = int256(currency1.balanceOfSelf()) - int256(before1);
    }

    /// @notice delta > 0 means the risky asset (currency0) is believed underpriced by the
    ///         curve, so a buyer of currency0 must pay strictly more. Invariant 5, buy side.
    function test_Sign_HookTakesWhenBuyingIntoPositiveBelief() public {
        (int256 p0, int256 p1) = _swap(plainKey, false, -1 ether);
        hook.setBelief(vaneKey, DELTA_100BPS);
        (int256 v0, int256 v1) = _swap(vaneKey, false, -1 ether);

        console2.log("plain currency0 received", p0);
        console2.log("plain currency1 paid    ", p1);
        console2.log("vane  currency0 received", v0);
        console2.log("vane  currency1 paid    ", v1);

        // Exact input pins the specified leg (currency1 paid), so the offset lands on
        // the unspecified leg: the buyer acquires strictly less of the risky asset for
        // the same numeraire, i.e. pays a strictly worse effective price.
        assertEq(v1, p1, "same numeraire paid, exact input");
        assertLt(v0, p0, "buyer into positive belief must receive strictly less risky asset");

        uint256 shortfall = uint256(p0 - v0);
        console2.log("risky asset forgone by buyer", shortfall);

        // Roughly delta * notional; not exactly the Taylor amount because the offset is
        // taken on the input leg and then routed through the curve.
        assertApproxEqRel(shortfall, 0.01 ether, 0.02e18, "offset must be ~1% of notional");
    }

    /// @notice The mirror case: delta > 0, a SELLER of the risky asset is quoted better.
    ///         A fee is unsigned and cannot do this. Invariant 5, sell side.
    function test_Sign_HookPaysWhenSellingIntoPositiveBelief() public {
        (int256 p0, int256 p1) = _swap(plainKey, true, -1 ether);
        hook.setBelief(vaneKey, DELTA_100BPS);
        (int256 v0, int256 v1) = _swap(vaneKey, true, -1 ether);

        console2.log("plain currency0 sold    ", p0);
        console2.log("plain currency1 received", p1);
        console2.log("vane  currency0 sold    ", v0);
        console2.log("vane  currency1 received", v1);

        // Exact input pins the risky asset sold, so the offset lands on the numeraire
        // received: the seller is quoted strictly better than the curve.
        assertEq(v0, p0, "same risky asset sold, exact input");
        assertGt(v1, p1, "seller into positive belief must receive strictly more numeraire");

        uint256 benefit = uint256(v1 - p1);
        console2.log("extra numeraire paid to seller", benefit);
        assertApproxEqRel(benefit, 0.01 ether, 0.02e18, "offset must be ~1% of notional");
    }

    /// @notice Both sides trade at a shifted price, in opposite directions. This is the
    ///         test that distinguishes a signed quote from a spread.
    function test_Sign_OffsetIsSignedNotAFee() public {
        // Measure the unspecified leg in each direction: that is where the offset lands
        // under exact input. The buyer receives less; the seller receives more; both are
        // trading at the same shifted price, in opposite directions.
        (int256 plainBuyGot,) = _swap(plainKey, false, -1 ether);
        (, int256 plainSellGot) = _swap(plainKey, true, -1 ether);

        hook.setBelief(vaneKey, DELTA_100BPS);
        (int256 vaneBuyGot,) = _swap(vaneKey, false, -1 ether);
        (, int256 vaneSellGot) = _swap(vaneKey, true, -1 ether);

        int256 buyerPenalty = plainBuyGot - vaneBuyGot;
        int256 sellerBenefit = vaneSellGot - plainSellGot;

        console2.log("buyer penalty ", buyerPenalty);
        console2.log("seller benefit", sellerBenefit);

        assertGt(buyerPenalty, 0, "buyer must be penalised");
        assertGt(sellerBenefit, 0, "seller must be compensated");
    }

    /// @notice Negative belief must invert the direction exactly.
    function test_Sign_NegativeBeliefInvertsDirection() public {
        (int256 p0, int256 p1) = _swap(plainKey, false, -1 ether);
        hook.setBelief(vaneKey, -DELTA_100BPS);
        (int256 v0, int256 v1) = _swap(vaneKey, false, -1 ether);

        assertEq(v1, p1, "same numeraire paid, exact input");
        assertGt(v0, p0, "buyer into negative belief must receive strictly more risky asset");
    }

    /// @notice Invariant 7: with the belief at zero, VANE is a strict no-op. This proves
    ///         the mechanism is an extension of a v4 pool, not a replacement.
    function test_ZeroBelief_IsExactNoOp() public {
        (int256 p0, int256 p1) = _swap(plainKey, true, -1 ether);
        (int256 v0, int256 v1) = _swap(vaneKey, true, -1 ether);

        assertEq(v0, p0, "currency0 flow must match plain pool exactly");
        assertEq(v1, p1, "currency1 flow must match plain pool exactly");
    }

    /// @notice Exact-output swaps invert which token is specified. Section 4.3 requires
    ///         both exactness modes work; this is the mode most likely to be wired wrong.
    function test_Sign_ExactOutputBuyAlsoPenalisesBuyer() public {
        (int256 p0, int256 p1) = _swap(plainKey, false, 1 ether);
        hook.setBelief(vaneKey, DELTA_100BPS);
        (int256 v0, int256 v1) = _swap(vaneKey, false, 1 ether);

        console2.log("exact-out plain c0 recv", p0);
        console2.log("exact-out plain c1 paid", p1);
        console2.log("exact-out vane  c0 recv", v0);
        console2.log("exact-out vane  c1 paid", v1);

        // Buyer must end up worse off on at least one leg, never better on both.
        bool worseOnZero = v0 < p0;
        bool worseOnOne = v1 < p1;
        assertTrue(worseOnZero || worseOnOne, "exact-output buyer must be penalised");
        assertFalse(v0 > p0 && v1 > p1, "buyer must never be better off on both legs");
    }
}
