// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AurumVault} from "./AurumVault.sol";
import {AurumStrategySlipstream} from "./AurumStrategySlipstream.sol";
import {RewardRoute} from "./libraries/SlipstreamRewardRoutes.sol";
import {ICLPool} from "./interfaces/ISlipstream.sol";

/// @title AurumFactorySlipstream — one-transaction up33 vault deployment +
///        registry. The V3 factory pattern, keyed by pool address; the up33
///        periphery (NFPM, SwapRouter, v2 pool factory) is fixed at
///        construction and the per-vault reward-sale routes are passed at
///        creation (see RewardRoute).
contract AurumFactorySlipstream is Ownable2Step {
    using SafeERC20 for IERC20;

    address public immutable vaultImplementation;
    address public immutable strategyImplementation;
    address public immutable feeConfig;
    address public immutable nfpm;
    address public immutable swapRouter;
    address public immutable v2Factory; // up33's v2 pool factory, for v2 reward-route hops

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
    error BadPool();
    error SeedFailed();
    error SeedTooSmall();

    constructor(
        address vaultImplementation_,
        address strategyImplementation_,
        address feeConfig_,
        address nfpm_,
        address swapRouter_,
        address v2Factory_,
        address owner_,
        address guardian_,
        address keeper_
    ) Ownable(owner_) {
        if (
            vaultImplementation_ == address(0) || strategyImplementation_ == address(0) || feeConfig_ == address(0)
                || nfpm_ == address(0) || swapRouter_ == address(0) || v2Factory_ == address(0) || guardian_ == address(0)
                || keeper_ == address(0)
        ) revert ZeroAddress();
        vaultImplementation = vaultImplementation_;
        strategyImplementation = strategyImplementation_;
        feeConfig = feeConfig_;
        nfpm = nfpm_;
        swapRouter = swapRouter_;
        v2Factory = v2Factory_;
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
    /// @param rewardRoutes Reward-sale routes in priority order (first choice
    ///        first, then fallbacks). Required when the pool's gauge pays a
    ///        token the position doesn't hold; empty otherwise.
    function createVault(
        address pool,
        RewardRoute[] calldata rewardRoutes,
        int24 tickLower,
        int24 tickUpper,
        uint256 seed0Max,
        uint256 seed1Max,
        AurumStrategySlipstream.RailsSS calldata rails,
        string calldata name,
        string calldata symbol
    ) external returns (address vault, address strategy) {
        if (msg.sender != creator) revert NotCreator();
        if (vaultForPool[pool] != address(0)) revert PoolAlreadyHasVault();
        (uint160 sqrtPriceX96,,,,,) = ICLPool(pool).slot0();
        if (sqrtPriceX96 == 0) revert BadPool();

        strategy = Clones.clone(strategyImplementation);
        vault = Clones.clone(vaultImplementation);

        AurumStrategySlipstream(strategy).initialize(
            pool, vault, nfpm, swapRouter, v2Factory, rewardRoutes, tickLower, tickUpper, feeConfig, rails
        );
        AurumVault(vault).initialize(strategy, vaultOwner, guardian, keeper, name, symbol);

        // Make sure the CL pools can serve the TWAPs the calm-period check and
        // the reward-sale price limits need (100 = V3-factory parity). v2
        // pools record their own periods.
        ICLPool(pool).increaseObservationCardinalityNext(100);
        for (uint256 i = 0; i < rewardRoutes.length; ++i) {
            if (!rewardRoutes[i].v2Pool0) ICLPool(rewardRoutes[i].pool0).increaseObservationCardinalityNext(100);
            if (rewardRoutes[i].pool1 != address(0) && !rewardRoutes[i].v2Pool1) {
                ICLPool(rewardRoutes[i].pool1).increaseObservationCardinalityNext(100);
            }
        }

        // Seed: pull exactly what the range ratio needs, mint, burn to DEAD.
        (uint256 used0, uint256 used1, uint128 quoted) =
            AurumStrategySlipstream(strategy).quoteDeposit(seed0Max, seed1Max);
        if (quoted == 0) revert SeedFailed();
        if (used0 > 0) IERC20(ICLPool(pool).token0()).safeTransferFrom(msg.sender, strategy, used0);
        if (used1 > 0) IERC20(ICLPool(pool).token1()).safeTransferFrom(msg.sender, strategy, used1);
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
