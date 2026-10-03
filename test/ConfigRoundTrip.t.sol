// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {VaneHook} from "../src/VaneHook.sol";
import {VaneConfig} from "../src/config/VaneConfig.sol";
import {VaneParameters} from "../script/VaneParameters.sol";
import {PoolState, PoolStateAux, PoolStateLib} from "../src/libraries/PoolStateLib.sol";

/// The config is written out three times — the struct, the immutables the constructor
/// unpacks it into, and the struct `config()` rebuilds for callers. Adding a parameter
/// means editing all three, and nothing previously compared the rebuilt struct against
/// what was deployed, so a missed field would have returned a stale view indefinitely.
contract ConfigRoundTripTest is Test, Deployers {
    VaneHook internal hook;

    function setUp() public {
        deployFreshManagerAndRouters();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xC0FF << 144));
        deployCodeTo("VaneHook.sol:VaneHook", abi.encode(manager, VaneParameters.config(), address(this)), hookAddr);
        hook = VaneHook(payable(hookAddr));
    }

    function test_ConfigRoundTripsEveryField() public view {
        VaneConfig memory want = VaneParameters.config();
        VaneConfig memory got = hook.config();

        assertEq(got.thetaX64, want.thetaX64, "thetaX64");
        assertEq(got.varLambdaX32, want.varLambdaX32, "varLambdaX32");
        assertEq(got.flowLambdaX32, want.flowLambdaX32, "flowLambdaX32");
        assertEq(got.horizonK, want.horizonK, "horizonK");
        assertEq(got.controllerGainX32, want.controllerGainX32, "controllerGainX32");
        assertEq(got.controllerLeakX32, want.controllerLeakX32, "controllerLeakX32");
        assertEq(got.controllerDeadbandX32, want.controllerDeadbandX32, "controllerDeadbandX32");
        assertEq(got.kappaMaxX64, want.kappaMaxX64, "kappaMaxX64");
        assertEq(got.deltaMaxX64, want.deltaMaxX64, "deltaMaxX64");
        assertEq(got.deltaDustX64, want.deltaDustX64, "deltaDustX64");
        assertEq(got.maxTickDelta, want.maxTickDelta, "maxTickDelta");
        assertEq(got.flowUnit, want.flowUnit, "flowUnit");
        assertEq(got.reserveTargetDefault, want.reserveTargetDefault, "reserveTargetDefault");
        assertEq(got.maxEstimatorDivergenceX32, want.maxEstimatorDivergenceX32, "maxEstimatorDivergenceX32");
        assertEq(got.routeBZScore, want.routeBZScore, "routeBZScore");
        assertEq(got.unidentifiedPenaltyX32, want.unidentifiedPenaltyX32, "unidentifiedPenaltyX32");
    }

    /// Guards against a field being added to the struct without being wired through. The
    /// ABI encoding of the returned struct is one word per field, so its length is a
    /// direct count — if this fails, a field was added and the assertions above were not
    /// extended to cover it.
    function test_ConfigHasExactlyTheFieldsCoveredAbove() public view {
        assertEq(abi.encode(hook.config()).length, 16 * 32, "config field count changed; extend the round-trip test");
    }

    /// The packed state words are built from an offset table that has no compile-time link
    /// to the field widths. Round-tripping every field at its maximum catches an
    /// overlapping offset, which the masks would otherwise hide by truncating quietly.
    function test_PackingSurvivesEveryFieldAtItsMaximum() public pure {
        PoolState memory s = PoolState({
            lastTick: type(int24).max,
            lastBlock: type(uint32).max,
            varOneX32: type(uint64).max,
            flowVarUnitsSq: type(uint64).max,
            deltaX64: type(int64).max,
            saturated: true
        });
        PoolState memory sBack = PoolStateLib.unpackState(PoolStateLib.packState(s));
        assertEq(sBack.lastTick, s.lastTick, "lastTick");
        assertEq(sBack.lastBlock, s.lastBlock, "lastBlock");
        assertEq(sBack.varOneX32, s.varOneX32, "varOneX32");
        assertEq(sBack.flowVarUnitsSq, s.flowVarUnitsSq, "flowVarUnitsSq");
        assertEq(sBack.deltaX64, s.deltaX64, "deltaX64");
        assertEq(sBack.saturated, s.saturated, "saturated");

        PoolStateAux memory a = PoolStateAux({
            checkpointTick: type(int24).min,
            checkpointBlock: type(uint32).max,
            varKX32: type(uint64).max,
            kappaX64: type(uint64).max,
            flowAccum: type(int64).min
        });
        PoolStateAux memory aBack = PoolStateLib.unpackAux(PoolStateLib.packAux(a));
        assertEq(aBack.checkpointTick, a.checkpointTick, "checkpointTick");
        assertEq(aBack.checkpointBlock, a.checkpointBlock, "checkpointBlock");
        assertEq(aBack.varKX32, a.varKX32, "varKX32");
        assertEq(aBack.kappaX64, a.kappaX64, "kappaX64");
        assertEq(aBack.flowAccum, a.flowAccum, "flowAccum");
    }
}
