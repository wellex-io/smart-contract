// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { IWellnessOracle } from "./interfaces/IWellnessOracle.sol";
import { WellnessTrustedStrategy4626 } from "./WellnessTrustedStrategy4626.sol";

/// @title WellixGateway
/// @notice User-facing gateway: lock-up staking, oracle-based APY rewards, and strategy liquidity.
/// @dev Booked rewards require strategy liquidity: `totalPrincipal + totalPendingRewards <= strategy maxWithdraw( this )`.
contract WellixGateway is AccessControl, Pausable, EIP712 {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    bytes32 public constant SPONSOR_ROLE = keccak256("SPONSOR_ROLE");

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant YEAR = 365 days;
    /// @notice Hard cap for sponsor skim on `depositFor` (10%).
    uint256 public constant MAX_SPONSOR_FEE_BPS = 1_000;

    bytes32 private constant WITHDRAW_TYPEHASH = keccak256(
        "Withdraw(address beneficiary,uint256 nonce,uint256 deadline,bytes32 positionIdsHash)"
    );
    bytes32 private constant CLAIM_REWARDS_TYPEHASH =
        keccak256("ClaimRewards(address beneficiary,uint256 nonce,uint256 deadline)");

    struct DepositRecord {
        uint128 amount;
        uint64 depositTimestamp;
        uint64 unlockAt;
        bool withdrawn;
    }

    /// @notice Snapshot-friendly aggregate for a user (MVP migration / indexers).
    struct UserLedger {
        uint256 activePrincipal;
        uint256 pendingRewardsAmount;
        uint256[] positionIds;
    }

    IERC20 public immutable stakeAsset;
    /// @notice `true` if `stakeAsset` responds to EIP-2612 `nonces` / `DOMAIN_SEPARATOR` (probe at deploy). `depositFor` always works; `depositForWithPermit` requires this.
    bool public immutable stakeAssetSupportsPermit;

    IWellnessOracle public wellnessOracle;
    WellnessTrustedStrategy4626 public strategy;
    uint64 public lockupPeriod;

    /// @notice Optional successor gateway or migration intake contract (metadata only for MVP).
    address public plannedSuccessor;
    uint256 public migrationPlanId;

    uint256 private _nextPositionId = 1;

    uint256 public totalPrincipal;
    uint256 public totalPendingRewards;

    mapping(address account => uint256 principal) public activePrincipalByUser;
    mapping(address account => uint256 amount) public pendingRewards;
    mapping(address account => uint256[] positionIds) private _userPositionIds;
    mapping(address account => mapping(uint256 positionId => DepositRecord record)) private
        _depositRecords;

    /// @notice Optional skim on `depositFor` gross amount; 0 disables fees.
    uint256 public sponsorFeeBps;
    address public feeReceiver;
    /// @notice Per-user nonce for EIP-712 sponsored `withdrawFor` / `claimRewardsFor`.
    mapping(address account => uint256 nonce) public sponsorNonces;

    error ZeroAddress();
    error InvalidAmount();
    error InvalidPeriodDuration(uint256 periodDuration);
    error AmountExceedsUint128(uint256 amount);
    error EmptyParticipants();
    error EmptyPositionIds();
    error PositionNotFound(uint256 positionId);
    error PositionAlreadyWithdrawn(uint256 positionId);
    error PositionLocked(uint256 positionId, uint64 unlockAt);
    error NoRewardsAvailable();
    error InsufficientStrategyLiquidity(uint256 requiredAssets, uint256 availableAssets);
    error FeeReceiverUnset();
    error SponsorFeeTooHigh(uint256 feeBps);
    error InvalidSignature();
    error ExpiredDeadline();
    error InvalidSponsorNonce();
    error StakeAssetDoesNotSupportPermit();

    event Deposited(
        address indexed account, uint256 indexed positionId, uint256 amount, uint64 unlockAt
    );
    event SponsoredDeposit(
        address indexed sponsor,
        address indexed beneficiary,
        uint256 indexed positionId,
        uint256 grossAmount,
        uint256 netAmount,
        uint256 fee,
        uint64 unlockAt
    );
    event Withdrawn(address indexed account, uint256 principalAmount, uint256 rewardsAmount);
    event RewardsClaimed(address indexed account, uint256 amount);
    event RewardsDistributed(
        address indexed distributor, uint256 participantCount, uint256 periodDuration
    );
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event StrategyUpdated(address indexed previousStrategy, address indexed newStrategy);
    event LockupPeriodUpdated(uint64 previousLockupPeriod, uint64 newLockupPeriod);
    event MigrationPlanUpdated(
        uint256 indexed planId, address indexed successor, string metadataURI
    );

    constructor(
        IERC20 stakeAsset_,
        IWellnessOracle wellnessOracle_,
        WellnessTrustedStrategy4626 strategy_,
        uint64 lockupPeriod_,
        address admin
    ) EIP712("WellixGateway", "1") {
        if (
            address(stakeAsset_) == address(0) || address(wellnessOracle_) == address(0)
                || address(strategy_) == address(0) || admin == address(0)
        ) {
            revert ZeroAddress();
        }
        if (lockupPeriod_ == 0) {
            revert InvalidPeriodDuration(lockupPeriod_);
        }

        stakeAsset = stakeAsset_;
        stakeAssetSupportsPermit = _stakeAssetSupportsPermit(address(stakeAsset_));
        wellnessOracle = wellnessOracle_;
        strategy = strategy_;
        lockupPeriod = lockupPeriod_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, admin);
        feeReceiver = admin;
    }

    /// @notice Sets skim taken from gross amount in `depositFor` (capped by `MAX_SPONSOR_FEE_BPS`). Requires `feeReceiver` if fee > 0.
    function setSponsorFeeBps(uint256 feeBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps > MAX_SPONSOR_FEE_BPS) {
            revert SponsorFeeTooHigh(feeBps);
        }
        if (feeBps > 0 && feeReceiver == address(0)) {
            revert FeeReceiverUnset();
        }
        sponsorFeeBps = feeBps;
    }

    /// @notice Receiver of `depositFor` fees.
    function setFeeReceiver(address newFeeReceiver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newFeeReceiver == address(0)) {
            revert ZeroAddress();
        }
        feeReceiver = newFeeReceiver;
    }

    /// @notice Pauses new deposits; withdrawals and reward claims stay open (exit path).
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @notice Records intended V2 deployment for indexers and off-chain migration playbooks.
    function setMigrationPlan(address successor, string calldata metadataURI)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        plannedSuccessor = successor;
        unchecked {
            migrationPlanId++;
        }
        emit MigrationPlanUpdated(migrationPlanId, successor, metadataURI);
    }

    /// @notice Aggregate on-chain liabilities for this user (plus position ids for per-lock migration UX).
    function exportUserLedger(address user) external view returns (UserLedger memory out) {
        return _readUserLedger(user);
    }

    /// @notice Commitment builders use this for merkle / intake proofs (V2); does not include per-position records to bound calldata.
    function migrationCommitment(address user) external view returns (bytes32) {
        UserLedger memory l = _readUserLedger(user);
        return keccak256(
            abi.encode(
                block.chainid,
                address(this),
                user,
                l.activePrincipal,
                l.pendingRewardsAmount,
                keccak256(abi.encodePacked(l.positionIds))
            )
        );
    }

    /// @notice Booked principal + pending reward liabilities.
    function currentLiabilities() external view returns (uint256) {
        return totalPrincipal + totalPendingRewards;
    }

    /// @notice Underlying the gateway can pull from the strategy now (approximate; uses ERC4626 maxWithdraw).
    function strategyWithdrawableAssets() external view returns (uint256) {
        return _strategyWithdrawableAssets();
    }

    /// @notice Creates a locked deposit position.
    function deposit(uint256 amount) external whenNotPaused returns (uint256 positionId) {
        if (amount == 0) {
            revert InvalidAmount();
        }
        if (amount > type(uint128).max) {
            revert AmountExceedsUint128(amount);
        }

        stakeAsset.safeTransferFrom(msg.sender, address(this), amount);
        positionId = _vaultAndBook(msg.sender, amount);
        emit Deposited(
            msg.sender, positionId, amount, _depositRecords[msg.sender][positionId].unlockAt
        );
    }

    /// @notice Sponsor-paid gas: pulls `grossAmount` from `beneficiary` (approve gateway first), applies `sponsorFeeBps` skim, books net principal to `beneficiary`.
    function depositFor(address beneficiary, uint256 grossAmount)
        external
        whenNotPaused
        onlyRole(SPONSOR_ROLE)
        returns (uint256 positionId)
    {
        return _executeSponsoredDeposit(beneficiary, grossAmount);
    }

    /// @notice Same as `depositFor` but sets allowance via EIP-2612 `permit` on `stakeAsset` (user signs off-chain; stake token must implement `IERC20Permit`).
    function depositForWithPermit(
        address beneficiary,
        uint256 grossAmount,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external whenNotPaused onlyRole(SPONSOR_ROLE) returns (uint256 positionId) {
        if (!stakeAssetSupportsPermit) {
            revert StakeAssetDoesNotSupportPermit();
        }
        IERC20Permit(address(stakeAsset))
            .permit(beneficiary, address(this), grossAmount, deadline, v, r, s);
        return _executeSponsoredDeposit(beneficiary, grossAmount);
    }

    /// @notice Withdraws unlocked principal and all pending rewards for caller.
    function withdraw(uint256[] calldata positionIds)
        external
        returns (uint256 principalAmount, uint256 rewardsAmount)
    {
        return _withdraw(msg.sender, msg.sender, positionIds);
    }

    /// @notice Sponsor submits withdrawal authorized by `beneficiary` via EIP-712 (`Withdraw`).
    function withdrawFor(
        address beneficiary,
        uint256[] calldata positionIds,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(SPONSOR_ROLE) returns (uint256 principalAmount, uint256 rewardsAmount) {
        bytes32 structHash = keccak256(
            abi.encode(
                WITHDRAW_TYPEHASH,
                beneficiary,
                nonce,
                deadline,
                keccak256(abi.encodePacked(positionIds))
            )
        );
        _authorizeSponsoredAction(beneficiary, nonce, deadline, structHash, v, r, s);
        return _withdraw(beneficiary, beneficiary, positionIds);
    }

    /// @notice Claims available pending rewards without principal withdrawal.
    function claimRewards() external returns (uint256 amount) {
        return _claimRewards(msg.sender, msg.sender);
    }

    /// @notice Sponsor submits reward claim authorized by `beneficiary` via EIP-712 (`ClaimRewards`).
    function claimRewardsFor(
        address beneficiary,
        uint256 nonce,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external onlyRole(SPONSOR_ROLE) returns (uint256 amount) {
        bytes32 structHash =
            keccak256(abi.encode(CLAIM_REWARDS_TYPEHASH, beneficiary, nonce, deadline));
        _authorizeSponsoredAction(beneficiary, nonce, deadline, structHash, v, r, s);
        return _claimRewards(beneficiary, beneficiary);
    }

    /// @notice Allocates APY-based rewards. Requires strategy to already hold enough underlying for all liabilities after the batch.
    function distributeRewards(address[] calldata participants, uint256 periodDuration)
        external
        onlyRole(REWARD_DISTRIBUTOR_ROLE)
    {
        uint256 participantCount = participants.length;
        if (participantCount == 0) {
            revert EmptyParticipants();
        }
        if (periodDuration == 0 || periodDuration > YEAR) {
            revert InvalidPeriodDuration(periodDuration);
        }

        uint256[] memory rewards = new uint256[](participantCount);
        uint256 batchTotal;
        for (uint256 i; i < participantCount; ++i) {
            address participant = participants[i];
            if (participant == address(0)) {
                revert ZeroAddress();
            }

            uint256 reward = _calculateEntitledReward(participant, periodDuration);
            rewards[i] = reward;
            batchTotal += reward;
        }

        uint256 liabilitiesAfter = totalPrincipal + totalPendingRewards + batchTotal;
        uint256 available = _strategyWithdrawableAssets();
        if (available < liabilitiesAfter) {
            revert InsufficientStrategyLiquidity(liabilitiesAfter, available);
        }

        for (uint256 i; i < participantCount; ++i) {
            uint256 reward = rewards[i];
            if (reward == 0) {
                continue;
            }
            address participant = participants[i];
            pendingRewards[participant] += reward;
            totalPendingRewards += reward;
        }

        emit RewardsDistributed(msg.sender, participantCount, periodDuration);
    }

    function previewEntitledReward(address account, uint256 periodDuration)
        external
        view
        returns (uint256)
    {
        return _calculateEntitledReward(account, periodDuration);
    }

    function getUserPositionIds(address account) external view returns (uint256[] memory) {
        return _userPositionIds[account];
    }

    function getDepositRecord(address account, uint256 positionId)
        external
        view
        returns (DepositRecord memory)
    {
        return _depositRecords[account][positionId];
    }

    function setWellnessOracle(IWellnessOracle newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newOracle) == address(0)) {
            revert ZeroAddress();
        }

        address previousOracle = address(wellnessOracle);
        wellnessOracle = newOracle;
        emit OracleUpdated(previousOracle, address(newOracle));
    }

    function setStrategy(WellnessTrustedStrategy4626 newStrategy)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (address(newStrategy) == address(0)) {
            revert ZeroAddress();
        }
        if (address(newStrategy.asset()) != address(stakeAsset)) {
            revert ZeroAddress();
        }

        address previousStrategy = address(strategy);
        strategy = newStrategy;
        emit StrategyUpdated(previousStrategy, address(newStrategy));
    }

    function setLockupPeriod(uint64 newLockupPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newLockupPeriod == 0) {
            revert InvalidPeriodDuration(newLockupPeriod);
        }

        uint64 previousLockupPeriod = lockupPeriod;
        lockupPeriod = newLockupPeriod;
        emit LockupPeriodUpdated(previousLockupPeriod, newLockupPeriod);
    }

    function _executeSponsoredDeposit(address beneficiary, uint256 grossAmount)
        internal
        returns (uint256 positionId)
    {
        if (beneficiary == address(0)) {
            revert ZeroAddress();
        }
        if (grossAmount == 0) {
            revert InvalidAmount();
        }
        if (grossAmount > type(uint128).max) {
            revert AmountExceedsUint128(grossAmount);
        }

        uint256 fee = Math.mulDiv(grossAmount, sponsorFeeBps, BPS_DENOMINATOR);
        if (fee > 0 && feeReceiver == address(0)) {
            revert FeeReceiverUnset();
        }

        uint256 netAmount = grossAmount - fee;
        if (netAmount == 0) {
            revert InvalidAmount();
        }

        stakeAsset.safeTransferFrom(beneficiary, address(this), grossAmount);
        if (fee > 0) {
            stakeAsset.safeTransfer(feeReceiver, fee);
        }

        positionId = _vaultAndBook(beneficiary, netAmount);
        uint64 unlockAt = _depositRecords[beneficiary][positionId].unlockAt;
        emit Deposited(beneficiary, positionId, netAmount, unlockAt);
        emit SponsoredDeposit(
            msg.sender, beneficiary, positionId, grossAmount, netAmount, fee, unlockAt
        );
    }

    function _vaultAndBook(address beneficiary, uint256 amount)
        internal
        returns (uint256 positionId)
    {
        stakeAsset.forceApprove(address(strategy), amount);
        strategy.deposit(amount, address(this));

        positionId = _nextPositionId++;
        uint64 unlockAt = uint64(block.timestamp) + lockupPeriod;
        _depositRecords[beneficiary][positionId] = DepositRecord({
            amount: uint128(amount),
            depositTimestamp: uint64(block.timestamp),
            unlockAt: unlockAt,
            withdrawn: false
        });
        _userPositionIds[beneficiary].push(positionId);

        activePrincipalByUser[beneficiary] += amount;
        totalPrincipal += amount;
    }

    function _withdraw(address account, address payoutTo, uint256[] calldata positionIds)
        internal
        returns (uint256 principalAmount, uint256 rewardsAmount)
    {
        uint256 positionCount = positionIds.length;
        if (positionCount == 0) {
            revert EmptyPositionIds();
        }

        for (uint256 i; i < positionCount; ++i) {
            uint256 positionId = positionIds[i];
            DepositRecord storage record = _depositRecords[account][positionId];

            if (record.amount == 0) {
                revert PositionNotFound(positionId);
            }
            if (record.withdrawn) {
                revert PositionAlreadyWithdrawn(positionId);
            }
            if (block.timestamp < record.unlockAt) {
                revert PositionLocked(positionId, record.unlockAt);
            }

            record.withdrawn = true;
            principalAmount += record.amount;
        }

        rewardsAmount = pendingRewards[account];
        uint256 payout = principalAmount + rewardsAmount;
        _requireStrategyCanPay(payout);

        activePrincipalByUser[account] -= principalAmount;
        totalPrincipal -= principalAmount;

        rewardsAmount = _consumePendingRewards(account);

        strategy.withdraw(payout, payoutTo, address(this));

        emit Withdrawn(account, principalAmount, rewardsAmount);
    }

    function _claimRewards(address account, address payoutTo) internal returns (uint256 amount) {
        amount = pendingRewards[account];
        if (amount == 0) {
            revert NoRewardsAvailable();
        }

        _requireStrategyCanPay(amount);

        amount = _consumePendingRewards(account);

        strategy.withdraw(amount, payoutTo, address(this));
        emit RewardsClaimed(account, amount);
    }

    function _authorizeSponsoredAction(
        address beneficiary,
        uint256 nonce,
        uint256 deadline,
        bytes32 structHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        if (block.timestamp > deadline) {
            revert ExpiredDeadline();
        }
        if (nonce != sponsorNonces[beneficiary]) {
            revert InvalidSponsorNonce();
        }
        address signer = ECDSA.recover(_hashTypedDataV4(structHash), v, r, s);
        if (signer != beneficiary) {
            revert InvalidSignature();
        }
        unchecked {
            sponsorNonces[beneficiary]++;
        }
    }

    function _strategyWithdrawableAssets() internal view returns (uint256) {
        return strategy.maxWithdraw(address(this));
    }

    function _requireStrategyCanPay(uint256 assets) internal view {
        uint256 available = _strategyWithdrawableAssets();
        if (assets > available) {
            revert InsufficientStrategyLiquidity(assets, available);
        }
    }

    function _calculateEntitledReward(address account, uint256 periodDuration)
        internal
        view
        returns (uint256)
    {
        uint256 principal = activePrincipalByUser[account];
        if (principal == 0 || periodDuration == 0) {
            return 0;
        }

        uint256 apyBps = wellnessOracle.getApyBps(account);
        return Math.mulDiv(Math.mulDiv(principal, apyBps, BPS_DENOMINATOR), periodDuration, YEAR);
    }

    function _consumePendingRewards(address account) internal returns (uint256 amount) {
        amount = pendingRewards[account];
        if (amount == 0) {
            return 0;
        }

        pendingRewards[account] = 0;
        totalPendingRewards -= amount;
    }

    /// @dev Best-effort EIP-2612 surface check (used once at construction). Does not guarantee a correct `permit` implementation.
    function _stakeAssetSupportsPermit(address token) private view returns (bool) {
        (bool okNonce, bytes memory retNonce) = token.staticcall(
            abi.encodeWithSelector(IERC20Permit.nonces.selector, address(0xdead))
        );
        if (!okNonce || retNonce.length < 32) {
            return false;
        }
        (bool okDomain, bytes memory retDomain) =
            token.staticcall(abi.encodeWithSelector(IERC20Permit.DOMAIN_SEPARATOR.selector));
        return okDomain && retDomain.length == 32;
    }

    function _readUserLedger(address user) private view returns (UserLedger memory out) {
        out.activePrincipal = activePrincipalByUser[user];
        out.pendingRewardsAmount = pendingRewards[user];
        out.positionIds = _userPositionIds[user];
    }
}

