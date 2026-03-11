import hre from "hardhat";
const { ethers } = hre;

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log(`\n🧪 Starting Testnet Lifecycle with: ${deployer.address}`);

  // =========================================================
  // 1. YOUR LIVE TESTNET ADDRESSES
  // =========================================================
  const MOCK_USDC_ADDRESS = "0xb77F0810D76337d06A66971151625d5bE6A27945";
  const VAULT_ADDRESS = "0x30d3E4F8ACe419614255D3ea9300023A7388D7F0";
  const IG_USDC_ADDRESS = "0xB38984183a8fa7ae2fB5F3B23D01389973400DCd";
  const MARKET_ADDRESS = "0xb919E3d646ccee943e7578922b3C9141Ed10D0e7";
  const MOCK_REALITY_ADDRESS = "0x9Bb476AbE27C50a5ecC0ec45a0D337f5aA583A32";

  // Load Contracts
  const realUSDC = await ethers.getContractAt("MockUSDC", MOCK_USDC_ADDRESS);
  const vault = await ethers.getContractAt("IgarriVault", VAULT_ADDRESS);
  const igUSDC = await ethers.getContractAt("IgarriUSDC", IG_USDC_ADDRESS);
  const market = await ethers.getContractAt("IgarriMarket", MARKET_ADDRESS);
  const mockReality = await ethers.getContractAt(
    "MockRealityETH",
    MOCK_REALITY_ADDRESS,
  );

  // =========================================================
  // TEST 1: ONBOARDING (Deposit USDC -> igUSDC)
  // =========================================================
  console.log("\n--- TEST 1: Vault Deposit ---");
  const depositAmount = ethers.parseUnits("500", 6); // 500 USDC

  console.log("Minting some Mock USDC for the test...");
  let tx = await realUSDC.mint(deployer.address, depositAmount);
  await tx.wait();
  await delay(2000); // RPC buffer

  console.log("Approving Vault...");
  tx = await realUSDC.approve(VAULT_ADDRESS, depositAmount);
  await tx.wait();
  await delay(2000);

  console.log("Depositing to Vault...");
  tx = await vault.deposit(depositAmount);
  await tx.wait();
  await delay(2000);

  const igBalance = await igUSDC.balanceOf(deployer.address);
  console.log(`✅ Received igUSDC: ${ethers.formatUnits(igBalance, 18)}`);

  // =========================================================
  // TEST 2 & 3: EIP-712 SIGNATURE & PHASE 1 TRADING
  // =========================================================
  console.log("\n--- TEST 2 & 3: Buy Shares & Migrate ---");

  // Buying 200 USDC worth of shares will force migration (threshold is 100).
  const buyAmount = ethers.parseUnits("200", 18);
  const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour
  const nonce = await market.nonces(deployer.address);

  // Generate EIP-712 Signatures
  console.log("Signing transaction locally...");
  const domain = {
    name: "IgarriMarket",
    version: "1",
    chainId: (await ethers.provider.getNetwork()).chainId,
    verifyingContract: MARKET_ADDRESS,
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
    buyer: deployer.address,
    isYes: true,
    shareAmount: buyAmount,
    nonce,
    deadline,
  };

  // Since deployer is both user and server for this test:
  const userSig = await deployer.signTypedData(domain, types, value);
  const serverSig = await deployer.signTypedData(domain, types, value);

  console.log("Approving Market for igUSDC...");
  tx = await igUSDC.approve(MARKET_ADDRESS, ethers.MaxUint256);
  await tx.wait();
  await delay(2000);

  console.log("Executing buyShares...");
  tx = await market.buyShares(
    deployer.address,
    true,
    buyAmount,
    deadline,
    userSig,
    serverSig,
  );
  await tx.wait();
  await delay(2000);

  const isMigrated = await market.phase2Active();
  console.log(
    `✅ Phase 1 Trade Complete. Market Migrated to Phase 2: ${isMigrated}`,
  );

  // =========================================================
  // TEST 4 & 5: ORACLE RESOLUTION & CLAIM
  // =========================================================
  console.log("\n--- TEST 4 & 5: Resolution & Claims ---");
  const questionID = await market.questionID();

  console.log("Mocking Reality.eth outcome to YES (1)...");
  tx = await mockReality.setMockResult(questionID, ethers.toBeHex(1, 32));
  await tx.wait();
  await delay(2000);

  console.log("Pulling result into Market (resolveMarket)...");
  tx = await market.resolveMarket();
  await tx.wait();
  await delay(2000);
  console.log(
    `✅ Market Resolved. Winning Outcome YES: ${await market.winningOutcomeIsYes()}`,
  );

  console.log("Generating Claim Signature...");
  const claimNonce = await market.nonces(deployer.address);
  const claimTypes = {
    ClaimTier: [
      { name: "user", type: "address" },
      { name: "tier", type: "uint8" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
    ],
  };
  const claimValue = {
    user: deployer.address,
    tier: 0,
    nonce: claimNonce,
    deadline,
  };
  const claimServerSig = await deployer.signTypedData(
    domain,
    claimTypes,
    claimValue,
  );

  const balBefore = await igUSDC.balanceOf(deployer.address);
  console.log("Claiming Winnings...");
  tx = await market.claimWinningsFor(
    deployer.address,
    true,
    0,
    deadline,
    claimServerSig,
  );
  await tx.wait();

  const balAfter = await igUSDC.balanceOf(deployer.address);
  const profit = balAfter - balBefore;
  console.log(
    `✅ Claim Complete! Received: ${ethers.formatUnits(profit, 18)} igUSDC`,
  );

  console.log("\n🎉 Testnet Lifecycle Completed Successfully!");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
