// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-pool hot state. One storage slot.
/// @dev Bit budget, 248 of 256 used, 8 reserved:
///        24  lastTick        int24   current tick at the last block sample
///        32  lastBlock       uint32  block of the last sample
///        64  varOneX32       uint64  Var(r_1), squared ticks, Q32.32
///        64  flowVarX32      uint64  E[y^2], squared flow units, Q32.32
///        64  deltaX64        int64   belief offset, Q64.64
///         8  reserved                held for a future staleness flag
///
///      The reserved bits are for a staleness marker distinguishing "no sample yet"
///      from "sampled and genuinely zero". Until that is needed they stay zero and
///      the round-trip test asserts they are untouched.
struct PoolState {
    int24 lastTick;
    uint32 lastBlock;
    uint64 varOneX32;
    uint64 flowVarX32;
    int64 deltaX64;
}

/// @notice Per-pool control state. One storage slot.
/// @dev Bit budget, 248 of 256 used, 8 reserved:
///        24  checkpointTick   int24   tick at the last horizon checkpoint
///        32  checkpointBlock  uint32  block of the last horizon checkpoint
///        64  varKX32          uint64  Var(r_k), squared ticks, Q32.32
///        64  kappaX64         uint64  impact gain, Q64.64
///        64  flowAccum        int64   signed flow this block, flow units
///         8  reserved                 held for a controller saturation flag
struct PoolStateAux {
    int24 checkpointTick;
    uint32 checkpointBlock;
    uint64 varKX32;
    uint64 kappaX64;
    int64 flowAccum;
}

/// @title PoolStateLib
/// @notice Manual packing of the two hot-path slots.
/// @dev Packing is explicit rather than left to the compiler so the hot path is
///      exactly one SLOAD and one SSTORE per slot, and so the layout is pinned by a
///      round-trip fuzz test over the full field domain rather than by the compiler's
///      current ordering rules.
///
///      This layout departs from the draft specification in one field. The draft gave
///      the belief 32 bits as "deltaX64Hi". A belief of 0.01 in Q64.64 is 0.01 * 2^64
///      = 1.845e17, which needs 58 bits; an int32 tops out at 2.1e9 and would truncate
///      the belief to zero for every value the mechanism actually uses. The belief
///      therefore takes a full int64 here, funded by the 40 reserved bits the draft
///      left unassigned. The int64 is safe because |delta| <= delta_max << 0.5, and
///      0.5 in Q64.64 is exactly the int64 ceiling.
library PoolStateLib {
    uint256 private constant MASK_24 = 0xFFFFFF;
    uint256 private constant MASK_32 = 0xFFFFFFFF;
    uint256 private constant MASK_64 = 0xFFFFFFFFFFFFFFFF;

    uint256 private constant OFFSET_LAST_BLOCK = 24;
    uint256 private constant OFFSET_VAR_ONE = 56;
    uint256 private constant OFFSET_FLOW_VAR = 120;
    uint256 private constant OFFSET_DELTA = 184;

    uint256 private constant OFFSET_CHECKPOINT_BLOCK = 24;
    uint256 private constant OFFSET_VAR_K = 56;
    uint256 private constant OFFSET_KAPPA = 120;
    uint256 private constant OFFSET_FLOW_ACCUM = 184;

    function packState(PoolState memory s) internal pure returns (bytes32 packed) {
        packed = bytes32(
            (uint256(uint24(s.lastTick)) & MASK_24) | ((uint256(s.lastBlock) & MASK_32) << OFFSET_LAST_BLOCK)
                | ((uint256(s.varOneX32) & MASK_64) << OFFSET_VAR_ONE)
                | ((uint256(s.flowVarX32) & MASK_64) << OFFSET_FLOW_VAR)
                | ((uint256(uint64(s.deltaX64)) & MASK_64) << OFFSET_DELTA)
        );
    }

    function unpackState(bytes32 packed) internal pure returns (PoolState memory s) {
        uint256 raw = uint256(packed);
        s.lastTick = int24(uint24(raw & MASK_24));
        s.lastBlock = uint32((raw >> OFFSET_LAST_BLOCK) & MASK_32);
        s.varOneX32 = uint64((raw >> OFFSET_VAR_ONE) & MASK_64);
        s.flowVarX32 = uint64((raw >> OFFSET_FLOW_VAR) & MASK_64);
        s.deltaX64 = int64(uint64((raw >> OFFSET_DELTA) & MASK_64));
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
