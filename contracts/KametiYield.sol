// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// IMPORTS
// NOTE: OpenZeppelin v5 moved ReentrancyGuard & Pausable from security/ → utils/
// ─────────────────────────────────────────────────────────────────────────────
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";  // ← utils/ not security/
import "@openzeppelin/contracts/utils/Pausable.sol";          // ← utils/ not security/
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// ─────────────────────────────────────────────────────────────────────────────
// EXTERNAL INTERFACES
// ─────────────────────────────────────────────────────────────────────────────

/// @dev Aave V3 Pool — the lending protocol where we deposit idle USDC
interface IAavePool {
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16  referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

/// @dev aUSDC — Aave's interest-bearing token
///      Its balance increases every second as interest accrues
///      Deposited 1000 USDC → got 1000 aUSDC → after time → 1020 aUSDC (20 = yield)
interface IAToken {
    function balanceOf(address account) external view returns (uint256);
}

// ─────────────────────────────────────────────────────────────────────────────
// KAMETI YIELD CONTRACT
//
// Purpose  : Manages all yield-generating activity for the Kameti platform.
//            Pools deposit idle USDC here → this contract puts it in Aave →
//            interest accrues → at cycle end, yield is calculated and
//            distributed back to pool members proportionally.
//
// Why separate from KametiPool?
//   → Pool contract stays focused on rotation logic only
//   → Yield strategy can be upgraded without touching pool contracts
//   → Multiple pools share one yield contract (more gas efficient)
//   → Easier to audit — each contract has exactly one responsibility
//
// Roles    : ADMIN_ROLE → owner, can pause, authorise pools, emergency withdraw
//            POOL_ROLE  → granted to KametiPool contracts so they can
//                         call deposit / withdraw / harvestAndDistribute
//
// Flow     : KametiPool calls deposit()            → idle USDC goes into Aave
//            KametiPool calls withdraw()           → USDC comes back from Aave
//            KametiPool calls harvestAndDistribute → yield split to all members
// ─────────────────────────────────────────────────────────────────────────────
contract KametiYield is AccessControl, ReentrancyGuard, Pausable {

    // ─────────────────────────────────────────────────────────────────────────
    // ROLES
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Role given to KametiPool contracts to call yield functions
    bytes32 public constant POOL_ROLE  = keccak256("POOL_ROLE");

    /// @notice Role for the admin — can pause, authorise pools, rescue funds
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ─────────────────────────────────────────────────────────────────────────
    // STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice USDC token contract
    IERC20    public immutable usdc;

    /// @notice Aave V3 lending pool
    IAavePool public immutable aavePool;

    /// @notice aUSDC — Aave's interest-bearing USDC token
    ///         Its balance grows every second → that growth is the yield
    IAToken   public immutable aUsdc;

    // ── Per-pool tracking ─────────────────────────────────────────────────────

    /// @notice Total USDC deposited into Aave by each pool (principal only)
    mapping(address => uint256) public poolDeposited;

    /// @notice Snapshot of aUSDC balance when a pool first deposited
    mapping(address => uint256) public poolDepositSnapshot;

    /// @notice Total yield harvested and distributed by each pool (lifetime)
    mapping(address => uint256) public poolYieldHarvested;

    /// @notice Whether a pool currently has an active deposit in Aave
    mapping(address => bool)    public poolIsDeposited;

    // ── Global tracking ───────────────────────────────────────────────────────

    /// @notice Total USDC currently deposited across ALL pools
    uint256 public totalDeposited;

    /// @notice Total yield ever distributed across ALL pools (lifetime)
    uint256 public totalYieldDistributed;

    /// @notice Timestamp of the most recent deposit
    uint256 public lastDepositTime;

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event Deposited(
        address indexed pool,
        uint256         amount,
        uint256         newTotalDeposited
    );

    event Withdrawn(
        address indexed pool,
        uint256         principalWithdrawn,
        uint256         yieldEarned
    );

    event YieldDistributed(
        address indexed pool,
        uint256         totalYield,
        uint256         memberCount,
        uint256         yieldPerMember
    );

    event MemberYieldPaid(
        address indexed pool,
        address indexed member,
        uint256         amount
    );

    event EmergencyWithdrawal(
        address indexed admin,
        uint256         amount,
        address         to
    );

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sets up the yield contract with all required protocol addresses.
    /// @dev    All three token/protocol addresses are immutable — they can never
    ///         be swapped after deployment. This protects users.
    /// @param  _usdc     USDC token contract address
    /// @param  _aavePool Aave V3 Pool contract address
    /// @param  _aUsdc    aUSDC token address (Aave's interest-bearing USDC)
    constructor(
        address _usdc,
        address _aavePool,
        address _aUsdc
    ) {
        require(_usdc     != address(0), "KametiYield: invalid USDC address");
        require(_aavePool != address(0), "KametiYield: invalid Aave address");
        require(_aUsdc    != address(0), "KametiYield: invalid aUSDC address");

        usdc     = IERC20(_usdc);
        aavePool = IAavePool(_aavePool);
        aUsdc    = IAToken(_aUsdc);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE,         msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // POOL-FACING FUNCTIONS (only authorised KametiPool contracts can call)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit idle USDC from a pool into Aave to start earning yield.
    /// @dev    Pool must transfer USDC to this contract BEFORE calling deposit().
    ///         Called by KametiPool after each round's payout is sent out.
    /// @param  poolAddress The KametiPool contract calling this function
    /// @param  amount      USDC amount to deposit into Aave
    function deposit(address poolAddress, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(POOL_ROLE)
    {
        require(amount > 0,                              "KametiYield: amount must be > 0");
        require(poolAddress != address(0),               "KametiYield: invalid pool address");
        require(
            usdc.balanceOf(address(this)) >= amount,
            "KametiYield: insufficient USDC balance - pool must transfer first"
        );

        // Snapshot aUSDC balance before first deposit so we can track this pool's yield
        if (!poolIsDeposited[poolAddress]) {
            poolDepositSnapshot[poolAddress] = aUsdc.balanceOf(address(this));
        }

        // Approve Aave to pull USDC, then supply
        usdc.approve(address(aavePool), amount);
        aavePool.supply(address(usdc), amount, address(this), 0);

        // Update accounting
        poolDeposited[poolAddress]  += amount;
        poolIsDeposited[poolAddress] = true;
        totalDeposited              += amount;
        lastDepositTime              = block.timestamp;

        emit Deposited(poolAddress, amount, totalDeposited);
    }

    /// @notice Withdraw a pool's USDC principal back from Aave.
    /// @dev    Called at the end of a cycle. Yield is handled separately
    ///         by harvestAndDistribute().
    /// @param  poolAddress The KametiPool contract calling this function
    /// @return withdrawn   Actual USDC amount withdrawn from Aave
    function withdraw(address poolAddress)
        external
        nonReentrant
        onlyRole(POOL_ROLE)
        returns (uint256 withdrawn)
    {
        require(poolIsDeposited[poolAddress], "KametiYield: no active deposit for this pool");

        uint256 principal = poolDeposited[poolAddress];
        require(principal > 0, "KametiYield: nothing to withdraw");

        // Withdraw principal from Aave back to this contract
        withdrawn = aavePool.withdraw(address(usdc), principal, address(this));

        // Send principal USDC back to the pool contract
        usdc.transfer(poolAddress, withdrawn);

        // Update accounting
        uint256 yieldEarned             = _calculatePoolYield(poolAddress);
        totalDeposited                 -= principal;
        poolDeposited[poolAddress]      = 0;
        poolIsDeposited[poolAddress]    = false;

        emit Withdrawn(poolAddress, withdrawn, yieldEarned);

        return withdrawn;
    }

    /// @notice Calculate yield earned by a pool and distribute it equally to all members.
    /// @dev    Called at cycle end AFTER withdraw(). Splits yield proportionally.
    ///
    ///         Example:
    ///           10 members deposited 50,000 USDC total
    ///           Aave earned 3,000 USDC yield over 10 months
    ///           Each member receives 3,000 / 10 = 300 USDC bonus
    ///
    /// @param  poolAddress The KametiPool contract calling this function
    /// @param  members     Array of all member wallet addresses to receive yield
    function harvestAndDistribute(
        address            poolAddress,
        address[] calldata members
    )
        external
        nonReentrant
        onlyRole(POOL_ROLE)
    {
        require(members.length > 0,         "KametiYield: no members provided");
        require(poolAddress != address(0),  "KametiYield: invalid pool address");

        uint256 totalYield = _calculatePoolYield(poolAddress);

        // Nothing to distribute — skip silently
        if (totalYield == 0) return;

        // Withdraw only the yield portion from Aave
        aavePool.withdraw(address(usdc), totalYield, address(this));

        uint256 memberCount    = members.length;
        uint256 yieldPerMember = totalYield / memberCount;

        // Dust = leftover from integer division rounding
        // e.g. 100 USDC / 3 members = 33 each + 1 dust → last member gets 34
        uint256 dust = totalYield - (yieldPerMember * memberCount);

        for (uint256 i = 0; i < memberCount; i++) {
            address member = members[i];
            require(member != address(0), "KametiYield: invalid member address");

            // Last member absorbs any rounding dust
            uint256 payout = (i == memberCount - 1)
                ? yieldPerMember + dust
                : yieldPerMember;

            usdc.transfer(member, payout);
            emit MemberYieldPaid(poolAddress, member, payout);
        }

        poolYieldHarvested[poolAddress] += totalYield;
        totalYieldDistributed           += totalYield;

        emit YieldDistributed(poolAddress, totalYield, memberCount, yieldPerMember);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS — free to call, zero gas
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the current yield earned by a specific pool.
    ///         This is a live figure — increases every second as Aave accrues interest.
    /// @param  poolAddress The pool to check
    /// @return yieldEarned USDC yield earned so far (not yet distributed)
    function getPoolYield(address poolAddress)
        external
        view
        returns (uint256 yieldEarned)
    {
        return _calculatePoolYield(poolAddress);
    }

    /// @notice Returns the total aUSDC balance held by this contract
    function getTotalAaveBalance()
        external
        view
        returns (uint256)
    {
        return aUsdc.balanceOf(address(this));
    }

    /// @notice Returns total yield currently sitting in Aave (not yet harvested)
    function getTotalUnrealisedYield()
        external
        view
        returns (uint256)
    {
        uint256 aaveBalance = aUsdc.balanceOf(address(this));
        if (aaveBalance <= totalDeposited) return 0;
        return aaveBalance - totalDeposited;
    }

    /// @notice Returns a pool's full yield summary in one call
    /// @return deposited      How much USDC this pool has deposited (principal)
    /// @return currentYield   Yield earned so far (live, updates every second)
    /// @return totalHarvested All yield ever distributed by this pool
    /// @return isActive       Whether this pool currently has funds in Aave
    function getPoolSummary(address poolAddress)
        external
        view
        returns (
            uint256 deposited,
            uint256 currentYield,
            uint256 totalHarvested,
            bool    isActive
        )
    {
        return (
            poolDeposited[poolAddress],
            _calculatePoolYield(poolAddress),
            poolYieldHarvested[poolAddress],
            poolIsDeposited[poolAddress]
        );
    }

    /// @notice Estimate yield per member given current state
    /// @param  poolAddress Pool to estimate for
    /// @param  memberCount Number of members in the pool
    /// @return yieldPerMember Estimated USDC yield each member would receive now
    function estimateYieldPerMember(address poolAddress, uint256 memberCount)
        external
        view
        returns (uint256 yieldPerMember)
    {
        if (memberCount == 0) return 0;
        return _calculatePoolYield(poolAddress) / memberCount;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ADMIN FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Grant POOL_ROLE to a newly deployed KametiPool contract.
    /// @dev    Must be called right after a new pool is deployed by the factory.
    /// @param  poolAddress Address of the KametiPool contract to authorise
    function authorisePool(address poolAddress)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(poolAddress != address(0), "KametiYield: invalid pool address");
        _grantRole(POOL_ROLE, poolAddress);
    }

    /// @notice Revoke POOL_ROLE from a pool (e.g., if compromised)
    /// @param  poolAddress Address of the pool to revoke
    function revokePool(address poolAddress)
        external
        onlyRole(ADMIN_ROLE)
    {
        _revokeRole(POOL_ROLE, poolAddress);
    }

    /// @notice Pause all deposits. Withdrawals remain possible.
    function pause()
        external
        onlyRole(ADMIN_ROLE)
    {
        _pause();
    }

    /// @notice Resume normal operation after a pause.
    function unpause()
        external
        onlyRole(ADMIN_ROLE)
    {
        _unpause();
    }

    /// @notice Emergency: withdraw ALL funds from Aave to a safe address.
    /// @dev    Last-resort only. Use if Aave is compromised or critical bug found.
    ///         Always emits an event so it is publicly visible on-chain.
    /// @param  to Safe address to send all recovered USDC to
    function emergencyWithdraw(address to)
        external
        onlyRole(ADMIN_ROLE)
    {
        require(to != address(0), "KametiYield: invalid destination");

        uint256 aaveBalance    = aUsdc.balanceOf(address(this));
        uint256 withdrawn      = 0;

        if (aaveBalance > 0) {
            withdrawn = aavePool.withdraw(address(usdc), type(uint256).max, address(this));
        }

        uint256 directBalance  = usdc.balanceOf(address(this));
        uint256 totalRecovered = withdrawn + directBalance;

        if (totalRecovered > 0) {
            usdc.transfer(to, totalRecovered);
        }

        totalDeposited = 0;

        emit EmergencyWithdrawal(msg.sender, totalRecovered, to);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Calculates how much yield a specific pool has earned in Aave.
    ///
    ///      Method (proportional share):
    ///        Total yield in Aave = aUSDC balance − totalDeposited
    ///        Pool's yield share  = totalYield × (poolDeposited / totalDeposited)
    ///
    ///      Example:
    ///        Pool deposited 50,000 out of 200,000 total = 25% share
    ///        Total yield = 4,000 USDC
    ///        Pool's yield = 4,000 × 25% = 1,000 USDC
    ///
    /// @param  poolAddress The pool to calculate yield for
    /// @return Pool's proportional yield in USDC
    function _calculatePoolYield(address poolAddress)
        internal
        view
        returns (uint256)
    {
        if (!poolIsDeposited[poolAddress]) return 0;
        if (totalDeposited == 0)           return 0;

        uint256 aaveBalance = aUsdc.balanceOf(address(this));
        if (aaveBalance <= totalDeposited) return 0;

        uint256 totalYield = aaveBalance - totalDeposited;
        uint256 poolShare  = (totalYield * poolDeposited[poolAddress]) / totalDeposited;

        return poolShare;
    }
}
