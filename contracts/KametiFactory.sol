// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// IMPORT
// IMPORTANT: KametiPool.sol must be in the SAME folder as this file in Remix
//            If using Hardhat/Foundry, adjust path to match your folder structure
// ─────────────────────────────────────────────────────────────────────────────
import "./KametiPool.sol";

// ─────────────────────────────────────────────────────────────────────────────
// KAMETI FACTORY
//
// Purpose  : The single entry point for creating new Kameti pool contracts.
//            Instead of deploying KametiPool manually each time, anyone calls
//            createPool() here and the factory handles deployment automatically.
//
// Flow     : User calls createPool()
//              → Factory builds a KametiPool.PoolConfig struct
//              → Factory deploys a fresh KametiPool contract
//              → New pool address is recorded and returned
//              → PoolCreated event emitted for frontends to detect
//
// Config   : Chainlink VRF, Aave, and USDC addresses are set ONCE in the
//            constructor and reused for every pool — no need to pass them
//            on every createPool() call.
// ─────────────────────────────────────────────────────────────────────────────
contract KametiFactory {

    // ─────────────────────────────────────────────────────────────────────────
    // STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Every pool ever created through this factory
    address[] public allPools;

    /// @notice All pools created by a specific wallet address
    mapping(address => address[]) public poolsByCreator;

    /// @notice All pools a specific wallet has joined as a member
    mapping(address => address[]) public poolsByMember;

    // ── Protocol-level config (set once at deployment, never changes) ─────────

    /// @notice Chainlink VRF Coordinator address (for provably fair randomness)
    address public vrfCoordinator;

    /// @notice Aave V3 lending pool address (for yield generation)
    address public aavePool;

    /// @notice USDC token contract address (currency used in all pools)
    address public usdc;

    /// @notice Chainlink VRF subscription ID (must be funded with LINK tokens)
    uint64  public subscriptionId;

    /// @notice Chainlink VRF key hash (determines which oracle fulfils requests)
    bytes32 public keyHash;

    /// @notice Platform wallet that receives the fee from each round's payout
    address public feeCollector;

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted every time a new KametiPool is successfully deployed
    /// @param  pool          Address of the newly created pool contract
    /// @param  creator       Wallet that called createPool()
    /// @param  maxMembers    How many members the pool accepts
    /// @param  monthlyAmount USDC contribution required per member per month
    event PoolCreated(
        address indexed pool,
        address indexed creator,
        uint256         maxMembers,
        uint256         monthlyAmount
    );

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Sets all protocol-level config once at deployment.
    /// @param  _vrf     Chainlink VRF Coordinator address
    /// @param  _aave    Aave V3 Pool address
    /// @param  _usdc    USDC token address
    /// @param  _subId   Chainlink VRF subscription ID
    /// @param  _keyHash Chainlink VRF key hash for the target network
    /// @param  _fee     Platform fee collector wallet address
    constructor(
        address _vrf,
        address _aave,
        address _usdc,
        uint64  _subId,
        bytes32 _keyHash,
        address _fee
    ) {
        vrfCoordinator = _vrf;
        aavePool        = _aave;
        usdc            = _usdc;
        subscriptionId  = _subId;
        keyHash         = _keyHash;
        feeCollector    = _fee;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EXTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deploy a brand new KametiPool with the given parameters.
    ///
    /// @param  _monthlyAmount  USDC each member contributes per month
    ///                         (6 decimals — e.g. 5000e6 = 5,000 USDC)
    /// @param  _maxMembers     Total number of members the pool accepts
    ///                         (pool auto-starts when this count is reached)
    /// @param  _collateralBps  Collateral as basis points of total cycle amount
    ///                         (e.g. 2000 = 20% collateral required to join)
    /// @param  _windowHours    Hours each member has to pay their contribution
    ///                         (e.g. 120 = 5 days per round)
    /// @param  _platformFeeBps Platform fee deducted from each payout
    ///                         (e.g. 100 = 1% fee per round)
    ///
    /// @return poolAddress     Address of the newly deployed KametiPool contract
    function createPool(
        uint256 _monthlyAmount,
        uint256 _maxMembers,
        uint256 _collateralBps,
        uint256 _windowHours,
        uint256 _platformFeeBps
    ) external returns (address poolAddress) {

        // ── Input validation ──────────────────────────────────────────────────
        require(_monthlyAmount  > 0,    "KametiFactory: monthly amount must be > 0");
        require(_maxMembers     >= 2,   "KametiFactory: pool must have at least 2 members");
        require(_maxMembers     <= 100, "KametiFactory: pool cannot exceed 100 members");
        require(_collateralBps  <= 5000,"KametiFactory: collateral cannot exceed 50%");
        require(_windowHours    >= 24,  "KametiFactory: window must be at least 24 hours");
        require(_platformFeeBps <= 500, "KametiFactory: platform fee cannot exceed 5%");

        // ── Build pool configuration ──────────────────────────────────────────
        KametiPool.PoolConfig memory cfg = KametiPool.PoolConfig({
            monthlyAmount     : _monthlyAmount,
            maxMembers        : _maxMembers,
            collateralBps     : _collateralBps,
            contributionWindow: _windowHours,
            platformFeeBps    : _platformFeeBps
        });

        // ── Deploy fresh KametiPool contract ──────────────────────────────────
        KametiPool pool = new KametiPool(
            usdc,
            aavePool,
            vrfCoordinator,
            subscriptionId,
            keyHash,
            cfg,
            feeCollector
        );

        // ── Record and announce ───────────────────────────────────────────────
        poolAddress = address(pool);
        allPools.push(poolAddress);
        poolsByCreator[msg.sender].push(poolAddress);

        emit PoolCreated(poolAddress, msg.sender, _maxMembers, _monthlyAmount);

        return poolAddress;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns addresses of every pool ever created by this factory
    function getAllPools()
        external
        view
        returns (address[] memory)
    {
        return allPools;
    }

    /// @notice Returns all pools created by a specific wallet address
    /// @param  creator The wallet to look up
    function getPoolsByCreator(address creator)
        external
        view
        returns (address[] memory)
    {
        return poolsByCreator[creator];
    }

    /// @notice Returns the total number of pools ever created
    function getTotalPools()
        external
        view
        returns (uint256)
    {
        return allPools.length;
    }

    /// @notice Returns a paginated slice of allPools for efficient frontend loading
    /// @param  offset Starting index (0-based)
    /// @param  limit  Maximum number of pools to return
    function getPoolsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory)
    {
        uint256 total = allPools.length;

        if (offset >= total) return new address[](0);

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256      count = end - offset;
        address[] memory page  = new address[](count);

        for (uint256 i = 0; i < count; i++) {
            page[i] = allPools[offset + i];
        }

        return page;
    }
}
