import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Insurance Fund (Isolated)", function () {
  let owner, factory, market, unauthorized;
  let realUSDC, yieldToken, aavePool, insuranceFund;

  const DECIMALS_USDC = 6n;
  const INITIAL_MARKET_FUNDS = ethers.parseUnits("5000", DECIMALS_USDC); // 5000 USDC

  beforeEach(async function () {
    // 1. Setup Signers
    // We explicitly assign roles to different signers to test access controls
    [owner, factory, market, unauthorized] = await ethers.getSigners();

    // 2. Deploy Mocks (USDC and Aave)
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", DECIMALS_USDC);
    await realUSDC.waitForDeployment();

    yieldToken = await MockUSDC.deploy("Yield aUSDC", "aUSDC", DECIMALS_USDC);
    await yieldToken.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(await yieldToken.getAddress());
    await aavePool.waitForDeployment();

    // 3. Deploy Insurance Fund
    const InsuranceFund = await ethers.getContractFactory(
      "IgarriInsuranceFund",
    );
    insuranceFund = await InsuranceFund.deploy(
      await realUSDC.getAddress(),
      factory.address, // Explicitly set the 'factory' signer as the MarketFactory
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );
    await insuranceFund.waitForDeployment();

    // 4. Fund the "Market" so it has USDC to deposit as fees
    await realUSDC.mint(market.address, INITIAL_MARKET_FUNDS);
  });

  describe("Initialization & Access Control", function () {
    it("Should initialize with correct addresses and 0 assets", async function () {
      expect(await insuranceFund.realUSDC()).to.equal(
        await realUSDC.getAddress(),
      );
      expect(await insuranceFund.marketFactory()).to.equal(factory.address);
      expect(await insuranceFund.totalAssets()).to.equal(0);
    });

    it("Should ONLY allow the Factory to authorize a market", async function () {
      // Unauthorized user fails
      await expect(
        insuranceFund
          .connect(unauthorized)
          .setAllowedMarket(market.address, true),
      ).to.be.revertedWithCustomError(insuranceFund, "Unauthorized");

      // Factory succeeds
      await expect(
        insuranceFund.connect(factory).setAllowedMarket(market.address, true),
      )
        .to.emit(insuranceFund, "MarketAllowed")
        .withArgs(market.address, true);

      expect(await insuranceFund.allowedMarkets(market.address)).to.be.true;
    });

    it("Should NOT allow unauthorized markets to deposit or cover bad debt", async function () {
      const amount = ethers.parseUnits("100", DECIMALS_USDC);

      await expect(
        insuranceFund.connect(unauthorized).depositFee(amount),
      ).to.be.revertedWithCustomError(insuranceFund, "Unauthorized");

      await expect(
        insuranceFund.connect(unauthorized).coverBadDebt(amount),
      ).to.be.revertedWithCustomError(insuranceFund, "Unauthorized");
    });
  });

  describe("Core Functionality: Inflows & Outflows", function () {
    beforeEach(async function () {
      // Authorize the market before testing core functions
      await insuranceFund
        .connect(factory)
        .setAllowedMarket(market.address, true);
    });

    it("Should deposit fee, pull USDC from market, and auto-supply to Aave", async function () {
      const feeAmount = ethers.parseUnits("500", DECIMALS_USDC);

      // Market approves the Insurance Fund to take the fee
      await realUSDC
        .connect(market)
        .approve(await insuranceFund.getAddress(), feeAmount);

      // Market deposits the fee
      await expect(insuranceFund.connect(market).depositFee(feeAmount))
        .to.emit(insuranceFund, "FeeDeposited")
        .withArgs(market.address, feeAmount);

      // Verify Market lost the USDC
      expect(await realUSDC.balanceOf(market.address)).to.equal(
        INITIAL_MARKET_FUNDS - feeAmount,
      );

      // Verify Insurance Fund has 0 raw USDC (it should have forwarded it)
      expect(
        await realUSDC.balanceOf(await insuranceFund.getAddress()),
      ).to.equal(0);

      // Verify Insurance Fund received the aTokens from Aave
      expect(await insuranceFund.totalAssets()).to.equal(feeAmount);
      expect(
        await yieldToken.balanceOf(await insuranceFund.getAddress()),
      ).to.equal(feeAmount);
    });

    it("Should cover bad debt by withdrawing from Aave and sending to Market", async function () {
      // 1. Setup: Deposit 1000 USDC into the insurance fund first
      const depositAmount = ethers.parseUnits("1000", DECIMALS_USDC);
      await realUSDC
        .connect(market)
        .approve(await insuranceFund.getAddress(), depositAmount);
      await insuranceFund.connect(market).depositFee(depositAmount);

      // 2. Market suffers bad debt and needs 300 USDC
      const shortfall = ethers.parseUnits("300", DECIMALS_USDC);

      // Keep track of market's balance before calling coverBadDebt
      const balanceBefore = await realUSDC.balanceOf(market.address);

      // Market calls coverBadDebt
      await expect(insuranceFund.connect(market).coverBadDebt(shortfall))
        .to.emit(insuranceFund, "BadDebtCovered") // <--- Fixed!
        .withArgs(market.address, shortfall);

      // Verify Market received the 300 raw USDC
      const balanceAfter = await realUSDC.balanceOf(market.address);
      expect(balanceAfter - balanceBefore).to.equal(shortfall);

      // Verify Insurance Fund's Aave position decreased by 300
      const expectedRemainingAssets = depositAmount - shortfall;
      expect(await insuranceFund.totalAssets()).to.equal(
        expectedRemainingAssets,
      );
    });

    it("Should revert if bad debt shortfall exceeds available insurance funds", async function () {
      // Setup: Deposit 100 USDC into the insurance fund
      const depositAmount = ethers.parseUnits("100", DECIMALS_USDC);
      await realUSDC
        .connect(market)
        .approve(await insuranceFund.getAddress(), depositAmount);
      await insuranceFund.connect(market).depositFee(depositAmount);

      // Market asks for 500 USDC (exceeds balance)
      const massiveShortfall = ethers.parseUnits("500", DECIMALS_USDC);

      await expect(
        insuranceFund.connect(market).coverBadDebt(massiveShortfall),
      ).to.be.revertedWithCustomError(
        insuranceFund,
        "InsufficientInsuranceFunds",
      );
    });

    it("Should track totalAssets correctly when Aave yield accumulates", async function () {
      // Setup: Deposit 1000 USDC
      const depositAmount = ethers.parseUnits("1000", DECIMALS_USDC);
      await realUSDC
        .connect(market)
        .approve(await insuranceFund.getAddress(), depositAmount);
      await insuranceFund.connect(market).depositFee(depositAmount);

      // Simulate Aave generating 50 USDC in interest
      const interest = ethers.parseUnits("50", DECIMALS_USDC);
      await aavePool.simulateInterest(
        await insuranceFund.getAddress(),
        interest,
      );

      // totalAssets should now be 1050
      const expectedAssets = depositAmount + interest;
      expect(await insuranceFund.totalAssets()).to.equal(expectedAssets);
    });
  });

  describe("Admin Functions", function () {
    it("Should allow the owner to emergency withdraw funds from Aave", async function () {
      // Setup: Authorize market and deposit 1000 USDC
      await insuranceFund
        .connect(factory)
        .setAllowedMarket(market.address, true);
      const depositAmount = ethers.parseUnits("1000", DECIMALS_USDC);
      await realUSDC
        .connect(market)
        .approve(await insuranceFund.getAddress(), depositAmount);
      await insuranceFund.connect(market).depositFee(depositAmount);

      // Ensure Aave has the raw USDC to back the withdrawal
      await realUSDC.mint(await aavePool.getAddress(), depositAmount);

      // Owner initiates emergency withdrawal of 400 USDC to 'unauthorized' address
      const withdrawAmount = ethers.parseUnits("400", DECIMALS_USDC);

      await insuranceFund
        .connect(owner)
        .emergencyWithdraw(unauthorized.address, withdrawAmount);

      // Verify the recipient got the raw USDC
      expect(await realUSDC.balanceOf(unauthorized.address)).to.equal(
        withdrawAmount,
      );

      // Verify Insurance Fund assets decreased
      const expectedRemaining = depositAmount - withdrawAmount;
      expect(await insuranceFund.totalAssets()).to.equal(expectedRemaining);
    });

    it("Should allow the owner to update the Aave pool address", async function () {
      const newAavePool = ethers.Wallet.createRandom().address;

      await expect(insuranceFund.connect(owner).setAavePool(newAavePool))
        .to.emit(insuranceFund, "AavePoolUpdated")
        .withArgs(newAavePool);

      expect(await insuranceFund.aavePool()).to.equal(newAavePool);
    });
  });
});
