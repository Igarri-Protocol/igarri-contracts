import { expect } from "chai";
import pkg from "hardhat";
const { ethers, network } = pkg;

describe("Igarri Oracle & Settlement Integration", function () {
  let owner, user1, user2, serverSigner, arbitrator;
  let realUSDC,
    igUSDC,
    vault,
    lendingVault,
    insuranceFund,
    factory,
    marketSingleton;
  let mockRealityETH, mathLib, signatureLib;

  const DECIMALS_USDC = 6n;
  const SCALE_FACTOR = 10n ** 12n;
  const BPS = 10000n;

  // --- Signature Helpers ---

  async function getDomain(verifyingContract) {
    return {
      name: "IgarriMarket",
      version: "1",
      chainId: (await ethers.provider.getNetwork()).chainId,
      verifyingContract: verifyingContract,
    };
  }

  // @audit Helper now takes the full user signer object and returns both sigs
  async function signBuy(market, userSigner, isYes, amount, nonce, deadline) {
    const domain = await getDomain(market);
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
      buyer: userSigner.address,
      isYes,
      shareAmount: amount,
      nonce,
      deadline,
    };

    const userSig = await userSigner.signTypedData(domain, types, value);
    const serverSig = await serverSigner.signTypedData(domain, types, value);

    return { userSig, serverSig };
  }

  async function signClaim(market, userAddress, tier, nonce, deadline) {
    const domain = await getDomain(market);
    const types = {
      ClaimTier: [
        { name: "user", type: "address" },
        { name: "tier", type: "uint8" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint256" },
      ],
    };
    const value = { user: userAddress, tier, nonce, deadline };
    return await serverSigner.signTypedData(domain, types, value);
  }

  // --- Deployment Setup ---

  beforeEach(async function () {
    [owner, user1, user2, serverSigner, arbitrator] = await ethers.getSigners();

    // 1. Deploy Libraries
    mathLib = await (await ethers.getContractFactory("IgarriMathLib")).deploy();
    signatureLib = await (
      await ethers.getContractFactory("IgarriSignatureLib")
    ).deploy();

    // 2. Deploy Mocks
    const MockReality = await ethers.getContractFactory("MockRealityETH");
    mockRealityETH = await MockReality.deploy();

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("USD Coin", "USDC", 6);

    const MockAave = await ethers.getContractFactory("MockAavePool");
    const aUSDC = await MockUSDC.deploy("aUSDC", "aUSDC", 6);
    const aavePool = await MockAave.deploy(await aUSDC.getAddress());

    // 3. DEPLOY FACTORY FIRST
    const Factory = await ethers.getContractFactory("IgarriMarketFactory");
    factory = await Factory.deploy();

    // 4. Deploy Infrastructure
    const Vault = await ethers.getContractFactory("IgarriVault");
    vault = await Vault.deploy(
      await realUSDC.getAddress(),
      await aavePool.getAddress(),
      await aUSDC.getAddress(),
    );

    const IgUSDC = await ethers.getContractFactory("IgarriUSDC");
    igUSDC = await IgUSDC.deploy(
      owner.address,
      await vault.getAddress(),
      await factory.getAddress(),
    );

    const Insurance = await ethers.getContractFactory("IgarriInsuranceFund");
    insuranceFund = await Insurance.deploy(
      await realUSDC.getAddress(),
      await factory.getAddress(),
      await aavePool.getAddress(),
      await aUSDC.getAddress(),
    );

    const Lending = await ethers.getContractFactory("IgarriLendingVault");
    lendingVault = await Lending.deploy(
      await igUSDC.getAddress(),
      await realUSDC.getAddress(),
      await vault.getAddress(),
      await aavePool.getAddress(),
      await aUSDC.getAddress(),
      await factory.getAddress(),
    );

    // 5. Configure Factory in Infrastructure
    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());
    await factory.setIgarriLendingVault(await lendingVault.getAddress());
    await factory.setIgarriInsuranceFund(await insuranceFund.getAddress());

    const Market = await ethers.getContractFactory("IgarriMarket", {
      libraries: {
        IgarriMathLib: await mathLib.getAddress(),
        IgarriSignatureLib: await signatureLib.getAddress(),
      },
    });
    marketSingleton = await Market.deploy();

    // 6. Final Plumbing
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());

    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());

    // Impersonate Factory to set lending vault in insurance fund
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [await factory.getAddress()],
    });
    await network.provider.send("hardhat_setBalance", [
      await factory.getAddress(),
      "0x10000000000000000000",
    ]);
    const factorySigner = await ethers.getSigner(await factory.getAddress());
    await insuranceFund
      .connect(factorySigner)
      .setAllowedMarket(await lendingVault.getAddress(), true);
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [await factory.getAddress()],
    });
  });

  async function setupMarket(thresholdUSDC) {
    const salt = ethers.randomBytes(32);
    const predictedAddr = await factory.calculateProxyAddress(
      await marketSingleton.getAddress(),
      salt,
    );

    const Token = await ethers.getContractFactory("IgarriOutcomeToken");
    const yesToken = await Token.deploy("YES", "YES", predictedAddr);
    const noToken = await Token.deploy("NO", "NO", predictedAddr);

    const initData = marketSingleton.interface.encodeFunctionData(
      "initialize",
      [
        await igUSDC.getAddress(),
        await vault.getAddress(),
        thresholdUSDC,
        await lendingVault.getAddress(),
        serverSigner.address,
        await insuranceFund.getAddress(),
        (await ethers.provider.getBlock("latest")).timestamp + 86400,
        await mockRealityETH.getAddress(),
        arbitrator.address,
        3600,
        "Will it rain?",
        await yesToken.getAddress(),
        await noToken.getAddress(),
      ],
    );

    await factory.deployMarket(
      await marketSingleton.getAddress(),
      initData,
      salt,
    );
    return {
      market: await ethers.getContractAt("IgarriMarket", predictedAddr),
      yes: yesToken,
      no: noToken,
    };
  }

  async function fundUserWithIgUSDC(userWallet, usdcAmount) {
    await realUSDC.mint(userWallet.address, usdcAmount);
    await realUSDC
      .connect(userWallet)
      .approve(await vault.getAddress(), usdcAmount);
    await vault.connect(userWallet).deposit(usdcAmount);
  }

  // --- Tests ---

  describe("Scenario A: Phase 1 Resolution (Low Volume)", function () {
    it("Should allow 1:1 payout for Phase 1 winners", async function () {
      const { market } = await setupMarket(5000);
      const amount = ethers.parseUnits("100", 18);
      const deadline =
        (await ethers.provider.getBlock("latest")).timestamp + 1000;

      await fundUserWithIgUSDC(user1, ethers.parseUnits("2000", 6));
      await igUSDC
        .connect(user1)
        .approve(await market.getAddress(), ethers.MaxUint256);

      // @audit Pass BOTH signatures to buyShares
      const nonce = await market.nonces(user1.address);
      const sigs = await signBuy(
        await market.getAddress(),
        user1,
        true,
        amount,
        nonce,
        deadline,
      );
      await market
        .connect(user1)
        .buyShares(
          user1.address,
          true,
          amount,
          deadline,
          sigs.userSig,
          sigs.serverSig,
        );

      const qid = await market.questionID();
      await mockRealityETH.setMockResult(qid, ethers.toBeHex(1, 32));
      await market.resolveMarket();

      expect(await market.marketResolved()).to.be.true;
      expect(await market.winningOutcomeIsYes()).to.be.true;

      const claimNonce = await market.nonces(user1.address);
      const claimSig = await signClaim(
        await market.getAddress(),
        user1.address,
        0,
        claimNonce,
        deadline,
      );
      const balBefore = await igUSDC.balanceOf(user1.address);

      await market
        .connect(user1)
        .claimWinningsFor(user1.address, true, 0, deadline, claimSig);

      expect(await igUSDC.balanceOf(user1.address)).to.be.gt(balBefore);
    });
  });

  describe("Scenario B: Phase 2 Resolution (Leveraged)", function () {
    it("Should settle leveraged positions post-migration", async function () {
      const { market } = await setupMarket(100);
      const deadline =
        (await ethers.provider.getBlock("latest")).timestamp + 5000;

      await fundUserWithIgUSDC(user1, ethers.parseUnits("1000", 6));
      await igUSDC
        .connect(user1)
        .approve(await market.getAddress(), ethers.MaxUint256);

      // @audit Pass BOTH signatures to trigger migration
      const buyAmt = ethers.parseUnits("150", 18);
      const nonce1 = await market.nonces(user1.address);
      const sigs1 = await signBuy(
        await market.getAddress(),
        user1,
        true,
        buyAmt,
        nonce1,
        deadline,
      );
      await market
        .connect(user1)
        .buyShares(
          user1.address,
          true,
          buyAmt,
          deadline,
          sigs1.userSig,
          sigs1.serverSig,
        );

      expect(await market.migrated()).to.be.true;

      await realUSDC.mint(
        await lendingVault.getAddress(),
        ethers.parseUnits("1000", 6),
      );
      await fundUserWithIgUSDC(user2, ethers.parseUnits("100", 6));
      await igUSDC
        .connect(user2)
        .approve(await market.getAddress(), ethers.MaxUint256);

      expect(await market.phase2Active()).to.be.true;

      await mockRealityETH.setMockResult(
        await market.questionID(),
        ethers.toBeHex(0, 32),
      );
      await market.resolveMarket();

      expect(await market.winningOutcomeIsYes()).to.be.false;
      expect(await market.settlementPrice18()).to.be.gt(0);
    });
  });

  describe("Scenario C: Invalid Market (Refund Logic)", function () {
    it("Should mark market as invalid and halt phase 2", async function () {
      const { market } = await setupMarket(5000);

      const INVALID =
        "0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";
      await mockRealityETH.setMockResult(await market.questionID(), INVALID);

      await market.resolveMarket();

      expect(await market.marketInvalidated()).to.be.true;
      expect(await market.phase2Active()).to.be.false;
    });
  });
});
