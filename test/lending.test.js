import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Lending Vault (Isolated)", function () {
  let owner, user;
  let realUSDC, yieldToken, aavePool;
  let igUSDC, vault, lendingVault;

  // Configuration
  const DECIMALS_USDC = 6;
  const DECIMALS_IG = 18;
  const INITIAL_DEPOSIT = ethers.parseUnits("1000", DECIMALS_USDC); // 1000 USDC
  const EXPECTED_IG_USDC = ethers.parseUnits("1000", DECIMALS_IG); // 1000 igUSDC

  beforeEach(async function () {
    [owner, user] = await ethers.getSigners();

    // 1. Deploy Mocks
    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    realUSDC = await MockUSDC.deploy("Mock USDC", "USDC", DECIMALS_USDC);
    await realUSDC.waitForDeployment();

    yieldToken = await MockUSDC.deploy("Yield aUSDC", "aUSDC", DECIMALS_USDC);
    await yieldToken.waitForDeployment();

    const MockAavePool = await ethers.getContractFactory("MockAavePool");
    aavePool = await MockAavePool.deploy(await yieldToken.getAddress());
    await aavePool.waitForDeployment();

    // 2. Deploy Igarri Vault (The Custodian)
    const Vault = await ethers.getContractFactory("IgarriVault");
    vault = await Vault.deploy(
      await realUSDC.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );
    await vault.waitForDeployment();

    // 3. Deploy IgarriUSDC (The Protocol Token)
    const IgUSDC = await ethers.getContractFactory("IgarriUSDC");
    igUSDC = await IgUSDC.deploy(
      owner.address,
      await vault.getAddress(),
      owner.address, // Dummy factory address
    );
    await igUSDC.waitForDeployment();

    // 4. Deploy Lending Vault (The Bank)
    const LendingVault = await ethers.getContractFactory("IgarriLendingVault");
    lendingVault = await LendingVault.deploy(
      await igUSDC.getAddress(),
      await realUSDC.getAddress(),
      await vault.getAddress(),
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
      owner.address,
    );
    await lendingVault.waitForDeployment();

    // ================== THE FIX IS HERE ==================
    // We explicitly allow the Lending Vault to transfer igUSDC from users
    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());
    // =====================================================

    // 5. Wire Permissions (Crucial Step)
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress()); // Allow LendingVault to pull funds

    // 6. User Setup: Get initial igUSDC
    // Mint Real USDC -> Approve Vault -> Deposit -> Get igUSDC
    await realUSDC.mint(user.address, INITIAL_DEPOSIT);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), INITIAL_DEPOSIT);
    await vault.connect(user).deposit(INITIAL_DEPOSIT);
  });

  it("Should have correct initial state", async function () {
    // User should have 1000 igUSDC
    expect(await igUSDC.balanceOf(user.address)).to.equal(EXPECTED_IG_USDC);

    // Vault should have 1000 realUSDC (held in Aave)
    expect(await vault.totalRealUSDCInVault()).to.equal(INITIAL_DEPOSIT);

    // Lending Vault should be empty
    expect(await lendingVault.totalAssets()).to.equal(0);
  });

  it("Should atomically move realUSDC to Aave when user stakes igUSDC", async function () {
    const stakeAmount = EXPECTED_IG_USDC; // 1000 igUSDC

    // 1. Approve Lending Vault to take user's igUSDC
    await igUSDC
      .connect(user)
      .approve(await lendingVault.getAddress(), stakeAmount);

    // 2. Stake
    await expect(lendingVault.connect(user).stake(stakeAmount))
      .to.emit(lendingVault, "Staked")
      .withArgs(user.address, stakeAmount, stakeAmount);

    // --- VERIFICATION ---

    // A. User Logic
    // User should have 0 igUSDC left
    expect(await igUSDC.balanceOf(user.address)).to.equal(0);
    // User should have 1000 igLP tokens
    expect(await lendingVault.balanceOf(user.address)).to.equal(stakeAmount);

    // B. Main Vault Logic
    // Vault 'totalRealUSDCInVault' should decrease by 1000
    // Because it sent the backing assets to the Lending Vault
    expect(await vault.totalRealUSDCInVault()).to.equal(0);

    // C. Lending Vault Logic
    // Lending Vault should now hold the value in Aave (via yieldTokens)
    // 1000 igUSDC = 1000 realUSDC (6 decimals)
    expect(
      await yieldToken.balanceOf(await lendingVault.getAddress()),
    ).to.equal(INITIAL_DEPOSIT);
  });

  it("Should accumulate yield correctly (Preview Balance)", async function () {
    const stakeAmount = EXPECTED_IG_USDC;
    await igUSDC
      .connect(user)
      .approve(await lendingVault.getAddress(), stakeAmount);
    await lendingVault.connect(user).stake(stakeAmount);

    // 1. Simulate Interest in Aave
    // The Lending Vault holds 1000 aUSDC. Let's add 100 aUSDC as "interest".
    const interest = ethers.parseUnits("100", DECIMALS_USDC);
    await aavePool.simulateInterest(await lendingVault.getAddress(), interest);

    // 2. Check Preview
    // Total Assets = 1000 + 100 = 1100 aUSDC
    // User Shares = 1000
    // Total Supply = 1000
    // Result = (1000 * 1100) / 1000 = 1100 (in 18 decimals)

    const expectedBalance = ethers.parseUnits("1100", DECIMALS_IG);
    const actualBalance = await lendingVault.previewUserBalance(user.address);

    expect(actualBalance).to.equal(expectedBalance);
  });

  it("Should unstake and return funds + yield to user", async function () {
    const stakeAmount = EXPECTED_IG_USDC;
    await igUSDC
      .connect(user)
      .approve(await lendingVault.getAddress(), stakeAmount);
    await lendingVault.connect(user).stake(stakeAmount);

    // 1. Simulate Interest (10% gain)
    const interest = ethers.parseUnits("100", DECIMALS_USDC); // 100 realUSDC profit

    // A. Mint the virtual yield (aTokens)
    await aavePool.simulateInterest(await lendingVault.getAddress(), interest);

    // ================== THE FIX IS HERE ==================
    // B. Mint the REAL backing cash to the Aave Pool so it's solvent
    await realUSDC.mint(await aavePool.getAddress(), interest);
    // =====================================================

    // 2. Unstake All
    // User has 1000 LP tokens.
    await lendingVault.connect(user).unstake(stakeAmount);

    // --- VERIFICATION ---

    // User should get 1100 igUSDC back (Original + Yield)
    const expectedReturn = ethers.parseUnits("1100", DECIMALS_IG);
    expect(await igUSDC.balanceOf(user.address)).to.equal(expectedReturn);

    // Lending Vault should be empty
    expect(await lendingVault.totalSupply()).to.equal(0);

    // Main Vault should have the funds back (1100 realUSDC)
    const expectedVaultBal = ethers.parseUnits("1100", DECIMALS_USDC);
    expect(await vault.totalRealUSDCInVault()).to.equal(expectedVaultBal);
  });
});
