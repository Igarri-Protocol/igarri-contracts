import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Protocol Phase 1", function () {
  let owner, user, realUSDC, igUSDC, vault, factory, singleton, marketProxy;

  // $50,000 with 18 decimals
  const THRESHOLD = ethers.parseUnits("50000", 18);
  const SCALE_FACTOR = 10n ** 12n;

  before(async function () {
    [owner, user] = await ethers.getSigners();

    // 1. Deploy Mock USDC (6 decimals)
    // Using a basic ERC20 for testing purposes
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", 6);

    // 2. Deploy Core Infrastructure
    const Vault = await ethers.getContractFactory("IgarriVault");
    vault = await Vault.deploy(await realUSDC.getAddress());

    const Factory = await ethers.getContractFactory("IgarriMarketFactory");
    factory = await Factory.deploy();

    const IgUSDC = await ethers.getContractFactory("IgarriUSDC");
    igUSDC = await IgUSDC.deploy(
      owner.address,
      await vault.getAddress(),
      await factory.getAddress(),
    );

    // 3. Setup Permissions (Atomic Linking)
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());
    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());

    const Market = await ethers.getContractFactory("IgarriMarket");
    singleton = await Market.deploy();

    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "BTC-MOON",
      THRESHOLD,
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-1"),
    );
    const receipt = await tx.wait();

    const event = receipt.logs
      .map((log) => {
        try {
          return factory.interface.parseLog(log);
        } catch (e) {
          return null;
        }
      })
      .find((parsedLog) => parsedLog && parsedLog.name === "ProxyDeployed");

    if (!event) throw new Error("ProxyDeployed event not found");

    const proxyAddress = event.args.proxy;
    marketProxy = await ethers.getContractAt("IgarriMarket", proxyAddress);
  });

  it("Should deposit 6-decimal USDC and receive 18-decimal igUSDC", async function () {
    const depositAmount = ethers.parseUnits("100", 6); // $100.00
    await realUSDC.mint(user.address, depositAmount);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), depositAmount);

    await vault.connect(user).deposit(depositAmount);

    const balance = await igUSDC.balanceOf(user.address);
    expect(balance).to.equal(ethers.parseUnits("100", 18));
  });

  it("Should allow buying shares without an igUSDC allowance (Zero Friction)", async function () {
    // 1. Deposit a large enough amount to cover the bonding curve cost
    const depositAmount = ethers.parseUnits("10000", 6); // $10,000
    await realUSDC.mint(user.address, depositAmount);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), depositAmount);
    await vault.connect(user).deposit(depositAmount);

    // 2. Now buy the shares
    const shareAmount = ethers.parseUnits("10", 12);

    const quote = await marketProxy.getQuote(shareAmount);
    console.log(
      "Quote:",
      ethers.formatUnits(quote[0], 18),
      ethers.formatUnits(quote[1], 18),
    );

    await expect(
      marketProxy.connect(user).buyShares(true, shareAmount),
    ).to.emit(marketProxy, "BulkBuy");

    const yesBalance = await (
      await ethers.getContractAt(
        "IgarriOutcomeToken",
        await marketProxy.yesToken(),
      )
    ).balanceOf(user.address);

    expect(yesBalance).to.equal(shareAmount);
  });

  it("Should partially fill and trigger migration when hitting threshold", async function () {
    // 1. Deposit enough to cover the threshold
    const whaleDeposit = ethers.parseUnits("100000", 6); // $100k
    await realUSDC.mint(user.address, whaleDeposit);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), whaleDeposit);
    await vault.connect(user).deposit(whaleDeposit);

    // 2. Buy enough shares to trigger migration
    const bigAmount = ethers.parseUnits("10", 13); // Large enough supply to hit threshold

    // CRITICAL: Await the transaction AND wait for it to be mined
    const tx = await marketProxy.connect(user).buyShares(true, bigAmount);
    await tx.wait(); // This ensures the state is updated before the next line

    const isMigrated = await marketProxy.migrated();
    console.log("Migrated Status:", isMigrated);
    console.log(
      "Total Capital:",
      ethers.formatUnits(await marketProxy.totalCapital(), 18),
    );

    expect(isMigrated).to.be.true;

    // Check real USDC balance of the market
    const marketRealBalance = await realUSDC.balanceOf(
      await marketProxy.getAddress(),
    );
    expect(marketRealBalance).to.be.closeTo(
      ethers.parseUnits("50000", 6),
      ethers.parseUnits("1", 6),
    );
  });
});
