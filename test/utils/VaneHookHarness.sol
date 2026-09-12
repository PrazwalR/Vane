// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

import {VaneHook} from "../../src/VaneHook.sol";
import {VaneConfig} from "../../src/config/VaneConfig.sol";
import {PoolStateLib, PoolState, PoolStateAux} from "../../src/libraries/PoolStateLib.sol";
import {FlowCovState} from "../../src/libraries/FlowAutocovariance.sol";

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
        PoolStateAux memory a = PoolStateLib.unpackAux(_aux[id]);
        a.kappaX64 = kappaX64;
        _aux[id] = PoolStateLib.packAux(a);
    }

    function setFlowCov(PoolKey calldata key, int64 cov1, int64 cov2) external {
        FlowCovState storage st = _flowCov[key.toId()];
        st.cov1 = cov1;
        st.cov2 = cov2;
    }

    function flowCovOf(PoolKey calldata key) external view returns (FlowCovState memory) {
        return _flowCov[key.toId()];
    }

    function setFlowVar(PoolKey calldata key, uint64 flowVar) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.flowVarX32 = flowVar;
        _state[id] = PoolStateLib.packState(s);
    }

    function setVarOne(PoolKey calldata key, uint64 varOneX32) external {
        PoolId id = key.toId();
        PoolState memory s = PoolStateLib.unpackState(_state[id]);
        s.varOneX32 = varOneX32;
        _state[id] = PoolStateLib.packState(s);
    }
}
