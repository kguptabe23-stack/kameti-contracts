// ─────────────────────────────────────────────────────────────────────────────
// KAMETI — COMPLETE TEST SUITE (FIXED)
// Run with: npx hardhat test
// ─────────────────────────────────────────────────────────────────────────────

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time }   = require("@nomicfoundation/hardhat-network-helpers");

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

// USDC has 6 decimals  →  5000 USDC = 5_000_000_000
const usdc = (n) => ethers.parseUnits(n.toString(), 6);

// KMTI has 18 decimals
const kmti = (n) => ethers.parseUnits(n.toString(), 18);

// Time helpers
const HOURS = (n) => n * 3600;

// ─────────────────────────────────────────────────────────────────────────────
// SHARED DEPLOY HELPER
// ─────────────────────────────────────────────────────────────────────────────

async function deployAll() {
    const [owner, m1, m2, m3, m4, m5, fee] = await ethers.getSigners();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();

    const MockAave = await ethers.getContractFactory("MockAave");
    const mockAave = await MockAave.deploy(await mockUSDC.getAddress());

    const MockVRF = await ethers.getContractFactory("MockVRFCoordinator");
    const mockVRF = await MockVRF.deploy();

    const poolConfig = {
        monthlyAmount     : usdc(5000),
        maxMembers        : 3,
        collateralBps     : 2000,   // 20% → collateral = 5000*3*20% = 3000 USDC
        contributionWindow: 120,
        platformFeeBps    : 100,
    };

    const KametiPool = await ethers.getContractFactory("KametiPool");
    const pool = await KametiPool.deploy(
        await mockUSDC.getAddress(),
        await mockAave.getAddress(),
        await mockVRF.getAddress(),
        1,
        ethers.ZeroHash,
        poolConfig,
        fee.address
    );

    const KametiToken = await ethers.getContractFactory("KametiToken");
    const token = await KametiToken.deploy();

    // Mint USDC to all signers
    for (const signer of [owner, m1, m2, m3, m4, m5]) {
        await mockUSDC.mint(signer.address, usdc(50000));
    }

    // Pre-fund MockAave so it can always pay withdrawals
    await mockUSDC.mint(await mockAave.getAddress(), usdc(500000));

    return {
        pool, token, mockUSDC, mockAave, mockVRF, poolConfig,
        poolAddr : await pool.getAddress(),
        usdcAddr : await mockUSDC.getAddress(),
        aaveAddr : await mockAave.getAddress(),
        vrfAddr  : await mockVRF.getAddress(),
        owner, m1, m2, m3, m4, m5, fee,
    };
}

// Approve + joinPool for a signer (collateral = 3000 USDC)
async function join(ctx, signer) {
    await ctx.mockUSDC.connect(signer).approve(ctx.poolAddr, usdc(3000));
    await ctx.pool.connect(signer).joinPool();
}

// Fill pool with m1, m2, m3 — triggers auto-start
async function fillPool(ctx) {
    await join(ctx, ctx.m1);
    await join(ctx, ctx.m2);
    await join(ctx, ctx.m3);
}

// All 3 members contribute
async function contributeAll(ctx) {
    for (const signer of [ctx.m1, ctx.m2, ctx.m3]) {
        await ctx.mockUSDC.connect(signer).approve(ctx.poolAddr, usdc(5000));
        await ctx.pool.connect(signer).contribute();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// KAMETITOKEN TESTS
// ─────────────────────────────────────────────────────────────────────────────

describe("KametiToken", function () {

    let token, owner, m1, m2;

    beforeEach(async function () {
        [owner, m1, m2] = await ethers.getSigners();
        const KametiToken = await ethers.getContractFactory("KametiToken");
        token = await KametiToken.deploy();
    });

    describe("Deployment", function () {

        it("correct name and symbol", async function () {
            expect(await token.name()).to.equal("Kameti Token");
            expect(await token.symbol()).to.equal("KMTI");
        });

        it("mints 20M to deployer on launch", async function () {
            expect(await token.balanceOf(owner.address)).to.equal(kmti(20_000_000));
        });

        it("max supply is 100M", async function () {
            expect(await token.MAX_SUPPLY()).to.equal(kmti(100_000_000));
        });

        it("deployer has MINTER_ROLE", async function () {
            const MINTER_ROLE = await token.MINTER_ROLE();
            expect(await token.hasRole(MINTER_ROLE, owner.address)).to.be.true;
        });

    });

    describe("Reward Completion", function () {

        it("mints correct amount to user", async function () {
            await token.rewardCompletion(m1.address, kmti(100));
            expect(await token.balanceOf(m1.address)).to.equal(kmti(100));
        });

        it("increments cyclesCompleted", async function () {
            await token.rewardCompletion(m1.address, kmti(100));
            expect(await token.cyclesCompleted(m1.address)).to.equal(1);
        });

        it("sets credit score to 50 after 1 cycle", async function () {
            await token.rewardCompletion(m1.address, kmti(100));
            expect(await token.creditScore(m1.address)).to.equal(50);
        });

        it("accumulates score: 3 cycles = 150", async function () {
            for (let i = 0; i < 3; i++) {
                await token.rewardCompletion(m1.address, kmti(100));
            }
            expect(await token.creditScore(m1.address)).to.equal(150);
        });

        it("caps score at 1000 regardless of cycles", async function () {
            for (let i = 0; i < 25; i++) {
                await token.rewardCompletion(m1.address, kmti(100));
            }
            expect(await token.creditScore(m1.address)).to.equal(1000);
        });

        it("reverts if non-minter calls rewardCompletion", async function () {
            await expect(
                token.connect(m1).rewardCompletion(m2.address, kmti(100))
            ).to.be.reverted;
        });

        it("reverts if mint would exceed max supply", async function () {
            const current = await token.totalSupply();
            const max     = await token.MAX_SUPPLY();
            const over    = max - current + kmti(1);
            await expect(
                token.rewardCompletion(m1.address, over)
            ).to.be.revertedWith("KametiToken: max supply exceeded");
        });

        it("emits CycleCompleted event", async function () {
            await expect(token.rewardCompletion(m1.address, kmti(100)))
                .to.emit(token, "CycleCompleted")
                .withArgs(m1.address, 1);
        });

        it("emits CreditScoreUpdated event", async function () {
            await expect(token.rewardCompletion(m1.address, kmti(100)))
                .to.emit(token, "CreditScoreUpdated")
                .withArgs(m1.address, 50);
        });

    });

    describe("Collateral Discount", function () {

        it("returns 0 for new user", async function () {
            expect(await token.getCollateralDiscount(m1.address)).to.equal(0);
        });

        it("returns 25 bps after 1 cycle (score=50)", async function () {
            await token.rewardCompletion(m1.address, kmti(100));
            expect(await token.getCollateralDiscount(m1.address)).to.equal(25);
        });

        it("caps discount at 500 bps at max score", async function () {
            for (let i = 0; i < 25; i++) {
                await token.rewardCompletion(m1.address, kmti(100));
            }
            expect(await token.getCollateralDiscount(m1.address)).to.equal(500);
        });

    });

});

// ─────────────────────────────────────────────────────────────────────────────
// KAMETIPOOL TESTS
// ─────────────────────────────────────────────────────────────────────────────

describe("KametiPool", function () {

    let ctx;

    beforeEach(async function () {
        ctx = await deployAll();
    });

    describe("Deployment", function () {

        it("factory is set to deployer", async function () {
            expect(await ctx.pool.factory()).to.equal(ctx.owner.address);
        });

        it("status starts as Open (0)", async function () {
            expect(await ctx.pool.status()).to.equal(0);
        });

        it("feeCollector is set correctly", async function () {
            expect(await ctx.pool.feeCollector()).to.equal(ctx.fee.address);
        });

        it("config stored correctly", async function () {
            const c = await ctx.pool.config();
            expect(c.monthlyAmount).to.equal(usdc(5000));
            expect(c.maxMembers).to.equal(3);
            expect(c.collateralBps).to.equal(2000);
            expect(c.platformFeeBps).to.equal(100);
        });

        it("starts with 0 members", async function () {
            const info = await ctx.pool.getPoolInfo();
            expect(info[0]).to.equal(0);
        });

    });

    describe("Joining Pool", function () {

        it("member can join and collateral is locked", async function () {
            await join(ctx, ctx.m1);
            const info = await ctx.pool.getMemberInfo(ctx.m1.address);
            expect(info.isActive).to.be.true;
            expect(info.collateral).to.equal(usdc(3000));
        });

        it("emits MemberJoined event with correct args", async function () {
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(3000));
            await expect(ctx.pool.connect(ctx.m1).joinPool())
                .to.emit(ctx.pool, "MemberJoined")
                .withArgs(ctx.m1.address, usdc(3000));
        });

        it("rejects duplicate join from same wallet", async function () {
            await join(ctx, ctx.m1);
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(3000));
            await expect(
                ctx.pool.connect(ctx.m1).joinPool()
            ).to.be.revertedWith("Already a member of this pool");
        });

        it("member count increases correctly", async function () {
            await join(ctx, ctx.m1);
            expect((await ctx.pool.getPoolInfo())[0]).to.equal(1);
            await join(ctx, ctx.m2);
            expect((await ctx.pool.getPoolInfo())[0]).to.equal(2);
        });

        it("spotsRemaining decreases as members join", async function () {
            expect(await ctx.pool.spotsRemaining()).to.equal(3);
            await join(ctx, ctx.m1);
            expect(await ctx.pool.spotsRemaining()).to.equal(2);
        });

        it("isAcceptingMembers is true while Open", async function () {
            expect(await ctx.pool.isAcceptingMembers()).to.be.true;
        });

        it("collateral is transferred from member to contract", async function () {
            const before = await ctx.mockUSDC.balanceOf(ctx.m1.address);
            await join(ctx, ctx.m1);
            const after  = await ctx.mockUSDC.balanceOf(ctx.m1.address);
            expect(before - after).to.equal(usdc(3000));
        });

    });

    describe("Pool Auto-Start — No New Members After Start", function () {

        it("auto-starts when last (3rd) member joins", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.status()).to.equal(1); // Active
        });

        it("emits PoolStarted event when last member joins", async function () {
            await join(ctx, ctx.m1);
            await join(ctx, ctx.m2);
            await ctx.mockUSDC.connect(ctx.m3).approve(ctx.poolAddr, usdc(3000));
            await expect(ctx.pool.connect(ctx.m3).joinPool())
                .to.emit(ctx.pool, "PoolStarted");
        });

        it("BLOCKS m4 from joining an Active pool", async function () {
            // Fill with 3 DIFFERENT members — m1, m2, m3
            await join(ctx, ctx.m1);
            await join(ctx, ctx.m2);
            await join(ctx, ctx.m3);
            // Pool is now Active — m4 must be rejected
            await ctx.mockUSDC.connect(ctx.m4).approve(ctx.poolAddr, usdc(3000));
            await expect(
                ctx.pool.connect(ctx.m4).joinPool()
            ).to.be.revertedWith(
                "Pool is no longer accepting members: Kameti has already started"
            );
        });

        it("isAcceptingMembers returns false after pool starts", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.isAcceptingMembers()).to.be.false;
        });

        it("spotsRemaining returns 0 after pool starts", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.spotsRemaining()).to.equal(0);
        });

        it("currentRound is set to 1 after pool starts", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.currentRound()).to.equal(1);
        });

    });

    describe("Contributions", function () {

        beforeEach(async function () {
            await fillPool(ctx);
        });

        it("member can contribute within window", async function () {
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m1).contribute();
            const info = await ctx.pool.getMemberInfo(ctx.m1.address);
            expect(info.hasPaid).to.be.true;
            expect(info.totalContributed).to.equal(usdc(5000));
        });

        it("emits ContributionReceived with correct args", async function () {
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await expect(ctx.pool.connect(ctx.m1).contribute())
                .to.emit(ctx.pool, "ContributionReceived")
                .withArgs(ctx.m1.address, usdc(5000), 1);
        });

        it("rejects double payment in same round", async function () {
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(10000));
            await ctx.pool.connect(ctx.m1).contribute();
            await expect(
                ctx.pool.connect(ctx.m1).contribute()
            ).to.be.revertedWith("Already paid for this round");
        });

        it("rejects contribution after window closes", async function () {
            await time.increase(HOURS(121));
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await expect(
                ctx.pool.connect(ctx.m1).contribute()
            ).to.be.revertedWith("Contribution window has closed for this round");
        });

        it("rejects contribution from non-member", async function () {
            await ctx.mockUSDC.connect(ctx.m4).approve(ctx.poolAddr, usdc(5000));
            await expect(
                ctx.pool.connect(ctx.m4).contribute()
            ).to.be.revertedWith("Not an active member");
        });

        it("USDC transferred from member to pool contract", async function () {
            const before = await ctx.mockUSDC.balanceOf(ctx.m1.address);
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m1).contribute();
            const after  = await ctx.mockUSDC.balanceOf(ctx.m1.address);
            expect(before - after).to.equal(usdc(5000));
        });

    });

    describe("Default Handling", function () {

        beforeEach(async function () {
            await fillPool(ctx);
        });

        it("defaulting member loses all collateral when collateral < monthly", async function () {
            // m1 and m2 pay — m3 does NOT pay
            // m3 collateral = 3000 USDC, monthly = 5000 USDC
            // since collateral(3000) < monthly(5000) → all collateral slashed → ejected
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m1).contribute();
            await ctx.mockUSDC.connect(ctx.m2).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m2).contribute();

            await time.increase(HOURS(121));
            await ctx.pool.processRound();

            const info = await ctx.pool.getMemberInfo(ctx.m3.address);
            expect(info.collateral).to.equal(0);       // all gone
            expect(info.isActive).to.be.false;          // ejected
        });

        it("emits MemberDefaulted event for non-paying member", async function () {
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m1).contribute();
            await ctx.mockUSDC.connect(ctx.m2).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m2).contribute();

            await time.increase(HOURS(121));
            await expect(ctx.pool.processRound())
                .to.emit(ctx.pool, "MemberDefaulted")
                .withArgs(ctx.m3.address, usdc(3000));
        });

        it("member with collateral > monthly loses exactly monthlyAmount", async function () {
            // Deploy pool where collateral(3000) > monthly(1000)
            // monthly=1000, maxMembers=3, collateral=100% → 1000*3*100%=3000 USDC
            const bigConfig = {
                monthlyAmount     : usdc(1000),
                maxMembers        : 3,
                collateralBps     : 10000, // 100%
                contributionWindow: 120,
                platformFeeBps    : 100,
            };
            const KametiPool = await ethers.getContractFactory("KametiPool");
            const bigPool    = await KametiPool.deploy(
                ctx.usdcAddr, ctx.aaveAddr, ctx.vrfAddr,
                1, ethers.ZeroHash, bigConfig, ctx.fee.address
            );
            const bigAddr = await bigPool.getAddress();

            // collateral = 3000 USDC each
            for (const signer of [ctx.m1, ctx.m2, ctx.m3]) {
                await ctx.mockUSDC.connect(signer).approve(bigAddr, usdc(3000));
                await bigPool.connect(signer).joinPool();
            }

            // m1 and m2 pay 1000 each, m3 defaults
            for (const signer of [ctx.m1, ctx.m2]) {
                await ctx.mockUSDC.connect(signer).approve(bigAddr, usdc(1000));
                await bigPool.connect(signer).contribute();
            }

            const before = (await bigPool.getMemberInfo(ctx.m3.address)).collateral;
            await time.increase(HOURS(121));
            await bigPool.processRound();
            const after  = (await bigPool.getMemberInfo(ctx.m3.address)).collateral;

            // collateral(3000) >= monthly(1000) → slashed exactly 1000, stays active
            expect(before - after).to.equal(usdc(1000));
            expect((await bigPool.getMemberInfo(ctx.m3.address)).isActive).to.be.true;
        });

    });

    describe("Process Round", function () {

        beforeEach(async function () {
            await fillPool(ctx);
        });

        it("reverts if window is still open", async function () {
            await expect(ctx.pool.processRound())
                .to.be.revertedWith("Contribution window is still open");
        });

        it("sends 1% platform fee to feeCollector", async function () {
            await contributeAll(ctx);
            const before = await ctx.mockUSDC.balanceOf(ctx.fee.address);
            await time.increase(HOURS(121));
            await ctx.pool.processRound();
            const after  = await ctx.mockUSDC.balanceOf(ctx.fee.address);
            // pot = 5000*3 = 15000, fee = 1% = 150 USDC
            expect(after - before).to.equal(usdc(150));
        });

        it("emits PayoutSent event", async function () {
            await contributeAll(ctx);
            await time.increase(HOURS(121));
            await expect(ctx.pool.processRound())
                .to.emit(ctx.pool, "PayoutSent");
        });

        it("advances currentRound after processing", async function () {
            await contributeAll(ctx);
            await time.increase(HOURS(121));
            await ctx.pool.processRound();
            expect(await ctx.pool.currentRound()).to.equal(2);
        });

        it("resets hasPaid for all members after round", async function () {
            await contributeAll(ctx);
            await time.increase(HOURS(121));
            await ctx.pool.processRound();
            for (const signer of [ctx.m1, ctx.m2, ctx.m3]) {
                const info = await ctx.pool.getMemberInfo(signer.address);
                expect(info.hasPaid).to.be.false;
            }
        });

        it("exactly one member receives payout per round", async function () {
            await contributeAll(ctx);
            const before1 = await ctx.mockUSDC.balanceOf(ctx.m1.address);
            const before2 = await ctx.mockUSDC.balanceOf(ctx.m2.address);
            const before3 = await ctx.mockUSDC.balanceOf(ctx.m3.address);

            await time.increase(HOURS(121));
            await ctx.pool.processRound();

            const gain1 = (await ctx.mockUSDC.balanceOf(ctx.m1.address)) - before1;
            const gain2 = (await ctx.mockUSDC.balanceOf(ctx.m2.address)) - before2;
            const gain3 = (await ctx.mockUSDC.balanceOf(ctx.m3.address)) - before3;

            const nonZero = [gain1, gain2, gain3].filter(g => g > 0n);
            expect(nonZero.length).to.equal(1);
            expect(nonZero[0]).to.equal(usdc(14850)); // 15000 - 1% fee
        });

        it("marks recipient hasReceivedPayout after round", async function () {
            await contributeAll(ctx);
            await time.increase(HOURS(121));
            await ctx.pool.processRound();

            const received = await Promise.all(
                [ctx.m1, ctx.m2, ctx.m3].map(async s =>
                    (await ctx.pool.getMemberInfo(s.address)).hasReceivedPayout
                )
            );
            expect(received.filter(r => r === true).length).to.equal(1);
        });

    });

    describe("Full Cycle (all 3 rounds)", function () {

        it("completes all 3 rounds and emits PoolCompleted", async function () {
            await fillPool(ctx);
            for (let i = 0; i < 2; i++) {
                await contributeAll(ctx);
                await time.increase(HOURS(121));
                await ctx.pool.processRound();
            }
            // Last round
            await contributeAll(ctx);
            await time.increase(HOURS(121));
            await expect(ctx.pool.processRound())
                .to.emit(ctx.pool, "PoolCompleted");
        });

        it("all 3 members receive payout exactly once", async function () {
            await fillPool(ctx);
            for (let i = 0; i < 3; i++) {
                await contributeAll(ctx);
                await time.increase(HOURS(121));
                await ctx.pool.processRound();
            }
            const received = await Promise.all(
                [ctx.m1, ctx.m2, ctx.m3].map(async s =>
                    (await ctx.pool.getMemberInfo(s.address)).hasReceivedPayout
                )
            );
            expect(received.every(r => r === true)).to.be.true;
        });

        it("status changes to Completed (2) after last round", async function () {
            await fillPool(ctx);
            for (let i = 0; i < 3; i++) {
                await contributeAll(ctx);
                await time.increase(HOURS(121));
                await ctx.pool.processRound();
            }
            expect(await ctx.pool.status()).to.equal(2);
        });

    });

    describe("View Functions", function () {

        it("getPoolInfo memberCount is correct", async function () {
            await join(ctx, ctx.m1);
            expect((await ctx.pool.getPoolInfo())[0]).to.equal(1);
        });

        it("getPoolInfo status is Open before fill", async function () {
            expect((await ctx.pool.getPoolInfo())[2]).to.equal(0);
        });

        it("getMemberInfo returns correct wallet", async function () {
            await join(ctx, ctx.m1);
            const info = await ctx.pool.getMemberInfo(ctx.m1.address);
            expect(info.wallet).to.equal(ctx.m1.address);
        });

        it("getMemberInfo hasPaid false before contributing", async function () {
            await fillPool(ctx);
            expect((await ctx.pool.getMemberInfo(ctx.m1.address)).hasPaid).to.be.false;
        });

        it("getMemberInfo hasPaid true after contributing", async function () {
            await fillPool(ctx);
            await ctx.mockUSDC.connect(ctx.m1).approve(ctx.poolAddr, usdc(5000));
            await ctx.pool.connect(ctx.m1).contribute();
            expect((await ctx.pool.getMemberInfo(ctx.m1.address)).hasPaid).to.be.true;
        });

        it("isAcceptingMembers true when Open with space", async function () {
            expect(await ctx.pool.isAcceptingMembers()).to.be.true;
        });

        it("isAcceptingMembers false when Active", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.isAcceptingMembers()).to.be.false;
        });

        it("spotsRemaining max when empty", async function () {
            expect(await ctx.pool.spotsRemaining()).to.equal(3);
        });

        it("spotsRemaining 0 when Active", async function () {
            await fillPool(ctx);
            expect(await ctx.pool.spotsRemaining()).to.equal(0);
        });

    });

});

// ─────────────────────────────────────────────────────────────────────────────
// KAMETIFACTORY TESTS
// ─────────────────────────────────────────────────────────────────────────────

describe("KametiFactory", function () {

    let ctx, factory;

    beforeEach(async function () {
        ctx = await deployAll();
        const KametiFactory = await ethers.getContractFactory("KametiFactory");
        factory = await KametiFactory.deploy(
            ctx.vrfAddr, ctx.aaveAddr, ctx.usdcAddr,
            1, ethers.ZeroHash, ctx.fee.address
        );
    });

    describe("Deployment", function () {

        it("stores correct USDC address", async function () {
            expect(await factory.usdc()).to.equal(ctx.usdcAddr);
        });

        it("stores correct Aave address", async function () {
            expect(await factory.aavePool()).to.equal(ctx.aaveAddr);
        });

        it("stores correct feeCollector", async function () {
            expect(await factory.feeCollector()).to.equal(ctx.fee.address);
        });

        it("starts with 0 pools", async function () {
            expect(await factory.getTotalPools()).to.equal(0);
        });

    });

    describe("Create Pool", function () {

        it("deploys pool and increments count", async function () {
            await factory.createPool(usdc(5000), 10, 2000, 120, 100);
            expect(await factory.getTotalPools()).to.equal(1);
        });

        it("emits PoolCreated event", async function () {
            await expect(factory.createPool(usdc(5000), 10, 2000, 120, 100))
                .to.emit(factory, "PoolCreated");
        });

        it("records pool under creator address", async function () {
            await factory.createPool(usdc(5000), 10, 2000, 120, 100);
            const pools = await factory.getPoolsByCreator(ctx.owner.address);
            expect(pools.length).to.equal(1);
        });

        it("getAllPools returns all deployed addresses", async function () {
            await factory.createPool(usdc(5000), 10, 2000, 120, 100);
            await factory.createPool(usdc(2000), 5,  2000, 120, 100);
            expect((await factory.getAllPools()).length).to.equal(2);
        });

    });

    describe("Input Validation", function () {

        it("rejects monthly amount of 0", async function () {
            await expect(factory.createPool(0, 10, 2000, 120, 100))
                .to.be.revertedWith("KametiFactory: monthly amount must be > 0");
        });

        it("rejects pool with 1 member", async function () {
            await expect(factory.createPool(usdc(5000), 1, 2000, 120, 100))
                .to.be.revertedWith("KametiFactory: pool must have at least 2 members");
        });

        it("rejects pool with 101 members", async function () {
            await expect(factory.createPool(usdc(5000), 101, 2000, 120, 100))
                .to.be.revertedWith("KametiFactory: pool cannot exceed 100 members");
        });

        it("rejects collateral above 50%", async function () {
            await expect(factory.createPool(usdc(5000), 10, 5001, 120, 100))
                .to.be.revertedWith("KametiFactory: collateral cannot exceed 50%");
        });

        it("rejects window less than 24 hours", async function () {
            await expect(factory.createPool(usdc(5000), 10, 2000, 23, 100))
                .to.be.revertedWith("KametiFactory: window must be at least 24 hours");
        });

        it("rejects platform fee above 5%", async function () {
            await expect(factory.createPool(usdc(5000), 10, 2000, 120, 501))
                .to.be.revertedWith("KametiFactory: platform fee cannot exceed 5%");
        });

        it("accepts minimum valid values", async function () {
            await expect(
                factory.createPool(usdc(100), 2, 0, 24, 0)
            ).to.not.be.reverted;
        });

        it("accepts maximum valid values", async function () {
            await expect(
                factory.createPool(usdc(100), 100, 5000, 24, 500)
            ).to.not.be.reverted;
        });

    });

    describe("Pagination", function () {

        beforeEach(async function () {
            for (let i = 0; i < 5; i++) {
                await factory.createPool(usdc(1000 * (i + 1)), 3, 2000, 120, 100);
            }
        });

        it("returns correct first page of 3", async function () {
            expect((await factory.getPoolsPaginated(0, 3)).length).to.equal(3);
        });

        it("returns correct second page (2 remaining)", async function () {
            expect((await factory.getPoolsPaginated(3, 3)).length).to.equal(2);
        });

        it("returns empty array for out-of-bounds offset", async function () {
            expect((await factory.getPoolsPaginated(100, 10)).length).to.equal(0);
        });

        it("limit larger than remaining returns only what exists", async function () {
            expect((await factory.getPoolsPaginated(4, 100)).length).to.equal(1);
        });

        it("getTotalPools returns 5", async function () {
            expect(await factory.getTotalPools()).to.equal(5);
        });

    });

});