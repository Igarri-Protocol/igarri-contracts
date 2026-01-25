import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Protocol Phase 1 (Aave Integration)", function () {
  let owner,
    user,
    realUSDC,
    yieldToken,
    aavePool,
    igUSDC,
    vault,
    factory,
    singleton,
    marketProxy;

  const THRESHOLD = ethers.parseUnits("50000", 18);

  before(async function () {
    [owner, user] = await ethers.getSigners();

    // 1. Deploy Mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", 6);
    yieldToken = await MockUSDC.deploy("Yield aUSDC", "aUSDC", 6);

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(await yieldToken.getAddress());

    // 2. Deploy Core Infrastructure
    const Vault = await ethers.getContractFactory("IgarriVault");
    vault = await Vault.deploy(
      await realUSDC.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );

    const Factory = await ethers.getContractFactory("IgarriMarketFactory");
    factory = await Factory.deploy();

    const IgUSDC = await ethers.getContractFactory("IgarriUSDC");
    igUSDC = await IgUSDC.deploy(
      owner.address,
      await vault.getAddress(),
      await factory.getAddress(),
    );

    // 3. Link Dependencies & Permissions
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());
    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());

    // 4. Deploy Market Singleton and Proxy
    const Market = await ethers.getContractFactory("IgarriMarket");
    singleton = await Market.deploy();

    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "BTC-MOON",
      THRESHOLD,
      await aavePool.getAddress(), // New parameter
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-v1"),
    );
    const receipt = await tx.wait();

    // Find Proxy address from logs
    const event = receipt.logs
      .map((log) => {
        try {
          return factory.interface.parseLog(log);
        } catch (e) {
          return null;
        }
      })
      .find((p) => p && p.name === "ProxyDeployed");

    marketProxy = await ethers.getContractAt("IgarriMarket", event.args.proxy);
  });

  it("Should deposit USDC, mint igUSDC, and supply to Aave", async function () {
    const amount = ethers.parseUnits("1000", 6);
    await realUSDC.mint(user.address, amount);
    await realUSDC.connect(user).approve(await vault.getAddress(), amount);

    await expect(vault.connect(user).deposit(amount)).to.emit(
      vault,
      "Deposited",
    );

    // Check Vault tracking
    expect(await vault.totalRealUSDCInVault()).to.equal(amount);

    // Check Aave Mock received the funds
    expect(await realUSDC.balanceOf(await aavePool.getAddress())).to.equal(
      amount,
    );

    // Check Vault received yield tokens (aTokens)
    expect(await yieldToken.balanceOf(await vault.getAddress())).to.equal(
      amount,
    );
  });

  it("Should buy shares and maintain bonding curve capital", async function () {
    const buyAmount = ethers.parseUnits("10", 10);
    // User already has igUSDC from previous test deposit

    await expect(marketProxy.connect(user).buyShares(true, buyAmount)).to.emit(
      marketProxy,
      "BulkBuy",
    );

    expect(await marketProxy.currentSupply()).to.equal(buyAmount);
  });

  it("Should harvest yields when interest is simulated", async function () {
    const interest = ethers.parseUnits("50", 6); // $50 profit
    await aavePool.simulateInterest(await vault.getAddress(), interest);

    const initialTreasuryBalance = await realUSDC.balanceOf(owner.address);

    // Withdraw yields to owner
    await vault.withdrawYields(owner.address);

    const finalTreasuryBalance = await realUSDC.balanceOf(owner.address);
    expect(finalTreasuryBalance - initialTreasuryBalance).to.equal(interest);
  });

  it("Should migrate capital from Aave to Market when threshold is hit", async function () {
    // 1. Large deposit to ensure vault has liquidity
    const whaleDeposit = ethers.parseUnits("60000", 6);
    await realUSDC.mint(user.address, whaleDeposit);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), whaleDeposit);
    await vault.connect(user).deposit(whaleDeposit);

    // 2. Buy enough to hit threshold
    const bigAmount = ethers.parseUnits("2000000", 18);
    await marketProxy.connect(user).buyShares(true, bigAmount);

    expect(await marketProxy.migrated()).to.be.true;

    // Verify market proxy now holds the real USDC (withdrawn from Aave during migration)
    const marketBalance = await realUSDC.balanceOf(
      await marketProxy.getAddress(),
    );

    expect(marketBalance).to.be.at.least(ethers.parseUnits("50000", 6));
  });
});
