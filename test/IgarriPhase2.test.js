import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Protocol: Full Lifecycle (Migration -> Trading -> Liquidation)", function () {
  let owner, user1, user2, keeper;
  let realUSDC, yieldToken, aavePool;
  let igUSDC, vault, lendingVault, factory, market;

  // Constants
  const DECIMALS_USDC = 6n;
  const DECIMALS_IG = 18n;
  const SCALE_FACTOR = 10n ** 12n;

  // 50,000 USDC Migration Threshold
  const MIGRATION_THRESHOLD = 50_000n * 10n ** DECIMALS_USDC;

  // Initial liquidity for Lending Pool (so users can borrow)
  const LP_LIQUIDITY = 1_000_000n * 10n ** DECIMALS_USDC;

  before(async function () {
    [owner, user1, user2, keeper] = await ethers.getSigners();

    // ====================================================
    // 1. DEPLOY MOCKS & CORE CONTRACTS
    // ====================================================

    // Mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", 6);
    yieldToken = await MockUSDC.deploy("Yield aUSDC", "aUSDC", 6);

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(await yieldToken.getAddress());

    // Vault
    const Vault = await ethers.getContractFactory("IgarriVault");
    vault = await Vault.deploy(
      await realUSDC.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );

    // Factory
    const Factory = await ethers.getContractFactory("IgarriMarketFactory");
    factory = await Factory.deploy();

    // igUSDC (Protocol Token)
    const IgUSDC = await ethers.getContractFactory("IgarriUSDC");
    igUSDC = await IgUSDC.deploy(
      owner.address,
      await vault.getAddress(),
      await factory.getAddress(),
    );

    // Lending Vault
    const LendingVault = await ethers.getContractFactory("IgarriLendingVault");
    lendingVault = await LendingVault.deploy(
      await igUSDC.getAddress(),
      await realUSDC.getAddress(),
      await vault.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
      await factory.getAddress(),
    );

    // ====================================================
    // 2. WIRE PERMISSIONS
    // ====================================================

    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress());

    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());
    await factory.setIgarriLendingVault(await lendingVault.getAddress());

    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());

    // ====================================================
    // 3. DEPLOY MARKET (via Factory)
    // ====================================================

    const Market = await ethers.getContractFactory("IgarriMarket");
    const singleton = await Market.deploy();

    // Initialize Arguments: Threshold is passed in 6 decimals (50,000)
    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "TRUMP-2024",
      50_000n * 10n ** DECIMALS_USDC, // Threshold
      await lendingVault.getAddress(),
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-test-v1"),
    );
    const receipt = await tx.wait();

    // Get Proxy Address
    const event = receipt.logs.find((log) => {
      try {
        return factory.interface.parseLog(log).name === "ProxyDeployed";
      } catch (e) {
        return false;
      }
    });
    market = await ethers.getContractAt(
      "IgarriMarket",
      factory.interface.parseLog(event).args.proxy,
    );

    // ====================================================
    // 4. SEED LIQUIDITY
    // ====================================================

    // A. Mint USDC to Users
    await realUSDC.mint(user1.address, 1_000_000n * 10n ** 6n);
    await realUSDC.mint(user2.address, 1_000_000n * 10n ** 6n);
    await realUSDC.mint(owner.address, LP_LIQUIDITY * 2n); // Owner funds the lending pool

    // B. Users Deposit into Vault to get igUSDC
    const depositAmount = 200_000n * 10n ** 6n; // $200k

    await realUSDC
      .connect(user1)
      .approve(await vault.getAddress(), depositAmount);
    await vault.connect(user1).deposit(depositAmount); // User1 has igUSDC

    await realUSDC
      .connect(user2)
      .approve(await vault.getAddress(), depositAmount);
    await vault.connect(user2).deposit(depositAmount); // User2 has igUSDC

    // C. Owner Stakes into Lending Vault (Provide Borrow Liquidity)
    await realUSDC
      .connect(owner)
      .approve(await vault.getAddress(), LP_LIQUIDITY);
    await vault.connect(owner).deposit(LP_LIQUIDITY);

    // Stake the igUSDC into Lending Vault
    const ownerIgBalance = await igUSDC.balanceOf(owner.address);
    await igUSDC
      .connect(owner)
      .approve(await lendingVault.getAddress(), ownerIgBalance);
    await lendingVault.connect(owner).stake(ownerIgBalance);

    // Allow Lending Vault to mint real USDC to Aave (Mock Logic)
    // In mock, `stake` calls `supply`. Ensure mock has balance if needed (Mock mints on transfer)
  });

  // ====================================================
  // TEST SUITE
  // ====================================================

  describe("Step 1: Migration", function () {
    it("Should start in Phase 1 (Bonding Curve)", async function () {
      expect(await market.phase2Active()).to.be.false;
      expect(await market.migrated()).to.be.false;
    });

    it("Should allow bulk buying shares until threshold is hit", async function () {
      // Calculate how much we need to buy to hit $50k
      // Cost ~ 50k. User1 buys massive amount.

      const buyAmount = 500_000n * 10n ** 18n; // Arbitrary large share amount

      await igUSDC
        .connect(user1)
        .approve(await market.getAddress(), ethers.MaxUint256);

      await expect(market.connect(user1).buyShares(true, buyAmount)).to.emit(
        market,
        "Migrated",
      );

      expect(await market.migrated()).to.be.true;
      expect(await market.phase2Active()).to.be.true;
    });

    it("Should initialize Phase 2 with correct Price ($0.50)", async function () {
      // Architecture Requirement: P_start = $0.50
      // vYES = 2 * vUSDC

      const vUSDC = await market.vUSDC();
      const vYES = await market.vYES();
      const vNO = await market.vNO();

      // Check Reserves
      expect(vYES).to.equal(vUSDC * 2n);
      expect(vNO).to.equal(vUSDC * 2n);

      // Check Price (via View Function)
      // Price = vUSDC / vYES = 0.5 * 1e18
      const priceYes = await market.getFunction("getCurrentPrice(bool)")(true);
      const priceNo = await market.getFunction("getCurrentPrice(bool)")(false);

      expect(priceYes).to.equal(ethers.parseUnits("0.5", 18));
      expect(priceNo).to.equal(ethers.parseUnits("0.5", 18));
    });
  });

  describe("Step 2: Dual Position Trading", function () {
    const COLLATERAL = 1000n * 10n ** 6n; // $1000

    it("User1 should open a LONG YES position", async function () {
      // User1 approves Market to spend their igUSDC (Collateral)
      // Note: User1 already approved MaxUint in previous test

      await expect(
        market.connect(user1).openPosition(true, COLLATERAL, 0),
      ).to.emit(market, "PositionOpened");
      // 5x Leverage: 1000 Collat + 4000 Loan
    });

    it("User1 should open a LONG NO position (Dual Position)", async function () {
      // This confirms mapping(address => mapping(bool => ...)) works
      await expect(
        market.connect(user1).openPosition(false, COLLATERAL, 0),
      ).to.emit(market, "PositionOpened");

      // Verify State
      const posYes = await market.positions(user1.address, true);
      const posNo = await market.positions(user1.address, false);

      expect(posYes.active).to.be.true;
      expect(posNo.active).to.be.true;
    });

    it("Should enforce Sum=1 Invariant after trades", async function () {
      // Prices shift after trading
      const priceYes = await market.getFunction("getCurrentPrice(bool)")(true);
      const priceNo = await market.getFunction("getCurrentPrice(bool)")(false);

      // Sum should be ~1.0 (allow tiny rounding error)
      const sum = priceYes + priceNo;
      // 1e18
      expect(sum).to.be.closeTo(ethers.parseUnits("1.0", 18), 1000n); // 1000 wei tolerance
    });
  });

  describe("Step 3: Liquidation Logic", function () {
    // Scenario: User2 pushes YES price up drastically.
    // This crashes NO price.
    // User1's NO position gets liquidated.

    it("User2 pumps YES price to ~0.90", async function () {
      const pumpAmount = 50_000n * 10n ** 6n; // Massive buy
      await igUSDC
        .connect(user2)
        .approve(await market.getAddress(), ethers.MaxUint256);
      await market.connect(user2).openPosition(true, pumpAmount, 0);

      const priceYes = await market.getFunction("getCurrentPrice(bool)")(true);
      // Expect YES > 0.80
      expect(priceYes).to.be.gt(ethers.parseUnits("0.8", 18));
    });

    it("User1's NO position should be unhealthy", async function () {
      // Price NO should be < 0.20
      const priceNo = await market.getFunction("getCurrentPrice(bool)")(false);
      expect(priceNo).to.be.lt(ethers.parseUnits("0.2", 18));

      const healthFactor = await market.getHealthFactor(user1.address, false);
      // Health Factor < 10000 (BPS) implies liquidation
      expect(healthFactor).to.be.lt(10000n);
    });

    it("Keeper should Bulk Liquidate positions", async function () {
      const traders = [user1.address];
      const sides = [false]; // Liquidate User1's NO position

      // Keeper needs no funds, just gas
      await expect(
        market.connect(keeper).bulkLiquidate(traders, sides),
      ).to.emit(market, "PositionLiquidated");

      // Check Reward
      // Keeper should receive some igUSDC reward
      const keeperBal = await igUSDC.balanceOf(keeper.address);
      expect(keeperBal).to.be.gt(0);

      // Verify Position Closed
      const posNo = await market.positions(user1.address, false);
      expect(posNo.active).to.be.false;
    });

    it("User1's YES position should still be active (Isolation)", async function () {
      const posYes = await market.positions(user1.address, true);
      expect(posYes.active).to.be.true;
    });
  });
});
