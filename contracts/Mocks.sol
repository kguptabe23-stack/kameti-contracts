// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ─────────────────────────────────────────────────────────────────────────────
// MOCK USDC
// A simple ERC20 with a mint function so we can give test wallets free tokens
// ─────────────────────────────────────────────────────────────────────────────

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";  // ← add this

contract MockUSDC is ERC20 {

    uint8 private _decimals = 6; // USDC uses 6 decimals

    constructor() ERC20("USD Coin", "USDC") {}

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    // Anyone can mint in tests — no access control needed
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOCK AAVE POOL
// Simulates Aave supply/withdraw without needing real Aave
// Simply holds the USDC and returns it on withdraw
// In a real test you would add yield simulation — kept simple here
// ─────────────────────────────────────────────────────────────────────────────
contract MockAave {

    address public usdc;
    mapping(address => uint256) public deposited;

    constructor(address _usdc) {
        usdc = _usdc;
    }

    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16
    ) external {
        // Pull USDC from caller
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        deposited[onBehalfOf] += amount;
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 out = amount > bal ? bal : amount;
        if (out > 0) {
            IERC20(asset).transfer(to, out);
        }
        return out;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOCK VRF COORDINATOR
// Simulates Chainlink VRF — immediately returns a fake random number
// so tests don't have to wait for real Chainlink
// ─────────────────────────────────────────────────────────────────────────────
interface IVRFConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external;
}

contract MockVRFCoordinator {

    uint256 private _nextRequestId = 1;

    // Called by KametiPool to request randomness
    function requestRandomWords(
        bytes32,    // keyHash
        uint64,     // subId
        uint16,     // confirmations
        uint32,     // gasLimit
        uint32      // numWords
    ) external returns (uint256 requestId) {
        requestId = _nextRequestId++;

        // Immediately fulfill with a fake random number
        // In real Chainlink this takes a few blocks
        uint256[] memory randomWords = new uint256[](1);
        randomWords[0] = uint256(keccak256(abi.encodePacked(block.timestamp, msg.sender, requestId)));

        IVRFConsumer(msg.sender).rawFulfillRandomWords(requestId, randomWords);

        return requestId;
    }
}


