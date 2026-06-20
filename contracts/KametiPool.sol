// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// IMPORTS
// NOTE: OpenZeppelin v5 moved ReentrancyGuard from security/ → utils/
// ─────────────────────────────────────────────────────────────────────────────
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

// ─────────────────────────────────────────────────────────────────────────────
// AAVE INTERFACE
// ─────────────────────────────────────────────────────────────────────────────
interface IAave {
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

// ─────────────────────────────────────────────────────────────────────────────
// KAMETI POOL CONTRACT
// ─────────────────────────────────────────────────────────────────────────────
contract KametiPool is ReentrancyGuard, VRFConsumerBaseV2 {

    // ─────────────────────────────────────────────────────────────────────────
    // ENUMS
    // ─────────────────────────────────────────────────────────────────────────

    enum PoolStatus {
        Open,       // Accepting new members — joining IS allowed
        Active,     // Pool is running — joining NOT allowed
        Completed,  // All rounds done — joining NOT allowed
        Paused      // Emergency stop — joining NOT allowed
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STRUCTS
    // ─────────────────────────────────────────────────────────────────────────

    struct Member {
        address wallet;
        uint256 collateral;
        bool    hasPaid;
        bool    hasReceivedPayout;
        bool    isActive;
        uint8   rotationPosition;
        uint256 totalContributed;
    }

    struct PoolConfig {
        uint256 monthlyAmount;
        uint256 maxMembers;
        uint256 collateralBps;
        uint256 contributionWindow;
        uint256 platformFeeBps;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // STATE VARIABLES
    // ─────────────────────────────────────────────────────────────────────────

    IERC20     public usdc;
    IAave      public aavePool;
    PoolConfig public config;
    PoolStatus public status;
    address    public factory;
    address    public feeCollector;

    uint256 public currentRound;
    uint256 public roundStartTime;
    uint256 public totalYieldEarned;

    address[]                   public memberList;
    mapping(address => Member)  public members;
    mapping(uint256 => address) public rotationOrder;

    VRFCoordinatorV2Interface private COORDINATOR;
    uint64  private s_subscriptionId;
    bytes32 private keyHash;
    uint32  private callbackGasLimit     = 200000;
    uint16  private requestConfirmations = 3;
    uint256 public  s_requestId;

    // ─────────────────────────────────────────────────────────────────────────
    // EVENTS
    // ─────────────────────────────────────────────────────────────────────────

    event MemberJoined        (address indexed member,    uint256 collateralLocked);
    event PoolStarted         (uint256 timestamp,         uint256 requestId);
    event RotationSet         (uint8[] rotationOrder);
    event ContributionReceived(address indexed member,    uint256 amount, uint256 round);
    event PayoutSent          (address indexed recipient, uint256 amount, uint256 round);
    event MemberDefaulted     (address indexed member,    uint256 slashedAmount);
    event YieldHarvested      (uint256 amount);
    event PoolCompleted       (uint256 totalYield);

    // ─────────────────────────────────────────────────────────────────────────
    // MODIFIERS
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyStatus(PoolStatus _status) {
        require(status == _status, "Wrong pool status");
        _;
    }

    modifier onlyMember() {
        require(members[msg.sender].isActive, "Not an active member");
        _;
    }

    /// @dev Blocks joining once pool has started — status must be exactly Open
    modifier onlyOpenPool() {
        require(
            status == PoolStatus.Open,
            "Pool is no longer accepting members: Kameti has already started"
        );
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // CONSTRUCTOR
    // ─────────────────────────────────────────────────────────────────────────

    constructor(
        address           _usdc,
        address           _aavePool,
        address           _vrfCoordinator,
        uint64            _subscriptionId,
        bytes32           _keyHash,
        PoolConfig memory _config,
        address           _feeCollector
    ) VRFConsumerBaseV2(_vrfCoordinator) {
        usdc             = IERC20(_usdc);
        aavePool         = IAave(_aavePool);
        COORDINATOR      = VRFCoordinatorV2Interface(_vrfCoordinator);
        s_subscriptionId = _subscriptionId;
        keyHash          = _keyHash;
        config           = _config;
        feeCollector     = _feeCollector;
        factory          = msg.sender;
        status           = PoolStatus.Open;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EXTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function joinPool() external nonReentrant onlyOpenPool {
        require(!members[msg.sender].isActive,         "Already a member of this pool");
        require(memberList.length < config.maxMembers, "Pool is full");

        uint256 totalCycleAmount   = config.monthlyAmount * config.maxMembers;
        uint256 collateralRequired = (totalCycleAmount * config.collateralBps) / 10000;

        usdc.transferFrom(msg.sender, address(this), collateralRequired);

        members[msg.sender] = Member({
            wallet            : msg.sender,
            collateral        : collateralRequired,
            hasPaid           : false,
            hasReceivedPayout : false,
            isActive          : true,
            rotationPosition  : 0,
            totalContributed  : 0
        });

        memberList.push(msg.sender);
        emit MemberJoined(msg.sender, collateralRequired);

        if (memberList.length == config.maxMembers) {
            _startPool();
        }
    }

    function contribute()
        external
        nonReentrant
        onlyMember
        onlyStatus(PoolStatus.Active)
    {
        require(!members[msg.sender].hasPaid, "Already paid for this round");
        require(
            block.timestamp <= roundStartTime + (config.contributionWindow * 1 hours),
            "Contribution window has closed for this round"
        );

        usdc.transferFrom(msg.sender, address(this), config.monthlyAmount);
        members[msg.sender].hasPaid          = true;
        members[msg.sender].totalContributed += config.monthlyAmount;

        emit ContributionReceived(msg.sender, config.monthlyAmount, currentRound);
    }

    function processRound()
        external
        nonReentrant
        onlyStatus(PoolStatus.Active)
    {
        require(
            block.timestamp > roundStartTime + (config.contributionWindow * 1 hours),
            "Contribution window is still open"
        );

        _handleDefaulters();

        uint256 pot         = config.monthlyAmount * memberList.length;
        uint256 platformFee = (pot * config.platformFeeBps) / 10000;
        uint256 payout      = pot - platformFee;

        usdc.transfer(feeCollector, platformFee);

        address recipient = rotationOrder[currentRound];
        usdc.transfer(recipient, payout);
        members[recipient].hasReceivedPayout = true;

        emit PayoutSent(recipient, payout, currentRound);

        _depositToAave();

        if (currentRound == memberList.length) {
            _completeCycle();
        } else {
            currentRound   = currentRound + 1;
            roundStartTime = block.timestamp;
            _resetPaymentFlags();
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // VIEW FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function getPoolInfo()
        external
        view
        returns (
            uint256    memberCount,
            uint256    round,
            PoolStatus poolStatus,
            uint256    nextPayout
        )
    {
        return (
            memberList.length,
            currentRound,
            status,
            config.monthlyAmount * memberList.length
        );
    }

    function getMemberInfo(address _member)
        external
        view
        returns (Member memory)
    {
        return members[_member];
    }

    function isAcceptingMembers() external view returns (bool) {
        return status == PoolStatus.Open && memberList.length < config.maxMembers;
    }

    function spotsRemaining() external view returns (uint256) {
        if (status != PoolStatus.Open) return 0;
        return config.maxMembers - memberList.length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // INTERNAL FUNCTIONS
    // ─────────────────────────────────────────────────────────────────────────

    function _startPool() internal {
        status         = PoolStatus.Active;
        currentRound   = 1;
        roundStartTime = block.timestamp;

        s_requestId = COORDINATOR.requestRandomWords(
            keyHash,
            s_subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            1
        );

        emit PoolStarted(block.timestamp, s_requestId);
    }

    function fulfillRandomWords(
        uint256,
        uint256[] memory randomWords
    ) internal override {
        uint256 randomValue = randomWords[0];
        uint256 n           = memberList.length;

        uint8[] memory order = new uint8[](n);
        for (uint8 i = 0; i < n; i++) order[i] = i;

        for (uint256 i = n - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(randomValue, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }

        for (uint8 i = 0; i < n; i++) {
            rotationOrder[i + 1]                           = memberList[order[i]];
            members[memberList[order[i]]].rotationPosition = i + 1;
        }

        emit RotationSet(order);
    }

    function _handleDefaulters() internal {
        for (uint256 i = 0; i < memberList.length; i++) {
            address m = memberList[i];
            if (members[m].isActive && !members[m].hasPaid) {
                uint256 slash = config.monthlyAmount;
                if (members[m].collateral >= slash) {
                    members[m].collateral -= slash;
                } else {
                    slash                 = members[m].collateral;
                    members[m].collateral = 0;
                    members[m].isActive   = false;
                }
                emit MemberDefaulted(m, slash);
            }
        }
    }

    function _depositToAave() internal {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance > 0) {
            usdc.approve(address(aavePool), balance);
            aavePool.supply(address(usdc), balance, address(this), 0);
        }
    }

    function _completeCycle() internal {
        aavePool.withdraw(address(usdc), type(uint256).max, address(this));

        uint256 finalBalance    = usdc.balanceOf(address(this));
        uint256 totalCollateral = 0;

        for (uint256 i = 0; i < memberList.length; i++) {
            totalCollateral += members[memberList[i]].collateral;
        }

        totalYieldEarned = finalBalance - totalCollateral;

        uint256 n = memberList.length;
        for (uint256 i = 0; i < n; i++) {
            address m          = memberList[i];
            uint256 yieldShare = totalYieldEarned / n;
            uint256 refund     = members[m].collateral + yieldShare;
            usdc.transfer(m, refund);
        }

        status = PoolStatus.Completed;
        emit PoolCompleted(totalYieldEarned);
    }

    function _resetPaymentFlags() internal {
        for (uint256 i = 0; i < memberList.length; i++) {
            members[memberList[i]].hasPaid = false;
        }
    }
}
