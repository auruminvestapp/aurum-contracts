// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AurumVault} from "./AurumVault.sol";
import {AurumStrategyUniV3} from "./AurumStrategyUniV3.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

/// @title AurumFactory — one-transaction vault deployment + on-chain registry.
/// @notice Clones a vault/strategy pair (EIP-1167), executes the creator's seed
///         deposit and burns the seed shares to the dead address, then records
///         the vault. The registry doubles as the allowlist future risk-tier
///         metavaults read.
contract AurumFactory is Ownable2Step {
    using SafeERC20 for IERC20;

    address public immutable vaultImplementation;
    address public immutable strategyImplementation;
    address public immutable feeConfig;

    address public vaultOwner; // becomes owner of every vault
    address public guardian;
    address public keeper; // the agent
    address public creator; // the only address allowed to create vaults

    address[] public allVaults;
    mapping(address vault => bool) public isAurumVault;
    mapping(address pool => address vault) public vaultForPool;

    event VaultCreated(address indexed pool, address indexed vault, address indexed strategy, uint128 seedLiquidity);
    event RolesSet(address vaultOwner, address guardian, address keeper, address creator);

    uint128 public constant MIN_SEED_LIQUIDITY = 1e9; // dust seed would let PPS-inflation grief small deposits

    error RenounceDisabled();
    error NotCreator();
    error ZeroAddress();
    error PoolAlreadyHasVault();
    error SeedFailed();
    error SeedTooSmall();

    constructor(
        address vaultImplementation_,
        address strategyImplementation_,
        address feeConfig_,
        address owner_,
        address guardian_,
        address keeper_
    ) Ownable(owner_) {
        if (
            vaultImplementation_ == address(0) || strategyImplementation_ == address(0) || feeConfig_ == address(0)
                || guardian_ == address(0) || keeper_ == address(0)
        ) revert ZeroAddress();
        vaultImplementation = vaultImplementation_;
        strategyImplementation = strategyImplementation_;
        feeConfig = feeConfig_;
        vaultOwner = owner_;
        guardian = guardian_;
        keeper = keeper_;
        creator = owner_;
        emit RolesSet(owner_, guardian_, keeper_, owner_);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }

    function setRoles(address vaultOwner_, address guardian_, address keeper_, address creator_) external onlyOwner {
        if (vaultOwner_ == address(0) || guardian_ == address(0) || keeper_ == address(0) || creator_ == address(0)) {
            revert ZeroAddress();
        }
        vaultOwner = vaultOwner_;
        guardian = guardian_;
        keeper = keeper_;
        creator = creator_;
        emit RolesSet(vaultOwner_, guardian_, keeper_, creator_);
    }

    /// @notice Deploy a vault/strategy pair on `pool` with an initial range and
    ///         a seed deposit (pulled from the caller, shares burned to DEAD).
    function createVault(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 seed0Max,
        uint256 seed1Max,
        AurumStrategyUniV3.Rails calldata rails,
        string calldata name,
        string calldata symbol
    ) external returns (address vault, address strategy) {
        if (msg.sender != creator) revert NotCreator();
        if (vaultForPool[pool] != address(0)) revert PoolAlreadyHasVault();

        strategy = Clones.clone(strategyImplementation);
        vault = Clones.clone(vaultImplementation);

        AurumStrategyUniV3(strategy).initialize(pool, vault, tickLower, tickUpper, feeConfig, rails);
        AurumVault(vault).initialize(strategy, vaultOwner, guardian, keeper, name, symbol);

        // Make sure the pool can serve the TWAP the calm-period check needs.
        IUniswapV3Pool(pool).increaseObservationCardinalityNext(100);

        // Seed: pull exactly what the range ratio needs, mint, burn to DEAD.
        (uint256 used0, uint256 used1, uint128 quoted) =
            AurumStrategyUniV3(strategy).quoteDeposit(seed0Max, seed1Max);
        if (quoted == 0) revert SeedFailed();
        if (used0 > 0) IERC20(IUniswapV3Pool(pool).token0()).safeTransferFrom(msg.sender, strategy, used0);
        if (used1 > 0) IERC20(IUniswapV3Pool(pool).token1()).safeTransferFrom(msg.sender, strategy, used1);
        uint128 seedLiquidity = AurumVault(vault).seedDeposit(used0, used1);
        if (seedLiquidity < MIN_SEED_LIQUIDITY) revert SeedTooSmall();

        allVaults.push(vault);
        isAurumVault[vault] = true;
        vaultForPool[pool] = vault;
        emit VaultCreated(pool, vault, strategy, seedLiquidity);
    }

    /// @notice Disabled: an ownerless contract would freeze vault creation and the roles handed to new vaults.
    ///         Hand over with transferOwnership + acceptOwnership instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
