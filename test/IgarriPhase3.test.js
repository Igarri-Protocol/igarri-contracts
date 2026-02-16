import { expect } from "chai";
import pkg from "hardhat";
const { ethers, network } = pkg;

describe("Igarri Protocol: Phase 3 (Resolution & Settlement)", function () {
  let owner, lpProvider, phase1Winner, phase2Winner, phase2Loser, whale;
  let serverWallet;
  let realUSDC, yieldToken, aavePool;
  let igUSDC, vault, lendingVault, insuranceFund, factory, market;
  let chainId;

  const DECIMALS_USDC = 6n;
  const SCALE_FACTOR = 10n ** 12n;
  const THRESHOLD = 50_000n * 10n ** DECIMALS_USDC;
  const LP_LIQUIDITY = 500_000n * 10n ** DECIMALS_USDC;

  const UserTier = {
    Standard: 0,
    Early: 1,
    FanToken: 2,
  };

  async function getDomain() {
    return {
      name: "IgarriMarket",
      version: "1",
      chainId: chainId,
      verifyingContract: await market.getAddress(),
    };
  }

  async function signBuyShares(
    signer,
    server,
    buyer,
    isYes,
    amount,
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
    const value = { buyer, isYes, shareAmount: amount, nonce, deadline };
    const userSig = await signer.signTypedData(domain, types, value);
    const serverSig = await server.signTypedData(domain, types, value);
    return { userSig, serverSig };
  }

  async function signOpenPosition(
    signer,
    server,
    trader,
    isYes,
    col,
    lev,
    min,
    nonce,
    deadline,
  ) {
    const domain = await getDomain();
    const types = {
      OpenPosition: [
        { name: "trader", type: "address" },
        { name: "isYes", type: "bool" },
        { name: "collateral", type: "uint256" },
        { name: "leverage", type: "uint256" },
        { name: "minShares", type: "uint256" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const value = {
      trader,
      isYes,
      collateral: col,
      leverage: lev,
      minShares: min,
      nonce,
      deadline,
    };
    const userSig = await signer.signTypedData(domain, types, value);
    const serverSig = await server.signTypedData(domain, types, value);
    return { userSig, serverSig };
  }

  before(async function () {
    [owner, lpProvider, phase1Winner, phase2Winner, phase2Loser, whale] =
      await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;
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

    // 2. Deploy Infrastructure
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

    // 3. Link Permissions
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

    // 4. Deploy Market Proxy
    const Market = await ethers.getContractFactory("IgarriMarket");
    const singleton = await Market.deploy();
    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "ETH-10K",
      THRESHOLD,
      await lendingVault.getAddress(),
      serverWallet.address,
      await insuranceFund.getAddress(),
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-phase3-test"),
    );
    const receipt = await tx.wait();
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

    // 5. Fund Users & LP
    const users = [phase1Winner, phase2Winner, phase2Loser, whale];
    for (let u of users) {
      await realUSDC.mint(u.address, 100_000n * 10n ** 6n);
      await realUSDC
        .connect(u)
        .approve(await vault.getAddress(), ethers.MaxUint256);
      await igUSDC
        .connect(u)
        .approve(await market.getAddress(), ethers.MaxUint256);
    }

    // Setup LP Liquidity
    await realUSDC.mint(lpProvider.address, LP_LIQUIDITY);
    await realUSDC
      .connect(lpProvider)
      .approve(await vault.getAddress(), LP_LIQUIDITY);
    await vault.connect(lpProvider).deposit(LP_LIQUIDITY);
    const lpIgBalance = await igUSDC.balanceOf(lpProvider.address);
    await igUSDC
      .connect(lpProvider)
      .approve(await lendingVault.getAddress(), lpIgBalance);
    await lendingVault.connect(lpProvider).stake(lpIgBalance);
  });

  describe("Setup: Pushing Market to Phase 3", function () {
    it("Should execute Phase 1 buys and migrate", async function () {
      // User 1 buys early YES shares
      let amount = ethers.parseUnits("500", 18);
      let nonce = await market.nonces(phase1Winner.address);
      let deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      let sigs = await signBuyShares(
        phase1Winner,
        serverWallet,
        phase1Winner.address,
        true,
        amount,
        nonce,
        deadline,
      );

      await vault.connect(phase1Winner).deposit(ethers.parseUnits("1000", 6)); // Get igUSDC
      await market
        .connect(phase1Winner)
        .buyShares(
          phase1Winner.address,
          true,
          amount,
          deadline,
          sigs.userSig,
          sigs.serverSig,
        );

      // Whale buys massive amount to trigger migration
      await vault.connect(whale).deposit(ethers.parseUnits("60000", 6));
      amount = ethers.parseUnits("1000000", 18);
      nonce = await market.nonces(whale.address);
      sigs = await signBuyShares(
        whale,
        serverWallet,
        whale.address,
        true,
        amount,
        nonce,
        deadline,
      );

      await market
        .connect(whale)
        .buyShares(
          whale.address,
          true,
          amount,
          deadline,
          sigs.userSig,
          sigs.serverSig,
        );
      expect(await market.phase2Active()).to.be.true;
    });

    it("Should open Phase 2 leveraged positions", async function () {
      const col = ethers.parseUnits("1000", 6);
      const lev = 5n;
      let deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

      // Phase 2 Winner opens LONG YES
      await vault.connect(phase2Winner).deposit(col);
      let nonce = await market.nonces(phase2Winner.address);
      let sigs = await signOpenPosition(
        phase2Winner,
        serverWallet,
        phase2Winner.address,
        true,
        col,
        lev,
        0,
        nonce,
        deadline,
      );
      await market
        .connect(phase2Winner)
        .openPosition(
          phase2Winner.address,
          true,
          col,
          lev,
          0,
          deadline,
          sigs.userSig,
          sigs.serverSig,
        );

      // Phase 2 Loser opens LONG NO
      await vault.connect(phase2Loser).deposit(col);
      nonce = await market.nonces(phase2Loser.address);
      sigs = await signOpenPosition(
        phase2Loser,
        serverWallet,
        phase2Loser.address,
        false,
        col,
        lev,
        0,
        nonce,
        deadline,
      );
      await market
        .connect(phase2Loser)
        .openPosition(
          phase2Loser.address,
          false,
          col,
          lev,
          0,
          deadline,
          sigs.userSig,
          sigs.serverSig,
        );

      // Verify Open Interest (OI) is tracked correctly
      const yesOI = await market.phase2YesOI();
      const noOI = await market.phase2NoOI();
      expect(yesOI).to.be.gt(0);
      expect(noOI).to.be.gt(0);
    });
  });

  describe("Execution: Settlement & Claims", function () {
    it("Should resolve the market to YES and set Price to $1.00", async function () {
      await expect(market.resolveMarket(true))
        .to.emit(market, "MarketResolved")
        .withArgs(true, ethers.parseUnits("1.0", 18)); // Fully solvent payout

      expect(await market.marketResolved()).to.be.true;
      expect(await market.phase2Active()).to.be.false;
    });

    it("Phase 1 Winner should claim 1:1 payout", async function () {
      const yesTokenAddress = await market.yesToken();
      const yesToken = await ethers.getContractAt(
        "IgarriOutcomeToken",
        yesTokenAddress,
      );

      const sharesHeld = await yesToken.balanceOf(phase1Winner.address);
      const expectedPayout6 = sharesHeld / SCALE_FACTOR; // 1 share = 1 USDC ($1)

      const balBefore = await igUSDC.balanceOf(phase1Winner.address);

      await expect(
        market.connect(phase1Winner).claimWinnings(true, UserTier.Standard),
      )
        .to.emit(market, "WinningsClaimed")
        .withArgs(phase1Winner.address, true, expectedPayout6);

      const balAfter = await igUSDC.balanceOf(phase1Winner.address);
      expect(balAfter - balBefore).to.equal(expectedPayout6 * SCALE_FACTOR);
      expect(await yesToken.balanceOf(phase1Winner.address)).to.equal(0);
    });

    it("Phase 2 Winner should claim (Profit - Loan + Multiplied Yield)", async function () {
      const pos = await market.positions(phase2Winner.address, true);

      const balBefore = await igUSDC.balanceOf(phase2Winner.address);

      // Tier: FanToken (2.0x Yield Multiplier)
      await expect(
        market.connect(phase2Winner).claimWinnings(false, UserTier.FanToken),
      ).to.emit(market, "WinningsClaimed");

      const balAfter = await igUSDC.balanceOf(phase2Winner.address);
      const userReceived = balAfter - balBefore;

      // Verify they got their collateral back + profits (since price went up for YES)
      expect(userReceived).to.be.gt(pos.collateral * SCALE_FACTOR);

      // Verify state was cleaned up
      const posAfter = await market.positions(phase2Winner.address, true);
      expect(posAfter.active).to.be.false;
    });

    it("Phase 2 Loser should NOT be able to claim winnings", async function () {
      await expect(
        market.connect(phase2Loser).claimWinnings(false, UserTier.Standard),
      ).to.be.revertedWithCustomError(market, "NoWinningPhase2Position");
    });
  });

  describe("Solvency Guardian (Pro-Rata Settlement)", function () {
    let secondMarket;

    before(async function () {
      // Deploy a second isolated market to test bankruptcy mechanics
      const Market = await ethers.getContractFactory("IgarriMarket");
      const singleton = await Market.deploy();
      const initData = singleton.interface.encodeFunctionData("initialize", [
        await igUSDC.getAddress(),
        await vault.getAddress(),
        "DUMMY-MARKET",
        THRESHOLD,
        await lendingVault.getAddress(),
        serverWallet.address,
        await insuranceFund.getAddress(),
      ]);

      const tx = await factory.deployMarket(
        await singleton.getAddress(),
        initData,
        ethers.id("market-insolvent-test"),
      );
      const receipt = await tx.wait();
      const event = receipt.logs.find((log) => {
        try {
          return factory.interface.parseLog(log).name === "ProxyDeployed";
        } catch (e) {
          return false;
        }
      });
      secondMarket = await ethers.getContractAt(
        "IgarriMarket",
        factory.interface.parseLog(event).args.proxy,
      );

      await realUSDC.mint(whale.address, ethers.parseUnits("60000", 6));
      await igUSDC
        .connect(whale)
        .approve(await secondMarket.getAddress(), ethers.MaxUint256);

      // Trigger migration to fund it with THRESHOLD (50,000 USDC)
      await vault.connect(whale).deposit(ethers.parseUnits("60000", 6));
      let amount = ethers.parseUnits("1000000", 18);
      let nonce = await secondMarket.nonces(whale.address);
      let deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

      // [FIX HERE]: Generate the signature manually for secondMarket
      // instead of using signBuyShares() which is locked to the first market
      const domain = {
        name: "IgarriMarket",
        version: "1",
        chainId: chainId,
        verifyingContract: await secondMarket.getAddress(), // Explicitly target secondMarket
      };

      const types = {
        BuyShares: [
          { name: "buyer", type: "address" },
          { name: "isYes", type: "bool" },
          { name: "shareAmount", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" },
        ],
      };

      const value = {
        buyer: whale.address,
        isYes: true,
        shareAmount: amount,
        nonce,
        deadline,
      };
      const userSig = await whale.signTypedData(domain, types, value);
      const serverSig = await serverWallet.signTypedData(domain, types, value);

      await secondMarket
        .connect(whale)
        .buyShares(whale.address, true, amount, deadline, userSig, serverSig);
    });

    it("Should trigger pro-rata payout if liabilities exceed real USDC", async function () {
      // Impersonate the second market and drain half its physical USDC to simulate an exploit or extreme slippage curve imbalance
      const marketAddr = await secondMarket.getAddress();
      await network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [marketAddr],
      });
      await network.provider.send("hardhat_setBalance", [
        marketAddr,
        "0x10000000000000000000",
      ]);
      const marketSigner = await ethers.getSigner(marketAddr);

      const balance = await realUSDC.balanceOf(marketAddr);
      const halfBalance = balance / 2n;

      // Transfer half the money out to burn address
      await realUSDC
        .connect(marketSigner)
        .transfer("0x000000000000000000000000000000000000dEaD", halfBalance);
      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [marketAddr],
      });

      // Fetch the actual total shares minted by the bonding curve
      const yesTokenAddress = await secondMarket.yesToken();
      const yesToken = await ethers.getContractAt(
        "IgarriOutcomeToken",
        yesTokenAddress,
      );
      const totalShares18 = await yesToken.totalSupply();
      const liabilities6 = totalShares18 / SCALE_FACTOR;

      // Resolve Market. Because we drained half the money, the Solvency Guardian MUST trigger.
      const tx = await secondMarket.resolveMarket(true);
      const receipt = await tx.wait();

      const resolvedEvent = receipt.logs.find(
        (log) => log.eventName === "MarketResolved",
      );
      const settlementPrice = resolvedEvent.args[1];

      // Dynamically calculate what the Solvency Guardian should output
      const expectedSettlementPrice = (halfBalance * 10n ** 18n) / liabilities6;

      // Verify the contract calculated the exact pro-rata price to stay solvent
      expect(settlementPrice).to.equal(expectedSettlementPrice);
      expect(await secondMarket.settlementPrice18()).to.equal(
        expectedSettlementPrice,
      );
    });
  });
});
