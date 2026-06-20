// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// IMPORTS
// NOTE: In OpenZeppelin v5, ERC20 and AccessControl paths remain the same
// ─────────────────────────────────────────────────────────────────────────────
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// ─────────────────────────────────────────────────────────────────────────────
// KAMETI TOKEN ($KMTI)
//
// Purpose  : Governance + reward token for the Kameti platform
// Standard : ERC-20 (fungible token)
// Supply   : 100,000,000 KMTI hard cap — no more can ever be minted
// Roles    : DEFAULT_ADMIN_ROLE → can grant/revoke roles
//            MINTER_ROLE        → given to KametiPool contracts to reward members
// ─────────────────────────────────────────────────────────────────────────────
contract KametiToken is ERC20, AccessControl {

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTANTS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Role identifier for addresses allowed to mint new KMTI tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Absolute maximum supply — 100 million tokens (18 decimals)
    uint256 public constant MAX_SUPPLY = 100_000_000 * 10 ** 18;

    // ─────────────────────────────────────────────────────────────────────────
    // STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice On-chain credit score for each user (range: 0 – 1000)
    ///         Higher score = more trusted = lower collateral required in pools
    mapping(address => uint256) public creditScore;

    /// @notice Total number of Kameti cycles successfully completed by each user
    mapping(address => uint256) public cyclesCompleted;

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted whenever a user's credit score is recalculated
    event CreditScoreUpdated(address indexed user, uint256 newScore);

    /// @notice Emitted whenever a user successfully completes a Kameti cycle
    event CycleCompleted(address indexed user, uint256 totalCycles);

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Runs once at deployment.
    ///      - Names the token "Kameti Token" with symbol "KMTI"
    ///      - Grants deployer both admin and minter roles
    ///      - Mints 20M tokens to deployer (for team/treasury — should be vested)
    constructor() ERC20("Kameti Token", "KMTI") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE,        msg.sender);

        // ⚠️  Put these tokens under a vesting contract immediately after deploy
        _mint(msg.sender, 20_000_000 * 10 ** 18);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EXTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Reward a user with KMTI tokens upon completing a Kameti cycle.
    /// @dev    Only callable by addresses with MINTER_ROLE (KametiPool contracts).
    ///         Blocked if minting would exceed the 100M hard cap.
    /// @param  user   Wallet address of the member who completed the cycle
    /// @param  amount Number of KMTI tokens to mint (18 decimals)
    function rewardCompletion(address user, uint256 amount)
        external
        onlyRole(MINTER_ROLE)
    {
        require(
            totalSupply() + amount <= MAX_SUPPLY,
            "KametiToken: max supply exceeded"
        );

        _mint(user, amount);

        cyclesCompleted[user]++;
        _updateCreditScore(user);

        emit CycleCompleted(user, cyclesCompleted[user]);
    }

    /// @notice Returns the collateral discount a user qualifies for, in basis points.
    /// @dev    Formula: (creditScore x 50) / 100
    ///         creditScore = 0    →   0 bps  (0.0% discount)
    ///         creditScore = 500  → 250 bps  (2.5% discount)
    ///         creditScore = 1000 → 500 bps  (5.0% discount) ← maximum
    /// @param  user The wallet address to check
    /// @return discountBps Discount in basis points (100 bps = 1%)
    function getCollateralDiscount(address user)
        external
        view
        returns (uint256 discountBps)
    {
        return (creditScore[user] * 50) / 100;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Recalculates credit score whenever rewardCompletion() is called.
    ///
    ///      Formula:
    ///        balanceBonus = floor(KMTI balance / 1,000 KMTI)
    ///        score        = (cyclesCompleted × 50) + balanceBonus
    ///        score        = min(score, 1000)   ← hard cap
    ///
    ///      Examples:
    ///        1 cycle,  0 KMTI    → score = 50
    ///        5 cycles, 2000 KMTI → score = 252
    ///        20 cycles, 5000 KMTI → score = 1000 (capped)
    function _updateCreditScore(address user) internal {
        uint256 balanceBonus = balanceOf(user) / (1_000 * 10 ** 18);
        uint256 score        = (cyclesCompleted[user] * 50) + balanceBonus;

        creditScore[user] = score > 1000 ? 1000 : score;

        emit CreditScoreUpdated(user, creditScore[user]);
    }
}
