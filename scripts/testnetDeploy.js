import hre from "hardhat";
const { ethers } = hre;

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`\n🚀 Starting Bulletproof Deployment`);
  console.log(`Deployer: ${deployer.address}`);

  // Fetch the nonce exactly ONCE from the network
  let currentNonce = await ethers.provider.getTransactionCount(
    deployer.address,
    "pending",
  );
  console.log(`Initial Nonce: ${currentNonce}`);

  // --- PHASE 1: Libraries & Mocks ---
  console.log("\n[Phase 1] Deploying Libraries & Mocks...");

  const MathLib = await (
    await ethers.getContractFactory("IgarriMathLib")
  ).deploy({ nonce: currentNonce++ });
  await MathLib.waitForDeployment();
  console.log(`✅ MathLib: ${await MathLib.getAddress()}`);
  await delay(1000);

  const SigLib = await (
    await ethers.getContractFactory("IgarriSignatureLib")
  ).deploy({ nonce: currentNonce++ });
  await SigLib.waitForDeployment();
  console.log(`✅ SigLib: ${await SigLib.getAddress()}`);
  await delay(1000);

  const MockUSDC = await (
    await ethers.getContractFactory("MockUSDC")
  ).deploy("Test USDC", "USDC", 6, { nonce: currentNonce++ });
  await MockUSDC.waitForDeployment();
  const usdcAddr = await MockUSDC.getAddress();
  console.log(`✅ Mock USDC: ${usdcAddr}`);
  await delay(1000);

  const MockYieldToken = await (
    await ethers.getContractFactory("MockUSDC")
  ).deploy("Yield aUSDC", "aUSDC", 6, { nonce: currentNonce++ });
  await MockYieldToken.waitForDeployment();
  const aUsdcAddr = await MockYieldToken.getAddress();
  console.log(`✅ Mock aUSDC: ${aUsdcAddr}`);
  await delay(1000);

  const MockAave = await (
    await ethers.getContractFactory("MockAavePool")
  ).deploy(aUsdcAddr, { nonce: currentNonce++ });
  await MockAave.waitForDeployment();
  const aavePoolAddr = await MockAave.getAddress();
  console.log(`✅ Mock Aave Pool: ${aavePoolAddr}`);
  await delay(1000);

  const MockReality = await (
    await ethers.getContractFactory("MockRealityETH")
  ).deploy({ nonce: currentNonce++ });
  await MockReality.waitForDeployment();
  const realityAddr = await MockReality.getAddress();
  console.log(`✅ Mock Reality.eth: ${realityAddr}`);
  await delay(1000);

  // --- PHASE 2: Core Infrastructure ---
  console.log("\n[Phase 2] Deploying Core Infrastructure...");

  const Vault = await (
    await ethers.getContractFactory("IgarriVault")
  ).deploy(usdcAddr, aavePoolAddr, aUsdcAddr, { nonce: currentNonce++ });
  await Vault.waitForDeployment();
  const vaultAddr = await Vault.getAddress();
  console.log(`🏦 Vault: ${vaultAddr}`);
  await delay(1000);

  const Factory = await (
    await ethers.getContractFactory("IgarriMarketFactory")
  ).deploy({ nonce: currentNonce++ });
  await Factory.waitForDeployment();
  const factoryAddr = await Factory.getAddress();
  console.log(`🏭 Factory: ${factoryAddr}`);
  await delay(1000);

  const IgUSDC = await (
    await ethers.getContractFactory("IgarriUSDC")
  ).deploy(deployer.address, vaultAddr, factoryAddr, { nonce: currentNonce++ });
  await IgUSDC.waitForDeployment();
  const igUSDCAddr = await IgUSDC.getAddress();
  console.log(`🪙 igUSDC: ${igUSDCAddr}`);
  await delay(1000);

  const Lending = await (
    await ethers.getContractFactory("IgarriLendingVault")
  ).deploy(
    igUSDCAddr,
    usdcAddr,
    vaultAddr,
    aavePoolAddr,
    aUsdcAddr,
    factoryAddr,
    { nonce: currentNonce++ },
  );
  await Lending.waitForDeployment();
  const lendingAddr = await Lending.getAddress();
  console.log(`🏦 Lending Vault: ${lendingAddr}`);
  await delay(1000);

  const Insurance = await (
    await ethers.getContractFactory("IgarriInsuranceFund")
  ).deploy(usdcAddr, factoryAddr, aavePoolAddr, aUsdcAddr, {
    nonce: currentNonce++,
  });
  await Insurance.waitForDeployment();
  const insuranceAddr = await Insurance.getAddress();
  console.log(`🛡️ Insurance Fund: ${insuranceAddr}`);
  await delay(1000);

  // --- PHASE 3: Logic Singletons & Permissions ---
  console.log("\n[Phase 3] Wiring Permissions...");

  const MarketLogic = await (
    await ethers.getContractFactory("IgarriMarket", {
      libraries: {
        IgarriMathLib: await MathLib.getAddress(),
        IgarriSignatureLib: await SigLib.getAddress(),
      },
    })
  ).deploy({ nonce: currentNonce++ });
  await MarketLogic.waitForDeployment();
  const marketLogicAddr = await MarketLogic.getAddress();
  await delay(1000);

  // Note the placement of the nonce override in standard transactions
  await (
    await Factory.setIgarriUSDC(igUSDCAddr, { nonce: currentNonce++ })
  ).wait();
  await (
    await Factory.setIgarriVault(vaultAddr, { nonce: currentNonce++ })
  ).wait();
  await (
    await Factory.setIgarriLendingVault(lendingAddr, { nonce: currentNonce++ })
  ).wait();
  await (
    await Factory.setIgarriInsuranceFund(insuranceAddr, {
      nonce: currentNonce++,
    })
  ).wait();

  await (
    await Vault.setIgarriUSDC(igUSDCAddr, { nonce: currentNonce++ })
  ).wait();
  await (
    await Vault.setIgarriMarketFactory(factoryAddr, { nonce: currentNonce++ })
  ).wait();
  await (
    await Vault.setLendingVault(lendingAddr, { nonce: currentNonce++ })
  ).wait();

  console.log("✅ Permissions synchronized.");
  await delay(1000);

  // --- PHASE 4: Genesis Market ---
  console.log("\n[Phase 4] Launching Market...");

  const salt = ethers.id("genesis-005"); // Bumping salt to prevent CREATE2 collisions
  const predictedMarketAddr = await Factory.calculateProxyAddress(
    marketLogicAddr,
    salt,
  );

  const Token = await ethers.getContractFactory("IgarriOutcomeToken");
  const yesToken = await Token.deploy("YES", "YES", predictedMarketAddr, {
    nonce: currentNonce++,
  });
  await yesToken.waitForDeployment();
  await delay(1000);

  const noToken = await Token.deploy("NO", "NO", predictedMarketAddr, {
    nonce: currentNonce++,
  });
  await noToken.waitForDeployment();
  await delay(1000);

  const initData = MarketLogic.interface.encodeFunctionData("initialize", [
    igUSDCAddr,
    vaultAddr,
    ethers.parseUnits("100", 6),
    lendingAddr,
    deployer.address,
    insuranceAddr,
    Math.floor(Date.now() / 1000) + 86400 * 7,
    realityAddr,
    ethers.ZeroAddress,
    3600,
    "Test Market?␟crypto␟en",
    await yesToken.getAddress(),
    await noToken.getAddress(),
  ]);

  await (
    await Factory.deployMarket(marketLogicAddr, initData, salt, {
      nonce: currentNonce++,
    })
  ).wait();

  console.log("\n🎉 Deployment Successful!");
  console.table({
    Vault: vaultAddr,
    Factory: factoryAddr,
    Market: predictedMarketAddr,
  });
}

main().catch(console.error);
