// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {VaneHookHarness} from "./utils/VaneHookHarness.sol";
import {Fixtures} from "./utils/Fixtures.sol";

/// A token that takes a cut on every transfer.
contract FeeOnTransferToken is MockERC20 {
    uint256 public constant FEE_BPS = 100;

    constructor() MockERC20("Fee On Transfer", "FOT", 18) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = (amount * FEE_BPS) / 10_000;
        super.transferFrom(from, address(0xFEE), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

/// Documents which token behaviours the hook supports, by testing them rather than by
/// asserting it in a comment. A protocol that has not decided its token assumptions has
/// decided to accept whatever breaks first.
contract TokenAssumptionsTest is Test, Deployers {
    VaneHookHarness internal hook;
    FeeOnTransferToken internal fot;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        address hookAddr = address(flags ^ (0xDDDD << 144));
        deployCodeTo(
            "VaneHookHarness.sol:VaneHookHarness", abi.encode(manager, Fixtures.config(), address(this)), hookAddr
        );
        hook = VaneHookHarness(hookAddr);

        fot = new FeeOnTransferToken();
        fot.mint(address(this), 1_000_000 ether);
        fot.approve(address(hook), type(uint256).max);
    }

    /// A fee-on-transfer token must not be able to credit the hook with reserve it never
    /// received. The settle/take pair is exact, so the shortfall leaves a non-zero delta
    /// and the unlock reverts. Funding is refused rather than silently under-collateralised.
    function test_FeeOnTransfer_FundingRevertsRatherThanUnderCollateralising() public {
        uint256 before = hook.reserveOf(Currency.wrap(address(fot)));

        vm.expectRevert();
        hook.fundReserve(Currency.wrap(address(fot)), 1000 ether);

        assertEq(hook.reserveOf(Currency.wrap(address(fot))), before, "a failed funding must not move the reserve");
    }

    /// A standard 18-decimal token funds exactly, with no shortfall and no excess.
    function test_StandardToken_FundsExactly() public {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        uint256 before = hook.reserveOf(currency0);

        hook.fundReserve(currency0, 100 ether);

        assertEq(hook.reserveOf(currency0) - before, 100 ether, "a standard token must credit the full amount");
    }

    /// Reserves are ERC-6909 claims held inside the PoolManager, so a token that rebases
    /// its ERC20 balances cannot silently change what the hook is owed. The claim balance
    /// is the accounting, and it only moves when the hook mints or burns.
    function test_ReserveIsClaimBalanceNotTokenBalance() public {
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        hook.fundReserve(currency0, 100 ether);
        uint256 claims = hook.reserveOf(currency0);

        // Move ERC20 balances around underneath; the claim balance must not follow.
        MockERC20(Currency.unwrap(currency0)).mint(address(hook), 500 ether);

        assertEq(hook.reserveOf(currency0), claims, "reserve must track claims, not ERC20 balance");
    }
}
