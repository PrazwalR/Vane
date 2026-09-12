// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {PoolState, PoolStateAux} from "../src/libraries/PoolStateLib.sol";
import {DepthLib} from "../src/libraries/DepthLib.sol";
import {KappaLib} from "../src/libraries/KappaLib.sol";
import {HorizonVariance} from "../src/libraries/HorizonVariance.sol";
import {FlowVariance} from "../src/libraries/FlowVariance.sol";
import {FlowCovState} from "../src/libraries/FlowAutocovariance.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract IntegrationTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VaneHookHarness internal hook;
    PoolKey internal vaneKey;
    PoolId internal id;

    uint16 internal constant HORIZON_K = 20;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags ^ (0x8888 << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        vaneKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        id = vaneKey.toId();
        hook.allowPool(vaneKey);
        manager.initialize(vaneKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 5000 ether, 0), "");

        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 1000 ether);
        hook.fundReserve(currency1, 1000 ether);
    }

    function _swap(bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            vaneKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapOn(PoolKey memory key, bool zeroForOne, int256 amount) internal {
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_Init_SeedsTickBaselines() public view {
        PoolState memory s = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);

        assertEq(s.lastBlock, uint32(block.number), "lastBlock must be seeded");
        assertEq(a.checkpointBlock, uint32(block.number), "checkpointBlock must be seeded");
        assertEq(s.lastTick, a.checkpointTick, "both tick baselines start equal");
    }

    function test_Sampling_IsOncePerBlockNotPerSwap() public {
        _swap(true, -1 ether);
        _swap(true, -1 ether);
        _swap(true, -1 ether);

        PoolState memory s = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);

        assertEq(s.varOneX32, 0, "variance must not update inside a block");
        assertLt(a.flowAccum, 0, "flow must accumulate for a sell");

        uint32 blockBefore = s.lastBlock;
        vm.roll(block.number + 1);
        _swap(true, -1 ether);

        s = hook.poolState(id);
        assertGt(s.lastBlock, blockBefore, "block boundary must advance the sample");
        assertGt(s.varOneX32, 0, "variance must update on the first swap of a new block");
        assertEq(hook.poolStateAux(id).flowAccum, 0, "accumulator must reset after sampling");
    }

    function _makeDeep() internal {
        modifyLiquidityRouter.modifyLiquidity(vaneKey, ModifyLiquidityParams(-60000, 60000, 95_000 ether, 0), "");
    }

    function test_Checkpoint_SetsKappaFromPoolState() public {
        assertEq(hook.kappaOf(id), 0, "kappa starts at zero");
        _makeDeep();

        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
            _swap(i % 2 == 0, -5 ether);
        }

        PoolStateAux memory a = hook.poolStateAux(id);
        console2.log("kappa after horizon (Q64.64):", a.kappaX64);
        console2.log("varK  (Q32.32):", a.varKX32);
        console2.log("varOne(Q32.32):", hook.poolState(id).varOneX32);

        assertGt(a.varKX32, 0, "horizon variance must be populated by a trending price");

        assertGt(a.checkpointBlock, 1, "checkpoint must have advanced past its seed");
        assertGt(a.kappaX64, 0, "kappa must be set from real pool state");
        assertLe(a.kappaX64, uint64(uint256(1 << 64) / 1000), "kappa must respect its cap");
    }

    function test_Diagnostic_KappaInputs() public {
        _makeDeep();

        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
            _swap(i % 2 == 0, -5 ether);
        }

        PoolState memory st = hook.poolState(id);
        PoolStateAux memory a = hook.poolStateAux(id);

        (uint160 sqrtP,,,) = manager.getSlot0(id);
        uint256 depth = DepthLib.depthX64(manager.getLiquidity(id), sqrtP, 1e12);
        uint256 sigma = HorizonVariance.sigmaX64(a.varKX32, HORIZON_K);
        uint256 noise = FlowVariance.noiseScaleX64(st.flowVarX32);

        console2.log("liquidity        :", manager.getLiquidity(id));
        console2.log("depth   (Q64.64) :", depth);
        console2.log("varK    (Q32.32) :", a.varKX32);
        console2.log("sigma   (Q64.64) :", sigma);
        console2.log("flowVar (raw)    :", st.flowVarX32);
        console2.log("noise U (Q64.64) :", noise);
        console2.log("lambda_amm       :", KappaLib.lambdaAmmX64(depth));
        console2.log("lambda_star      :", KappaLib.lambdaStarX64(sigma, noise));
        console2.log("D* (Q64.64)      :", DepthLib.targetDepthX64(noise, sigma));
    }

    function test_Kappa_ShallowPoolNeedsNoCorrection() public {
        for (uint256 i = 0; i <= HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
        }

        assertEq(hook.kappaOf(id), 0, "an over-reacting pool must not be corrected");
    }

    function test_Checkpoint_FlatPriceLeavesKappaAtZero() public {
        for (uint256 i = 0; i <= HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -0.5 ether);
        }

        PoolStateAux memory a = hook.poolStateAux(id);
        console2.log("varK on an oscillating price:", a.varKX32);
        console2.log("kappa on an oscillating price:", a.kappaX64);

        assertGt(hook.poolState(id).varOneX32, 0, "per-block variance still registers the moves");
        assertEq(a.kappaX64, 0, "no horizon move means no fundamental volatility to price");
    }

    function test_Checkpoint_LongGapDoesNotInflateKappa() public {
        for (uint256 i = 0; i < HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
        }
        vm.roll(block.number + 1);
        _swap(true, -5 ether);
        uint256 kappaDense = hook.kappaOf(id);

        setUp();
        for (uint256 i = 0; i < HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
        }
        vm.roll(block.number + 100);
        _swap(true, -5 ether);
        uint256 kappaSparse = hook.kappaOf(id);

        console2.log("kappa, checkpoint at K blocks :", kappaDense);
        console2.log("kappa, checkpoint after a gap :", kappaSparse);

        assertLe(kappaSparse, kappaDense, "a long gap must not inflate kappa");
    }

    function test_Exploit_LongIdleThenViolentMoveDoesNotBrickPool() public {
        _swap(true, -1 ether);

        vm.roll(block.number + 5000);
        _swap(true, -400 ether);

        vm.roll(block.number + 1);
        _swap(false, -1 ether);
        vm.roll(block.number + 1);
        _swap(true, -1 ether);

        assertGt(hook.poolState(id).varOneX32, 0, "estimator must survive the excursion");
    }

    function test_Kappa_UsesNumeraireUnitsNotFlowUnits() public {
        _makeDeep();
        for (uint256 i = 0; i <= HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
        }

        uint256 kappa = hook.kappaOf(id);
        uint64 kappaMax = uint64(uint256(1 << 64) / 1000);

        console2.log("kappa:", kappa);
        console2.log("kappa cap:", kappaMax);

        assertLt(kappa, kappaMax / 2, "kappa near its cap indicates a scaling error");
    }

    function test_RouteB_DivergenceShrinksKappa() public {
        uint256 kappaAgreeing = _settleKappa(false);
        assertGt(kappaAgreeing, 0, "baseline kappa must be live for the test to mean anything");

        uint256 kappaDiverging = _settleKappa(true);

        console2.log("kappa, estimators agreeing :", kappaAgreeing);
        console2.log("kappa, estimators diverging:", kappaDiverging);

        assertLt(kappaDiverging, kappaAgreeing, "a divergent second opinion must shrink kappa");
    }

    function _settleKappa(bool forceDivergence) internal returns (uint256) {
        setUp();
        _makeDeep();
        for (uint256 i = 0; i < 400; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -5 ether);
            _swap(i % 2 == 0, -5 ether);
        }

        vm.roll(block.number + HORIZON_K + 1);

        if (forceDivergence) {
            uint64 fv = hook.poolState(id).flowVarX32;
            hook.setFlowCov(vaneKey, int64(uint64(fv / 2)), int64(uint64((uint256(fv) * 278) / 1000)));
        }

        _swap(true, -5 ether);

        return hook.kappaOf(id);
    }

    function test_Belief_EmergesFromOneSidedFlow() public {
        for (uint256 i = 0; i <= HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -0.5 ether);
        }

        hook.setKappa(vaneKey, uint64(uint256(1 << 64) / 1_000_000));

        int256 beliefBefore = hook.beliefOf(id);

        for (uint256 i = 0; i < 10; i++) {
            vm.roll(block.number + 1);
            _swap(false, -2 ether);
        }

        int256 beliefAfter = hook.beliefOf(id);
        console2.log("belief before one-sided buying:", beliefBefore);
        console2.log("belief after  one-sided buying:", beliefAfter);

        assertGt(beliefAfter, beliefBefore, "sustained buying must raise the belief");
    }

    function test_Belief_SignFollowsFlowDirection() public {
        hook.setKappa(vaneKey, uint64(uint256(1 << 64) / 1_000_000));

        for (uint256 i = 0; i < 10; i++) {
            vm.roll(block.number + 1);
            _swap(true, -2 ether);
        }

        int256 belief = hook.beliefOf(id);
        console2.log("belief after one-sided selling:", belief);
        assertLt(belief, 0, "sustained selling must drive the belief negative");
    }

    function test_Belief_DecaysWithoutFlow() public {
        hook.setBelief(vaneKey, int256(uint256(1 << 64)) / 200);
        int256 start = hook.beliefOf(id);

        for (uint256 i = 0; i < 15; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -1000 wei);
        }

        int256 ended = hook.beliefOf(id);
        console2.log("belief start:", start);
        console2.log("belief after decay:", ended);

        assertLt(ended, start, "belief must decay toward zero without supporting flow");
        assertGe(ended, 0, "decay must not overshoot through zero");
    }

    function test_Reserve_EmptyReserveDisablesBeliefWithoutReverting() public {
        hook.setBelief(vaneKey, int256(uint256(1 << 64)) / 100);

        vm.startPrank(address(hook));
        manager.transfer(address(1), currency0.toId(), hook.reserveOf(currency0));
        manager.transfer(address(1), currency1.toId(), hook.reserveOf(currency1));
        vm.stopPrank();
        assertEq(hook.reserveOf(currency0), 0, "reserve must be empty");

        uint256 before0 = currency0.balanceOfSelf();
        _swap(true, -1 ether);
        assertLt(currency0.balanceOfSelf(), before0, "swap must still execute");
    }

    function test_Reserve_PartialFundingScalesBelief() public {
        hook.setBelief(vaneKey, int256(uint256(1 << 64)) / 100);

        vm.startPrank(address(hook));
        manager.transfer(address(1), currency0.toId(), hook.reserveOf(currency0) - 10 ether);
        vm.stopPrank();
        assertEq(hook.reserveOf(currency0), 10 ether, "reserve must be the claim balance");
        assertEq(hook.targetFor(currency0), 100 ether, "target comes from config default");

        vm.expectEmit(true, false, false, true, address(hook));
        emit VaneHook.BeliefScaled(id, 10 ether, 100 ether);
        _swap(true, -1 ether);
    }

    function test_Reserve_TargetOverrideIsRespected() public {
        assertEq(hook.targetFor(currency0), 100 ether, "default applies when unset");
        hook.setReserveTarget(currency0, 5 ether);
        assertEq(hook.targetFor(currency0), 5 ether, "override must take effect");
    }

    function test_NoCrossPoolContamination_UnderRealFlow() public {
        PoolKey memory second = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        hook.allowPool(second);
        manager.initialize(second, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(second, ModifyLiquidityParams(-60000, 60000, 5000 ether, 0), "");

        hook.setKappa(vaneKey, uint64(uint256(1 << 64) / 1_000_000));

        for (uint256 i = 0; i < 8; i++) {
            vm.roll(block.number + 1);
            _swap(false, -2 ether);
        }

        assertGt(hook.beliefOf(id), 0, "traded pool must develop a belief");
        assertEq(hook.beliefOf(second.toId()), 0, "untraded pool must be untouched");
        assertEq(hook.poolState(second.toId()).varOneX32, 0, "untraded pool variance untouched");
    }

    function testFuzz_NeverRevertsAcrossBlocks(uint8 rawSwaps, uint128 rawAmount, bool startDirection) public {
        uint256 swaps = bound(uint256(rawSwaps), 1, 40);
        uint256 amount = bound(uint256(rawAmount), 1e6, 20 ether);

        for (uint256 i = 0; i < swaps; i++) {
            vm.roll(block.number + 1);
            bool dir = (i % 2 == 0) == startDirection;
            try swapRouter.swap(
                vaneKey,
                SwapParams({
                    zeroForOne: dir,
                    amountSpecified: -int256(amount),
                    sqrtPriceLimitX96: dir ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            ) {}
            catch {
                fail();
            }
        }
    }

    function test_Gas_NewBlockSamplingPath() public {
        for (uint256 i = 0; i < 4; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -1 ether);
        }
        vm.roll(block.number + 1);

        uint256 before = gasleft();
        _swap(true, -1 ether);
        uint256 used = before - gasleft();

        console2.log("full swap gas, new-block sampling path:", used);

        assertLt(used, 56_131 + 45_000, "new-block path must fit the gas budget");
    }

    function test_Gas_WorstCaseCheckpointWithActiveBelief() public {
        PoolKey memory plainKey = PoolKey(currency0, currency1, 3000, 60, IHooks(address(0)));
        manager.initialize(plainKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(plainKey, ModifyLiquidityParams(-60000, 60000, 5000 ether, 0), "");

        for (uint256 i = 0; i < HORIZON_K - 1; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
            _swapOn(plainKey, true, -5 ether);
        }

        hook.setBelief(vaneKey, int256(uint256(1 << 64)) / 100);
        vm.roll(block.number + 1);

        uint256 beforePlain = gasleft();
        _swapOn(plainKey, true, -1 ether);
        uint256 plainGas = beforePlain - gasleft();

        uint256 beforeVane = gasleft();
        _swap(true, -1 ether);
        uint256 vaneGas = beforeVane - gasleft();

        console2.log("plain pool, same history:", plainGas);
        console2.log("vane pool, checkpoint + active belief:", vaneGas);
        console2.log("marginal hook cost:", vaneGas - plainGas);

        assertLt(vaneGas - plainGas, 54_000, "worst case must stay within its recorded bound");
    }

    function test_Gas_AttributionAtIdenticalState() public {
        for (uint256 i = 0; i < HORIZON_K - 1; i++) {
            vm.roll(block.number + 1);
            _swap(true, -5 ether);
        }
        vm.roll(block.number + 1);

        uint256 snap = vm.snapshotState();

        uint256 b1 = gasleft();
        _swap(true, -1 ether);
        uint256 checkpointOnly = b1 - gasleft();

        vm.revertToState(snap);

        hook.setBelief(vaneKey, int256(uint256(1 << 64)) / 100);
        uint256 b2 = gasleft();
        _swap(true, -1 ether);
        uint256 checkpointPlusSettle = b2 - gasleft();

        console2.log("checkpoint only          :", checkpointOnly);
        console2.log("checkpoint + settlement  :", checkpointPlusSettle);
        console2.log("settlement attributable  :", checkpointPlusSettle - checkpointOnly);
    }

    function test_Gas_HorizonCheckpointPath() public {
        for (uint256 i = 0; i < HORIZON_K; i++) {
            vm.roll(block.number + 1);
            _swap(i % 2 == 0, -0.5 ether);
        }

        vm.roll(block.number + 1);
        uint256 before = gasleft();
        _swap(true, -1 ether);
        uint256 used = before - gasleft();

        console2.log("full swap gas, horizon checkpoint path:", used);
        assertLt(used, 56_131 + 45_000, "checkpoint path must fit the gas budget");
    }
}
