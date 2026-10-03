// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct PoolState {
    int24 lastTick;
    uint32 lastBlock;
    uint64 varOneX32;
    /// EWMA of squared net per-block flow, in flow units squared. Deliberately NOT an
    /// X32 quantity: unlike varOneX32 and varKX32, the sample is not shifted before the
    /// EWMA, so this carries no fixed-point scale. It was named flowVarX32 for a while,
    /// which made the only unit convention in the codebase lie about its own value.
    uint64 flowVarUnitsSq;
    int64 deltaX64;
    bool saturated;
}

struct PoolStateAux {
    int24 checkpointTick;
    uint32 checkpointBlock;
    uint64 varKX32;
    uint64 kappaX64;
    int64 flowAccum;
}

library PoolStateLib {
    uint256 private constant MASK_24 = 0xFFFFFF;
    uint256 private constant MASK_32 = 0xFFFFFFFF;
    uint256 private constant MASK_64 = 0xFFFFFFFFFFFFFFFF;

    uint256 private constant OFFSET_LAST_BLOCK = 24;
    uint256 private constant OFFSET_VAR_ONE = 56;
    uint256 private constant OFFSET_FLOW_VAR = 120;
    uint256 private constant OFFSET_DELTA = 184;
    uint256 private constant OFFSET_SATURATED = 248;

    uint256 private constant OFFSET_CHECKPOINT_BLOCK = 24;
    uint256 private constant OFFSET_VAR_K = 56;
    uint256 private constant OFFSET_KAPPA = 120;
    uint256 private constant OFFSET_FLOW_ACCUM = 184;

    function packState(PoolState memory s) internal pure returns (bytes32 packed) {
        packed = bytes32(
            (uint256(uint24(s.lastTick)) & MASK_24) | ((uint256(s.lastBlock) & MASK_32) << OFFSET_LAST_BLOCK)
                | ((uint256(s.varOneX32) & MASK_64) << OFFSET_VAR_ONE)
                | ((uint256(s.flowVarUnitsSq) & MASK_64) << OFFSET_FLOW_VAR)
                | ((uint256(uint64(s.deltaX64)) & MASK_64) << OFFSET_DELTA)
                | ((s.saturated ? uint256(1) : uint256(0)) << OFFSET_SATURATED)
        );
    }

    function unpackState(bytes32 packed) internal pure returns (PoolState memory s) {
        uint256 raw = uint256(packed);
        s.lastTick = int24(uint24(raw & MASK_24));
        s.lastBlock = uint32((raw >> OFFSET_LAST_BLOCK) & MASK_32);
        s.varOneX32 = uint64((raw >> OFFSET_VAR_ONE) & MASK_64);
        s.flowVarUnitsSq = uint64((raw >> OFFSET_FLOW_VAR) & MASK_64);
        s.deltaX64 = int64(uint64((raw >> OFFSET_DELTA) & MASK_64));
        s.saturated = ((raw >> OFFSET_SATURATED) & 1) == 1;
    }

    function packAux(PoolStateAux memory a) internal pure returns (bytes32 packed) {
        packed = bytes32(
            (uint256(uint24(a.checkpointTick)) & MASK_24)
                | ((uint256(a.checkpointBlock) & MASK_32) << OFFSET_CHECKPOINT_BLOCK)
                | ((uint256(a.varKX32) & MASK_64) << OFFSET_VAR_K) | ((uint256(a.kappaX64) & MASK_64) << OFFSET_KAPPA)
                | ((uint256(uint64(a.flowAccum)) & MASK_64) << OFFSET_FLOW_ACCUM)
        );
    }

    function unpackAux(bytes32 packed) internal pure returns (PoolStateAux memory a) {
        uint256 raw = uint256(packed);
        a.checkpointTick = int24(uint24(raw & MASK_24));
        a.checkpointBlock = uint32((raw >> OFFSET_CHECKPOINT_BLOCK) & MASK_32);
        a.varKX32 = uint64((raw >> OFFSET_VAR_K) & MASK_64);
        a.kappaX64 = uint64((raw >> OFFSET_KAPPA) & MASK_64);
        a.flowAccum = int64(uint64((raw >> OFFSET_FLOW_ACCUM) & MASK_64));
    }
}
