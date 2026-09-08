// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {VaneHook} from "../../src/VaneHook.sol";
import {VaneConfig} from "../../src/config/VaneConfig.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "../../src/libraries/PoolStateLib.sol";

/// @notice Test-only access to the hook's packed state.
/// @dev VaneHook exposes no way to write a belief from outside, because an externally
///      settable belief would be an operator-controlled price and would reintroduce the
///      trust assumption the mechanism exists to remove. Tests that need to pin a belief
///      to isolate one behaviour use this harness instead, which lives under test/ and
///      is unreachable from src/.
contract VaneHookHarness is VaneHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager manager, VaneConfig memory config) VaneHook(manager, config) {}

    function setBelief(PoolKey calldata key, int256 newDeltaX64) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.deltaX64 = int64(newDeltaX64);
        _state[id] = PoolStateLib.packState(s);
    }

    function setKappa(PoolKey calldata key, uint64 kappaX64) external {
        PoolId id = key.toId();
        PoolStateAux memory a = PoolStateLib.unpackAux(_aux[id]);
        a.kappaX64 = kappaX64;
        _aux[id] = PoolStateLib.packAux(a);
    }

    function setVarOne(PoolKey calldata key, uint64 varOneX32) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.varOneX32 = varOneX32;
        _state[id] = PoolStateLib.packState(s);
    }
}
