// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {VaneHook} from "../../src/VaneHook.sol";
import {VaneConfig} from "../../src/config/VaneConfig.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "../../src/libraries/PoolStateLib.sol";

contract VaneHookHarness is VaneHook {
    using PoolIdLibrary for PoolKey;

    constructor(IPoolManager manager, VaneConfig memory config, address owner) VaneHook(manager, config, owner) {}

    function setBelief(PoolKey calldata key, int256 newDeltaX64) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.deltaX64 = int64(newDeltaX64);
        _state[id] = PoolStateLib.packState(s);
    }

    function setKappa(PoolKey calldata key, uint64 kappaX64) external {
        PoolId id = key.toId();
        uint32 lastBlock = PoolStateLib.lastBlockOf(_state[id]);
        PoolStateAux memory a = PoolStateLib.unpackAux(_aux[id], lastBlock);
        a.kappaX64 = kappaX64;
        _aux[id] = PoolStateLib.packAux(a, lastBlock);
    }

    function setFlowVar(PoolKey calldata key, uint64 flowVar) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.flowVarUnitsSq = flowVar;
        _state[id] = PoolStateLib.packState(s);
    }

    function setVarOne(PoolKey calldata key, uint64 varOneX32) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.varOneX32 = varOneX32;
        _state[id] = PoolStateLib.packState(s);
    }
}
