// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title FeeConfig — per-vault performance fee, read by strategies at harvest.
/// @notice One global registry. The owner sets a default and
///         per-vault overrides; MAX_TOTAL_FEE_BPS is immutable so the worst
///         case is verifiable forever. Fees are charged on harvested yield
///         only, never on principal.
contract FeeConfig is Ownable2Step {
    uint256 public constant MAX_TOTAL_FEE_BPS = 1_500; // 15% hard cap, immutable
    uint256 public constant BPS = 10_000;

    struct Fees {
        uint16 totalBps;  // performance fee on harvested yield
        uint16 callerBps; // slice of the harvest paid to the caller (part of total)
        bool set;         // distinguishes "override exists" from zero fees
    }

    uint16 public defaultTotalBps;
    uint16 public defaultCallerBps;
    address public treasury;

    mapping(address vault => Fees) private _overrides;

    event DefaultFeesSet(uint16 totalBps, uint16 callerBps);
    event VaultFeesSet(address indexed vault, uint16 totalBps, uint16 callerBps);
    event VaultFeesCleared(address indexed vault);
    event TreasurySet(address treasury);

    error RenounceDisabled();
    error FeeAboveCap();
    error CallerFeeAboveTotal();
    error ZeroAddress();

    constructor(address owner_, address treasury_, uint16 defaultTotalBps_, uint16 defaultCallerBps_)
        Ownable(owner_)
    {
        if (treasury_ == address(0)) revert ZeroAddress();
        _check(defaultTotalBps_, defaultCallerBps_);
        treasury = treasury_;
        defaultTotalBps = defaultTotalBps_;
        defaultCallerBps = defaultCallerBps_;
        emit TreasurySet(treasury_);
        emit DefaultFeesSet(defaultTotalBps_, defaultCallerBps_);
    }

    function getFees(address vault) external view returns (uint256 totalBps, uint256 callerBps, address treasury_) {
        Fees memory f = _overrides[vault];
        if (f.set) return (f.totalBps, f.callerBps, treasury);
        return (defaultTotalBps, defaultCallerBps, treasury);
    }

    function setDefaultFees(uint16 totalBps, uint16 callerBps) external onlyOwner {
        _check(totalBps, callerBps);
        defaultTotalBps = totalBps;
        defaultCallerBps = callerBps;
        emit DefaultFeesSet(totalBps, callerBps);
    }

    function setVaultFees(address vault, uint16 totalBps, uint16 callerBps) external onlyOwner {
        _check(totalBps, callerBps);
        _overrides[vault] = Fees({totalBps: totalBps, callerBps: callerBps, set: true});
        emit VaultFeesSet(vault, totalBps, callerBps);
    }

    function clearVaultFees(address vault) external onlyOwner {
        delete _overrides[vault];
        emit VaultFeesCleared(vault);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function _check(uint16 totalBps, uint16 callerBps) private pure {
        if (totalBps > MAX_TOTAL_FEE_BPS) revert FeeAboveCap();
        if (callerBps > totalBps) revert CallerFeeAboveTotal();
    }

    /// @notice Disabled: an ownerless contract would freeze treasury rotation — the recovery path when a token refuses the treasury.
    ///         Hand over with transferOwnership + acceptOwnership instead.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }
}
