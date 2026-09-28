// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AurumVault} from "./AurumVault.sol";
import {AurumStrategyUniV4} from "./AurumStrategyUniV4.sol";
import {IPoolManager, PoolKey, Currency} from "./vendor/uniswap/v4/V4Core.sol";
import {V4StateReader} from "./vendor/uniswap/v4/V4StateReader.sol";

/// @title AurumFactoryV4 — one-transaction V4 vault deployment + registry.
/// @notice The V3 factory adapted to Uniswap V4: vaults are keyed by the
///         bytes32 poolId (pools live inside the singleton PoolManager), the
///         creator passes the full PoolKey (the id is derived here so key and
///         id can never mismatch), and the strict pool policy is enforced
///         on-chain: hookless pools with two ERC-20 currencies only. There is
///         no observation-cardinality step — V4 pools carry no oracle; calm
///         rails come from the strategy's internal checkpoint.
contract AurumFactoryV4 is Ownable2Step {
    using SafeERC20 for IERC20;

    address public immutable vaultImplementation;
    address public immutable strategyImplementation;
    address public immutable feeConfig;
    IPoolManager public immutable poolManager;
    /// @notice WETH9 used as the ERC20 face for native-c0 pools. Zero is
    ///         allowed — such a factory simply cannot create native vaults.
    address public immutable weth;

    address public vaultOwner; // becomes owner of every vault
    address public guardian;
    address public keeper; // the agent
    address public creator; // the only address allowed to create vaults

    address[] public allVaults;
    mapping(address vault => bool) public isAurumVault;
    mapping(bytes32 poolId => address vault) public vaultForPoolId;

    /// @notice Hooked pools are rejected unless their hook is explicitly
    ///         trusted (source-vetted per the trusted-hook checklist in the
    ///         2026-07-23 design spec). Gates FUTURE vault creation only —
    ///         deployed vaults are immutable clones holding their own PoolKey.
    mapping(address hook => bool) public trustedHooks;

    event VaultCreated(bytes32 indexed poolId, address indexed vault, address indexed strategy, uint128 seedLiquidity);
    event RolesSet(address vaultOwner, address guardian, address keeper, address creator);
    event HookTrusted(address indexed hook, bool trusted);

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
        IPoolManager poolManager_,
        address owner_,
        address guardian_,
        address keeper_,
        address weth_
    ) Ownable(owner_) {
        if (
            vaultImplementation_ == address(0) || strategyImplementation_ == address(0) || feeConfig_ == address(0)
                || address(poolManager_) == address(0) || guardian_ == address(0) || keeper_ == address(0)
        ) revert ZeroAddress();
        vaultImplementation = vaultImplementation_;
        strategyImplementation = strategyImplementation_;
        feeConfig = feeConfig_;
        poolManager = poolManager_;
        weth = weth_;
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

    /// @notice Trust (or untrust) a hook address for FUTURE vault creation.
    ///         Untrusting never affects deployed vaults — they are immutable
    ///         clones holding their own PoolKey.
    function setTrustedHook(address hook, bool trusted) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        trustedHooks[hook] = trusted;
        emit HookTrusted(hook, trusted);
    }

    /// @notice Deploy a vault/strategy pair on the pool identified by `key`,
    ///         with an initial range and a seed deposit (pulled from the
    ///         caller, shares burned to DEAD).
    function createVault(
        PoolKey calldata key,
        int24 tickLower,
        int24 tickUpper,
        uint256 seed0Max,
        uint256 seed1Max,
        AurumStrategyUniV4.RailsV4 calldata rails,
        string calldata name,
        string calldata symbol
    ) external returns (address vault, address strategy) {
        if (msg.sender != creator) revert NotCreator();

        bytes32 poolId = V4StateReader.poolIdFor(key);
        if (vaultForPoolId[poolId] != address(0)) revert PoolAlreadyHasVault();
        // Strict policy, matching the data layer: hookless (or explicitly
        // trusted hook). currency0 may be native ETH — the strategy then runs
        // behind its WETH face (wrap-at-the-edge); currency1 is always an
        // ERC-20 (V4 guarantees native can only ever be currency0).
        if (key.hooks != address(0) && !trustedHooks[key.hooks]) revert BadPool();
        bool native0 = Currency.unwrap(key.currency0) == address(0);
        if (native0 && weth == address(0)) revert BadPool();
        // An ETH/WETH pool would map both token0 and token1 to WETH (native
        // currency0 uses the WETH face), collapsing the strategy's idle
        // accounting into a double-count on withdrawal. Reject it outright.
        if (native0 && Currency.unwrap(key.currency1) == weth) revert BadPool();
        (uint160 sqrtPriceX96,,,) = V4StateReader.getSlot0(poolManager, poolId);
        if (sqrtPriceX96 == 0) revert BadPool();

        strategy = Clones.clone(strategyImplementation);
        vault = Clones.clone(vaultImplementation);

        AurumStrategyUniV4(payable(strategy)).initialize(poolManager, key, vault, tickLower, tickUpper, feeConfig, weth, rails);
        AurumVault(vault).initialize(strategy, vaultOwner, guardian, keeper, name, symbol);

        // Seed: pull exactly what the range ratio needs, mint, burn to DEAD.
        (uint256 used0, uint256 used1, uint128 quoted) =
            AurumStrategyUniV4(payable(strategy)).quoteDeposit(seed0Max, seed1Max);
        if (quoted == 0) revert SeedFailed();
        // token0 is the strategy's ERC20 face — for native pools that is WETH,
        // so seeding always pulls an ERC20 (the strategy unwraps at the
        // settle boundary on first invest).
        if (used0 > 0) IERC20(AurumStrategyUniV4(payable(strategy)).token0()).safeTransferFrom(msg.sender, strategy, used0);
        if (used1 > 0) IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, strategy, used1);
        uint128 seedLiquidity = AurumVault(vault).seedDeposit(used0, used1);
        if (seedLiquidity < MIN_SEED_LIQUIDITY) revert SeedTooSmall();

        allVaults.push(vault);
        isAurumVault[vault] = true;
        vaultForPoolId[poolId] = vault;
        emit VaultCreated(poolId, vault, strategy, seedLiquidity);
    }

    /// @notice Disabled: an ownerless contract would freeze vault creation, the hook allowlist and the roles handed to new vaults.
    ///         Hand over with transferOwnership + acceptOwnership instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
