import { expect } from "chai";
import pkg from "hardhat";
const { ethers, network } = pkg;

describe("Igarri Protocol Phase 1 (Aave Integration)", function () {
  let owner, user, serverWallet;
  let realUSDC, yieldToken, aavePool;
  let igUSDC,
    vault,
    lendingVault,
    insuranceFund,
    factory,
    singleton,
    marketProxy;
  let chainId;

  // Set to 50,000 USDC (6 decimals). The contract will multiply by SCALE_FACTOR internally.
  const THRESHOLD = 50_000n * 10n ** 6n;

  // --- EIP-712 HELPERS ---
  async function getDomain() {
    return {
      name: "IgarriMarket",
      version: "1",
      chainId: chainId,
      verifyingContract: await marketProxy.getAddress(),
    };
  }

  async function signBuyShares(
    signerWallet,
    serverWallet,
    buyer,
    isYes,
    shareAmount,
    nonce,
    deadline,
  ) {
    const domain = await getDomain();
    const types = {
      BuyShares: [
        { name: "buyer", type: "address" },
        { name: "isYes", type: "bool" },
        { name: "shareAmount", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };

    const value = { buyer, isYes, shareAmount, nonce, deadline };

    const userSig = await signerWallet.signTypedData(domain, types, value);
    const serverSig = await serverWallet.signTypedData(domain, types, value);

    return { userSig, serverSig };
  }

  before(async function () {
    [owner, user] = await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;

    // Setup the mock server wallet for signing
    serverWallet = new ethers.Wallet(
      "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
      ethers.provider,
    );

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

    // 3. Deploy Missing Dependencies for New Architecture
    const LendingVault = await ethers.getContractFactory("IgarriLendingVault");
    lendingVault = await LendingVault.deploy(
      await igUSDC.getAddress(),
      await realUSDC.getAddress(),
      await vault.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
      await factory.getAddress(),
    );

    const InsuranceFund = await ethers.getContractFactory(
      "IgarriInsuranceFund",
    );
    insuranceFund = await InsuranceFund.deploy(
      await realUSDC.getAddress(),
      await factory.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );

    // 4. Link Dependencies & Permissions
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress());

    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());
    await factory.setIgarriLendingVault(await lendingVault.getAddress());
    await factory.setIgarriInsuranceFund(await insuranceFund.getAddress());

    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());

    // Impersonate Factory to authorize lending vault on Insurance Fund
    const factoryAddress = await factory.getAddress();
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [factoryAddress],
    });
    await network.provider.send("hardhat_setBalance", [
      factoryAddress,
      "0x10000000000000000000",
    ]);
    const factorySigner = await ethers.getSigner(factoryAddress);
    await insuranceFund
      .connect(factorySigner)
      .setAllowedMarket(await lendingVault.getAddress(), true);
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [factoryAddress],
    });

    // 5. Deploy Market Singleton and Proxy
    const Market = await ethers.getContractFactory("IgarriMarket");
    singleton = await Market.deploy();

    // UPDATED: Include all 7 arguments required by the new initialize function
    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "BTC-MOON",
      THRESHOLD,
      await lendingVault.getAddress(),
      serverWallet.address,
      await insuranceFund.getAddress(),
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-v1"),
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

    expect(await vault.totalRealUSDCInVault()).to.equal(amount);
    expect(await realUSDC.balanceOf(await aavePool.getAddress())).to.equal(
      amount,
    );
    expect(await yieldToken.balanceOf(await vault.getAddress())).to.equal(
      amount,
    );
  });

  it("Should buy shares and maintain bonding curve capital", async function () {
    const buyAmount = ethers.parseUnits("10", 10);

    // User must approve the market to pull their igUSDC
    await igUSDC
      .connect(user)
      .approve(await marketProxy.getAddress(), ethers.MaxUint256);

    // --- Generate EIP-712 Signatures ---
    const nonce = await marketProxy.nonces(user.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const { userSig, serverSig } = await signBuyShares(
      user,
      serverWallet,
      user.address,
      true,
      buyAmount,
      nonce,
      deadline,
    );

    // Execute the signed transaction
    await expect(
      marketProxy
        .connect(user)
        .buyShares(user.address, true, buyAmount, deadline, userSig, serverSig),
    ).to.emit(marketProxy, "BulkBuy");

    expect(await marketProxy.currentSupply()).to.equal(buyAmount);
  });

  it("Should harvest yields when interest is simulated", async function () {
    const interest = ethers.parseUnits("50", 6); // $50 profit
    await aavePool.simulateInterest(await vault.getAddress(), interest);

    const initialTreasuryBalance = await realUSDC.balanceOf(owner.address);

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

    // 2. Generate signatures for a massive buy to trigger migration
    const bigAmount = ethers.parseUnits("2000000", 18);
    const nonce = await marketProxy.nonces(user.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

    const { userSig, serverSig } = await signBuyShares(
      user,
      serverWallet,
      user.address,
      true,
      bigAmount,
      nonce,
      deadline,
    );

    // 3. Execute the buy
    await marketProxy
      .connect(user)
      .buyShares(user.address, true, bigAmount, deadline, userSig, serverSig);

    // Verify Migration Success
    expect(await marketProxy.migrated()).to.be.true;

    // Verify market proxy now holds the real USDC (withdrawn from Aave during migration)
    const marketBalance = await realUSDC.balanceOf(
      await marketProxy.getAddress(),
    );
    expect(marketBalance).to.be.at.least(THRESHOLD);
  });
});
