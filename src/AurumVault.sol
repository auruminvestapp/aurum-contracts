// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAurumStrategy} from "./interfaces/IAurumStrategy.sol";

/// @title AurumVault — price-blind proportional shares over a CL position.
/// @notice Shares are a plain ERC-20 (+permit) claim on a fraction of the
///         strategy's liquidity. No oracle ever enters the share math:
///         deposits are strictly proportional (excess is never pulled),
///         withdrawals are always in-kind. Vault and strategy are fixed for
///         life: there is no upgrade path and no strategy swap, so no role can
///         redirect the position. A better strategy means a new vault that
///         depositors choose to move to.
contract AurumVault is ERC20PermitUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct DepositQuote {
        uint256 position0;
        uint256 position1;
        uint128 liquidity;
    }

    enum VaultState {
        Active,
        Paused,
        Panicked
    }

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public owner;
    address public pendingOwner; // proposed by the owner, takes over on acceptOwnership()
    address public guardian; // emergency-only powers
    address public keeper; // the agent — emergency powers here, rails live in the strategy

    IAurumStrategy public strategy;
    IERC20 public token0;
    IERC20 public token1;
    VaultState public state;

    event Deposit(address indexed user, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed user, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1, bool inKind);
    event StateChanged(VaultState state);
    event OwnerSet(address owner);
    event OwnerProposed(address pendingOwner);
    event GuardianSet(address guardian);
    event KeeperSet(address keeper);

    error NotOwner();
    error NotEmergencyAuthority();
    error NotFactory();
    error NotActive();
    error NotCalm();
    error WrongState();
    error ZeroAmount();
    error ZeroAddress();
    error SlippageShares();
    error SlippageAmounts();
    error NoActiveLiquidity();
    error DepositExceedsMax();
    error InexactTransfer();
    error IdlePrincipalSpent();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev pause/panic are risk-reducing: owner, guardian and the agent may all trigger them.
    modifier onlyEmergencyAuthority() {
        if (msg.sender != owner && msg.sender != guardian && msg.sender != keeper) revert NotEmergencyAuthority();
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address strategy_,
        address owner_,
        address guardian_,
        address keeper_,
        string calldata name_,
        string calldata symbol_
    ) external initializer {
        if (strategy_ == address(0) || owner_ == address(0) || guardian_ == address(0) || keeper_ == address(0)) {
            revert ZeroAddress();
        }
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);

        factory = msg.sender;
        strategy = IAurumStrategy(strategy_);
        token0 = IERC20(IAurumStrategy(strategy_).token0());
        token1 = IERC20(IAurumStrategy(strategy_).token1());
        owner = owner_;
        guardian = guardian_;
        keeper = keeper_;
        state = VaultState.Active;
    }

    // ---------------------------------------------------------------- views

    function isActive() external view returns (bool) {
        return state == VaultState.Active;
    }

    /// @notice Liquidity units one full share represents, scaled by 1e18.
    ///         Monotonically increasing through compounding; display-only.
    function pricePerFullShare() external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        return Math.mulDiv(strategy.totalLiquidity(), 1e18, supply);
    }

    /// @notice Estimate the TOTAL two-token debit, including the depositor's
    ///         proportional contribution to tokens already idle in the strategy.
    /// @dev A deposit harvests first, so the execution quote can differ if that
    ///      harvest changes liquidity or idle balances. The maxima remain hard
    ///      bounds on the actual debit.
    function previewDeposit(uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint256 amount0, uint256 amount1, uint128 liquidity, uint256 shares)
    {
        uint256 supply = totalSupply();
        uint128 beforeLiquidity = strategy.totalLiquidity();
        if (supply > 0 && beforeLiquidity == 0) revert NoActiveLiquidity();
        uint256 idle0 = token0.balanceOf(address(strategy));
        uint256 idle1 = token1.balanceOf(address(strategy));
        DepositQuote memory q = _quoteDeposit(amount0Max, amount1Max, beforeLiquidity, idle0, idle1);
        liquidity = q.liquidity;
        if (liquidity == 0) return (0, 0, 0, 0);
        amount0 = q.position0 + _idleContribution(idle0, liquidity, beforeLiquidity);
        amount1 = q.position1 + _idleContribution(idle1, liquidity, beforeLiquidity);
        shares = supply == 0 ? liquidity : Math.mulDiv(supply, liquidity, beforeLiquidity);
    }

    // ------------------------------------------------------------- user flow

    /// @notice Proportional two-token deposit. The stated maxima include the
    ///         position contribution and a matching share of existing idle
    ///         principal. Excess is never pulled.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (state != VaultState.Active) revert NotActive();
        if (receiver == address(0)) revert ZeroAddress();
        // Deposits only in calm periods: the required token ratio is derived
        // from the current price, so a flash-skewed pool must not set it.
        if (!strategy.isCalm()) revert NotCalm();

        // Compound pending yield first so entry PPS is honest (harvestOnDeposit);
        // the depositor earns the caller fee for the gas they spend.
        strategy.harvest(msg.sender);

        uint128 liquidityBefore = strategy.totalLiquidity();
        uint256 supply = totalSupply();
        if (supply > 0 && liquidityBefore == 0) revert NoActiveLiquidity();
        uint256 idle0 = token0.balanceOf(address(strategy));
        uint256 idle1 = token1.balanceOf(address(strategy));
        DepositQuote memory q = _quoteDeposit(amount0Max, amount1Max, liquidityBefore, idle0, idle1);
        if (q.liquidity == 0) revert ZeroAmount();

        _pullExact(token0, q.position0);
        _pullExact(token1, q.position1);
        uint128 liquidityAdded = strategy.invest(q.position0, q.position1);
        if (liquidityAdded == 0) revert ZeroAmount();

        // The strategy may not fund this depositor's liquidity with principal
        // already owned by existing holders (notably V4's former all-balance
        // invest path). Any unused position contribution remains idle.
        if (token0.balanceOf(address(strategy)) < idle0 || token1.balanceOf(address(strategy)) < idle1) {
            revert IdlePrincipalSpent();
        }

        uint256 extra0 = _idleContribution(idle0, liquidityAdded, liquidityBefore);
        uint256 extra1 = _idleContribution(idle1, liquidityAdded, liquidityBefore);
        uint256 paid0 = q.position0 + extra0;
        uint256 paid1 = q.position1 + extra1;
        if (paid0 > amount0Max || paid1 > amount1Max) revert DepositExceedsMax();

        shares = supply == 0 ? liquidityAdded : Math.mulDiv(supply, liquidityAdded, liquidityBefore);
        if (shares == 0 || shares < minShares) revert SlippageShares();

        _pullExact(token0, extra0);
        _pullExact(token1, extra1);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, shares, paid0, paid1);
    }

    function _quoteDeposit(uint256 max0, uint256 max1, uint128 beforeLiquidity, uint256 idle0, uint256 idle1)
        internal
        view
        returns (DepositQuote memory q)
    {
        uint256 budget0 = max0;
        uint256 budget1 = max1;
        for (uint256 attempt = 0; attempt < 5; ++attempt) {
            (q.position0, q.position1, q.liquidity) = strategy.quoteDeposit(budget0, budget1);
            if (q.liquidity == 0 || (idle0 == 0 && idle1 == 0)) return q;

            uint256 gross0 = q.position0 + _idleContribution(idle0, q.liquidity, beforeLiquidity);
            uint256 gross1 = q.position1 + _idleContribution(idle1, q.liquidity, beforeLiquidity);
            if (gross0 <= max0 && gross1 <= max1) return q;

            // Scale the position budgets by each exceeded total-token limit.
            // Full-precision mulDiv preserves very small ratios when a tiny
            // position coexists with a very large idle balance.
            uint256 next0 = budget0;
            uint256 next1 = budget1;
            if (gross0 > max0) {
                next0 = Math.mulDiv(next0, max0, gross0);
                next1 = Math.mulDiv(next1, max0, gross0);
            }
            if (gross1 > max1) {
                uint256 cut0 = Math.mulDiv(budget0, max1, gross1);
                uint256 cut1 = Math.mulDiv(budget1, max1, gross1);
                if (cut0 < next0) next0 = cut0;
                if (cut1 < next1) next1 = cut1;
            }
            // One-wei pool rounding can leave a budget unchanged. Force
            // progress; an unaffordable dust-sized request returns zero.
            if (next0 == budget0 && next1 == budget1) {
                if (next0 > 0) --next0;
                if (next1 > 0) --next1;
            }
            budget0 = next0;
            budget1 = next1;
        }
        revert DepositExceedsMax();
    }

    function _idleContribution(uint256 idle, uint128 added, uint128 beforeLiquidity)
        internal
        pure
        returns (uint256)
    {
        if (idle == 0 || added == 0) return 0;
        if (beforeLiquidity == 0) revert NoActiveLiquidity();
        return Math.mulDiv(idle, added, beforeLiquidity, Math.Rounding.Ceil);
    }

    function _pullExact(IERC20 token, uint256 amount) internal {
        if (amount == 0) return;
        address to = address(strategy);
        uint256 beforeBalance = token.balanceOf(to);
        uint256 beforeSender = token.balanceOf(msg.sender);
        token.safeTransferFrom(msg.sender, to, amount);
        if (token.balanceOf(to) != beforeBalance + amount || beforeSender - token.balanceOf(msg.sender) != amount) {
            revert InexactTransfer();
        }
    }

    /// @notice In-kind pro-rata withdrawal. Callable in EVERY vault state —
    ///         pause and panic never block exits. No swap, no oracle.
    /// @dev Both tokens are paid in one call, so a token that refuses the
    ///      transfer (issuer pause, denylist, freeze) blocks the whole
    ///      withdrawal — including the other token — until it transfers again.
    function withdraw(uint256 shares, uint256 min0, uint256 min1, address receiver)
        external
        nonReentrant
        returns (uint256 out0, uint256 out1)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        uint256 supply = totalSupply();
        _burn(msg.sender, shares); // CEI: burn before external interaction

        (out0, out1) = strategy.divest(shares, supply, receiver);
        if (out0 < min0 || out1 < min1) revert SlippageAmounts();

        emit Withdraw(msg.sender, receiver, shares, out0, out1, true);
    }

    // ------------------------------------------------------------- emergency

    function pause() external onlyEmergencyAuthority {
        if (state != VaultState.Active) revert WrongState();
        state = VaultState.Paused;
        emit StateChanged(state);
    }

    function unpause() external onlyOwner {
        if (state != VaultState.Paused) revert WrongState();
        state = VaultState.Active;
        emit StateChanged(state);
    }

    /// @notice Evacuate the pool position. Zero swaps, zero oracle reads —
    ///         works mid-manipulation. Withdrawals stay open throughout.
    function panic() external onlyEmergencyAuthority {
        if (state == VaultState.Panicked) revert WrongState();
        state = VaultState.Panicked;
        strategy.emergencyExit();
        emit StateChanged(state);
    }

    function unpanic() external onlyOwner {
        if (state != VaultState.Panicked) revert WrongState();
        state = VaultState.Active;
        strategy.reinvestIdle();
        emit StateChanged(state);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Propose a new owner; nothing changes until it accepts. The
    ///         owner alone can unpause, unpanic and rotate roles, so a
    ///         mistyped address must never be able to take that over. Proposing
    ///         zero withdraws a pending proposal.
    function transferOwnership(address owner_) external onlyOwner {
        pendingOwner = owner_;
        emit OwnerProposed(owner_);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnerSet(msg.sender);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice Factory-only: invest the seed amounts (already transferred to the
    ///         strategy) and mint the resulting shares to the dead address, so
    ///         no first depositor ever holds a manipulable full supply.
    function seedDeposit(uint256 amount0, uint256 amount1) external returns (uint128 seedLiquidity) {
        if (msg.sender != factory) revert NotFactory();
        if (totalSupply() != 0) revert WrongState();
        seedLiquidity = strategy.invest(amount0, amount1);
        if (seedLiquidity == 0) revert ZeroAmount();
        _mint(DEAD, seedLiquidity);
    }
}
