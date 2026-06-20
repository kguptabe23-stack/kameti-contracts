# Kameti — Blockchain Rotating Savings Platform

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![React](https://img.shields.io/badge/React-18-61DAFB)](https://reactjs.org/)
[![Polygon](https://img.shields.io/badge/Network-Polygon%20Amoy-8247E5)](https://polygon.technology/)
[![License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-58%20Passing-brightgreen)]()

> A transparent, trustless, yield-generating Rotating Savings and Credit
> Association (ROSCA) built entirely on the Polygon blockchain.
> Inspired by the traditional Indian **Kameti** savings system.

---

## 🎯 What is Kameti?

Kameti (also known as Chit Fund) is a traditional rotating savings circle
practised by hundreds of millions of people across India. A group of people
each contribute a fixed amount every month — and each month one member
receives the entire pooled amount.

**The Problem with Traditional Kameti:**
- Organiser can run away with funds
- Members can default after receiving payout
- No transparency — only organiser sees records
- Zero returns on pooled money
- No legal protection

**Our Blockchain Solution:**
- Smart contract holds all funds — no human can steal them
- Collateral system prevents defaults
- 100% transparent — every transaction on-chain
- Idle funds earn yield via Aave DeFi protocol
- Self-enforcing — code is the contract

---

## ✨ Key Features

| Feature | Description |
|---------|-------------|
| 🔒 **Trustless** | No organiser needed — smart contracts handle everything |
| 💰 **Yield Generation** | Idle pooled funds deposited into Aave (~8% APY) |
| 🎲 **Fair Rotation** | Chainlink VRF provides provably fair random rotation order |
| 🛡️ **Default Protection** | Collateral slashed automatically if member misses payment |
| 📊 **On-Chain Credit** | Honest participation builds credit score NFT |
| 🏛️ **Governance** | $KMTI token holders vote on protocol upgrades |
| 🌐 **Global Access** | Anyone with a wallet can join from anywhere |

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────┐
│                   FRONTEND (React)                   │
│         Wagmi + Viem + RainbowKit                   │
└─────────────────────┬───────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│              SMART CONTRACTS (Solidity)              │
│                                                      │
│  KametiFactory  ──creates──►  KametiPool            │
│       │                           │                  │
│  KametiToken                 KametiYield             │
│  (Governance)                (Aave Strategy)         │
└─────────────────────────────────────────────────────┘
                      │
┌─────────────────────▼───────────────────────────────┐
│              POLYGON AMOY TESTNET                    │
│                                                      │
│  Chainlink VRF  ──randomness──►  Rotation Order     │
│  Aave V3        ──yield──────►  Member Returns      │
└─────────────────────────────────────────────────────┘
```

---

## 📜 Smart Contracts

### KametiPool.sol
The core contract. Each Kameti group is a separate deployment of this contract.

**Key Functions:**
- `joinPool()` — Join by locking collateral in USDC
- `contribute()` — Pay monthly contribution within window
- `processRound()` — Process payouts after contribution window closes
- `getPoolInfo()` — Read pool state (free, no gas)
- `getMemberInfo()` — Read member state (free, no gas)

### KametiFactory.sol
Deploys new KametiPool contracts. Single entry point for creating pools.

### KametiToken.sol
ERC-20 governance token ($KMTI). Rewards honest participation.
Builds on-chain credit score — higher score = lower collateral required.

### KametiYield.sol
Manages Aave V3 deposits. Idle USDC earns yield distributed to members at cycle end.

---

## 🔐 Security Features

- `ReentrancyGuard` on all state-changing functions
- `AccessControl` for admin and pool roles
- Collateral slashing for defaulters
- Emergency pause and withdrawal functions
- Input validation on all factory parameters
- Chainlink VRF for tamper-proof randomness

---

## 🧪 Test Coverage

```
58 tests passing across 3 test suites

KametiToken (14 tests)
  ✔ Deployment
  ✔ Reward Completion & Credit Score
  ✔ Collateral Discount

KametiPool (34 tests)
  ✔ Deployment
  ✔ Joining Pool
  ✔ Pool Auto-Start — No New Members After Start
  ✔ Contributions
  ✔ Default Handling
  ✔ Process Round & Payout
  ✔ Full Cycle (all 3 rounds)
  ✔ View Functions

KametiFactory (10 tests)
  ✔ Deployment
  ✔ Create Pool
  ✔ Input Validation
  ✔ Pagination
```

---

## 🚀 Deployed Contracts

### Polygon Amoy Testnet

| Contract | Address |
|----------|---------|
| KametiToken | `0xbd11376e2Eaa66B6CA11d249181C471b890803A1` |
| KametiFactory | `0x9F85d6ed462219d5a9A03e0254C83d0a422cf490` |
| KametiYield | `0x8B7186DFa16DF6FCF6e10c8cff853956a7bFe5B8` |

🔍 **[View on Polygonscan](https://amoy.polygonscan.com/address/0x9F85d6ed462219d5a9A03e0254C83d0a422cf490)**

---

## 🛠️ Tech Stack

### Smart Contracts
- **Solidity** 0.8.20
- **OpenZeppelin** v5 (ERC20, AccessControl, ReentrancyGuard)
- **Chainlink VRF** v2 (verifiable randomness)
- **Hardhat** (development framework)
- **Chai + Ethers.js** (testing)

### Frontend
- **React** 18 + Vite
- **Wagmi** v2 (blockchain hooks)
- **Viem** (Ethereum interactions)
- **RainbowKit** (wallet connection)

### Blockchain Infrastructure
- **Polygon** (low gas fees, fast transactions)
- **Aave V3** (yield generation)
- **USDC** (stablecoin — no volatility risk)

---

## 🏃 Running Locally

### Smart Contracts

```bash
# Clone repo
git clone https://github.com/YOUR_USERNAME/kameti-contracts
cd kameti-contracts

# Install dependencies
npm install

# Compile
npx hardhat compile

# Run tests
npx hardhat test

# Deploy to testnet
npx hardhat run ignition/modules/deploy.js --network amoy
```

### Frontend

```bash
# Clone repo
git clone https://github.com/YOUR_USERNAME/kameti-frontend
cd kameti-frontend

# Install dependencies
npm install

# Start dev server
npm run dev

# Open http://localhost:5173
```

---

## 📁 Project Structure

```
kameti-contracts/
├── contracts/
│   ├── KametiPool.sol       # Core pool logic
│   ├── KametiToken.sol      # Governance token
│   ├── KametiFactory.sol    # Pool deployment factory
│   ├── KametiYield.sol      # Aave yield strategy
│   └── Mocks.sol            # Test mock contracts
├── test/
│   └── KametiPool.test.js   # 58 tests
├── ignition/modules/
│   └── deploy.js            # Deployment script
└── hardhat.config.js

kameti-frontend/
├── src/
│   ├── App.jsx              # Main application
│   ├── config/
│   │   ├── wagmi.js         # Wallet configuration
│   │   └── contracts.js     # Contract addresses & ABIs
│   └── abi/                 # Contract ABIs
└── package.json
```

---

## 💡 How It Works

```
1. Creator deploys pool via KametiFactory
         ↓
2. Members join by locking USDC collateral
         ↓
3. Pool fills → Chainlink VRF sets random rotation
         ↓
4. Monthly: all members contribute USDC
         ↓
5. Idle funds deposited to Aave → earn yield
         ↓
6. One member receives the pool pot (- 1% fee)
         ↓
7. Defaulters have collateral slashed automatically
         ↓
8. After all members paid: return collateral + yield
         ↓
9. Members earn $KMTI tokens → build credit score
```

---

## 🗺️ Roadmap

- [x] Smart contract development
- [x] 58 tests passing
- [x] Testnet deployment (Polygon Amoy)
- [x] Frontend with real blockchain connection
- [ ] Security audit (CertiK / Code4rena)
- [ ] Polygon Mainnet launch
- [ ] Mobile app (React Native)
- [ ] $KMTI token launch
- [ ] Multi-chain expansion (Base, BNB Chain)

---

## 👨‍💻 Author

Built from scratch as a full-stack blockchain project demonstrating:
- Solidity smart contract development
- DeFi protocol integration (Aave, Chainlink)
- Full-stack dApp development (React + Wagmi)
- Blockchain deployment and testing

---

## 📄 License

MIT License — see [LICENSE](LICENSE) file.

---

*Traditional savings, reimagined for the blockchain era.*
