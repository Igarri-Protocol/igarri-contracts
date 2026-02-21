import { expect } from "chai";
import pkg from "hardhat";
const { ethers, network } = pkg;

describe("Igarri Protocol: Full Lifecycle (With EIP-712 Signatures)", function () {
  let owner, user1, user2, keeper;
  let serverWallet;
  let realUSDC, yieldToken, aavePool;
  let igUSDC, vault, lendingVault, factory, market, insuranceFund, mathLib; // <-- Added mathLib
  let chainId;

  const DECIMALS_USDC = 6n;
  const SCALE_FACTOR = 10n ** 12n;
  const MIGRATION_THRESHOLD = 50_000n * 10n ** DECIMALS_USDC;
  const LP_LIQUIDITY = 1_000_000n * 10n ** DECIMALS_USDC;

  // --- EIP-712 HELPERS ---

  async function getDomain() {
    return {
      name: "IgarriMarket",
      version: "1",
      chainId: chainId,
      verifyingContract: await market.getAddress(),
    };
  }

  // NEW HELPER: For Phase 1 Buy Shares
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

  async function signOpenPosition(
    signerWallet,
    serverWallet,
    trader,
    isYes,
    collateral,
    leverage,
    minShares,
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
      collateral,
      leverage,
      minShares,
      nonce,
      deadline,
    };

    const userSig = await signerWallet.signTypedData(domain, types, value);
    const serverSig = await serverWallet.signTypedData(domain, types, value);

    return { userSig, serverSig };
  }

  async function signBulkLiquidate(
    serverWallet,
    traders,
    isYesSides,
    nonce,
    deadline,
  ) {
    const BULK_TYPEHASH = ethers.keccak256(
      ethers.toUtf8Bytes(
        "BulkLiquidate(bytes32 payloadHash,uint256 nonce,uint256 deadline)",
      ),
    );

    const payloadHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["address[]", "bool[]"],
        [traders, isYesSides],
      ),
    );

    const structHash = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32", "uint256", "uint256"],
        [BULK_TYPEHASH, payloadHash, nonce, deadline],
      ),
    );

    const domainSeparator = ethers.keccak256(
      ethers.AbiCoder.defaultAbiCoder().encode(
        ["bytes32", "bytes32", "bytes32", "uint256", "address"],
        [
          ethers.keccak256(
            ethers.toUtf8Bytes(
              "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
            ),
          ),
          ethers.keccak256(ethers.toUtf8Bytes("IgarriMarket")),
          ethers.keccak256(ethers.toUtf8Bytes("1")),
          chainId,
          await market.getAddress(),
        ],
      ),
    );

    const digest = ethers.keccak256(
      ethers.solidityPacked(
        ["string", "bytes32", "bytes32"],
        ["\x19\x01", domainSeparator, structHash],
      ),
    );

    return serverWallet.signingKey.sign(digest).serialized;
  }

  before(async function () {
    [owner, user1, user2, keeper] = await ethers.getSigners();
    chainId = (await ethers.provider.getNetwork()).chainId;
    serverWallet = new ethers.Wallet(
      "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
      ethers.provider,
    );

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", 6);
    yieldToken = await MockUSDC.deploy("Yield aUSDC", "aUSDC", 6);
    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(await yieldToken.getAddress());

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

    await factory.setIgarriInsuranceFund(await insuranceFund.getAddress());
    await lendingVault.setInsuranceFund(await insuranceFund.getAddress());
    await lendingVault.setReserveFactor(1000);

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

    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setIgarriMarketFactory(await factory.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress());
    await factory.setIgarriUSDC(await igUSDC.getAddress());
    await factory.setIgarriVault(await vault.getAddress());
    await factory.setIgarriLendingVault(await lendingVault.getAddress());
    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());

    // =========================================================
    // DEPLOY AND LINK EXTERNAL MATH LIBRARY
    // =========================================================
    const MathLib = await ethers.getContractFactory("IgarriMathLib");
    mathLib = await MathLib.deploy();
    await mathLib.waitForDeployment();

    const Market = await ethers.getContractFactory("IgarriMarket", {
      libraries: {
        IgarriMathLib: await mathLib.getAddress(),
      },
    });
    const singleton = await Market.deploy();
    await singleton.waitForDeployment();
    // =========================================================

    const initData = singleton.interface.encodeFunctionData("initialize", [
      await igUSDC.getAddress(),
      await vault.getAddress(),
      "TRUMP-2024",
      MIGRATION_THRESHOLD,
      await lendingVault.getAddress(),
      serverWallet.address,
      await insuranceFund.getAddress(),
    ]);

    const tx = await factory.deployMarket(
      await singleton.getAddress(),
      initData,
      ethers.id("market-test-v1"),
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

    await realUSDC.mint(user1.address, 1_000_000n * 10n ** 6n);
    await realUSDC.mint(user2.address, 1_000_000n * 10n ** 6n);
    await realUSDC.mint(owner.address, LP_LIQUIDITY * 2n);

    const depositAmount = 200_000n * 10n ** 6n;
    await realUSDC
      .connect(user1)
      .approve(await vault.getAddress(), depositAmount);
    await vault.connect(user1).deposit(depositAmount);
    await realUSDC
      .connect(user2)
      .approve(await vault.getAddress(), depositAmount);
    await vault.connect(user2).deposit(depositAmount);

    await realUSDC
      .connect(owner)
      .approve(await vault.getAddress(), LP_LIQUIDITY);
    await vault.connect(owner).deposit(LP_LIQUIDITY);
    const ownerIgBalance = await igUSDC.balanceOf(owner.address);
    await igUSDC
      .connect(owner)
      .approve(await lendingVault.getAddress(), ownerIgBalance);
    await lendingVault.connect(owner).stake(ownerIgBalance);
  });

  describe("Step 1: Migration", function () {
    it("Should start in Phase 1 (Bonding Curve)", async function () {
      expect(await market.phase2Active()).to.be.false;
    });

    it("Should allow bulk buying shares", async function () {
      const buyAmount = 500_000n * 10n ** 18n;
      await igUSDC
        .connect(user1)
        .approve(await market.getAddress(), ethers.MaxUint256);
      await igUSDC
        .connect(user2)
        .approve(await market.getAddress(), ethers.MaxUint256);

      const nonce = await market.nonces(user1.address);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);

      const { userSig, serverSig } = await signBuyShares(
        user1,
        serverWallet,
        user1.address,
        true,
        buyAmount,
        nonce,
        deadline,
      );

      await expect(
        market
          .connect(user1)
          .buyShares(
            user1.address,
            true,
            buyAmount,
            deadline,
            userSig,
            serverSig,
          ),
      ).to.emit(market, "Migrated");

      expect(await market.phase2Active()).to.be.true;
    });

    it("Should initialize Phase 2 with correct Price ($0.50)", async function () {
      const vUSDC = await market.vUSDC();
      const vYES = await market.vYES();
      expect(vYES).to.equal(vUSDC * 2n);
      const priceYes = await market.getFunction("getCurrentPrice(bool)")(true);
      expect(priceYes).to.equal(ethers.parseUnits("0.5", 18));
    });
  });

  describe("Step 2: Dual Position Trading (With Signatures)", function () {
    const COLLATERAL = 1000n * 10n ** 6n;
    const LEVERAGE = 5n;

    it("User1 should open a LONG YES position via Signature (5x)", async function () {
      const nonce = await market.nonces(user1.address);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const { userSig, serverSig } = await signOpenPosition(
        user1,
        serverWallet,
        user1.address,
        true,
        COLLATERAL,
        LEVERAGE,
        0,
        nonce,
        deadline,
      );
      await expect(
        market
          .connect(user1)
          .openPosition(
            user1.address,
            true,
            COLLATERAL,
            LEVERAGE,
            0,
            deadline,
            userSig,
            serverSig,
          ),
      ).to.emit(market, "PositionOpened");
    });

    it("User1 should open a LONG NO position via Signature (5x)", async function () {
      const nonce = await market.nonces(user1.address);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const { userSig, serverSig } = await signOpenPosition(
        user1,
        serverWallet,
        user1.address,
        false,
        COLLATERAL,
        LEVERAGE,
        0,
        nonce,
        deadline,
      );
      await expect(
        market
          .connect(user1)
          .openPosition(
            user1.address,
            false,
            COLLATERAL,
            LEVERAGE,
            0,
            deadline,
            userSig,
            serverSig,
          ),
      ).to.emit(market, "PositionOpened");
    });
  });

  describe("Step 3: Liquidation Logic (Server Gated)", function () {
    it("User2 pumps YES price to ~0.90", async function () {
      const pumpAmount = 50_000n * 10n ** 6n;
      const LEVERAGE = 5n;
      const nonce = await market.nonces(user2.address);
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const { userSig, serverSig } = await signOpenPosition(
        user2,
        serverWallet,
        user2.address,
        true,
        pumpAmount,
        LEVERAGE,
        0,
        nonce,
        deadline,
      );
      await market
        .connect(user2)
        .openPosition(
          user2.address,
          true,
          pumpAmount,
          LEVERAGE,
          0,
          deadline,
          userSig,
          serverSig,
        );
      const priceYes = await market.getFunction("getCurrentPrice(bool)")(true);
      expect(priceYes).to.be.gt(ethers.parseUnits("0.8", 18));
    });

    it("User1's NO position should be unhealthy", async function () {
      const healthFactor = await market.getHealthFactor(user1.address, false);
      expect(healthFactor).to.be.lt(10000n);
    });

    it("Keeper should Bulk Liquidate with Server Signature", async function () {
      const traders = [user1.address];
      const sides = [false];
      const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
      const nonce = await market.nonces(keeper.address);

      const serverSig = await signBulkLiquidate(
        serverWallet,
        traders,
        sides,
        nonce,
        deadline,
      );

      await expect(
        market
          .connect(keeper)
          .bulkLiquidate(traders, sides, deadline, serverSig),
      ).to.emit(market, "PositionLiquidated");

      const posNo = await market.positions(user1.address, false);
      expect(posNo.active).to.be.false;
    });
  });
});
