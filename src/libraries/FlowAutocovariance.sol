// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Q64x64} from "./Q64x64.sol";

struct FlowCovState {
    int64 prevFlow1;
    int64 prevFlow2;
    int64 cov1;
    int64 cov2;
}

library FlowAutocovariance {
    uint256 internal constant ONE_X32 = 1 << 32;

    function update(FlowCovState memory st, int64 blockFlow, uint64 lambdaX32)
        internal
        pure
        returns (FlowCovState memory)
    {
        int256 sample1 = int256(blockFlow) * int256(st.prevFlow1);
        int256 sample2 = int256(blockFlow) * int256(st.prevFlow2);

        st.cov1 = _saturate(Q64x64.ewmaSigned(int256(st.cov1), sample1, lambdaX32));
        st.cov2 = _saturate(Q64x64.ewmaSigned(int256(st.cov2), sample2, lambdaX32));

        st.prevFlow2 = st.prevFlow1;
        st.prevFlow1 = blockFlow;

        return st;
    }

    function minCovRatioX32(uint256 lambdaX32, uint256 zScore) internal pure returns (uint256) {
        if (lambdaX32 >= ONE_X32) return type(uint256).max;
        uint256 ratioX32 = ((ONE_X32 - lambdaX32) << 32) / (ONE_X32 + lambdaX32);
        return zScore * Q64x64.sqrtX32(ratioX32);
    }

    function rhoX32(FlowCovState memory st) internal pure returns (uint256) {
        if (st.cov1 <= 0 || st.cov2 <= 0) return 0;
        return (uint256(uint64(st.cov2)) << 32) / uint256(uint64(st.cov1));
    }

    function isIdentified(FlowCovState memory st, uint64 flowVar, uint256 minRatioX32) internal pure returns (bool) {
        if (st.cov1 <= 0 || st.cov2 <= 0 || flowVar == 0) return false;

        if (uint64(st.cov2) > uint64(st.cov1)) return false;

        uint256 ratioX32 = (uint256(uint64(st.cov1)) << 32) / uint256(flowVar);
        return ratioX32 >= minRatioX32;
    }

    function noiseScale(FlowCovState memory st, uint64 flowVar, uint256 minRatioX32) internal pure returns (uint256) {
        if (!isIdentified(st, flowVar, minRatioX32)) return 0;

        uint256 c1 = uint256(uint64(st.cov1));
        uint256 c2 = uint256(uint64(st.cov2));
        uint256 varInformed = (c1 * c1) / c2;

        if (varInformed >= uint256(flowVar)) return 0;
        return Q64x64.sqrt((uint256(flowVar) - varInformed) / 1);
    }

    function divergenceX32(uint256 noiseA, uint256 noiseB) internal pure returns (uint256) {
        if (noiseB == 0) return 0;
        uint256 diff = noiseA > noiseB ? noiseA - noiseB : noiseB - noiseA;
        return (diff << 32) / noiseB;
    }

    function _saturate(int256 v) private pure returns (int64) {
        if (v > type(int64).max) return type(int64).max;
        if (v < type(int64).min) return type(int64).min;
        return int64(v);
    }
}
