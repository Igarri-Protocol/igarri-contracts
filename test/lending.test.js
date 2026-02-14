import { expect } from "chai";
import pkg from "hardhat";
const { ethers } = pkg;

describe("Igarri Lending Vault (Isolated)", function () {
  let owner, user, dummyMarket;
  let realUSDC, yieldToken, aavePool;
  let igUSDC, vault, lendingVault, insuranceFund;

  // Configuration
  const DECIMALS_USDC = 6;
  const DECIMALS_IG = 18;
  const INITIAL_DEPOSIT = ethers.parseUnits("1000", DECIMALS_USDC); // 1000 USDC
  const EXPECTED_IG_USDC = ethers.parseUnits("1000", DECIMALS_IG); // 1000 igUSDC

  beforeEach(async function () {
    [owner, user, dummyMarket] = await ethers.getSigners();

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
      owner.address, // owner acts as marketFactory for testing
    );
    await lendingVault.waitForDeployment();

    // ================== NEW: Deploy Insurance Fund ==================
    const InsuranceFund = await ethers.getContractFactory(
      "IgarriInsuranceFund",
    );
    insuranceFund = await InsuranceFund.deploy(
      await realUSDC.getAddress(),
      owner.address, // owner acts as marketFactory here too
      await aavePool.getAddress(),
      await yieldToken.getAddress(),
    );
    await insuranceFund.waitForDeployment();

    // Wire the Insurance Fund to the Lending Vault
    await lendingVault.setInsuranceFund(await insuranceFund.getAddress());
    // Set default reserve factor to 10% (1000 BPS)
    await lendingVault.setReserveFactor(1000);
    // ================================================================

    await insuranceFund
      .connect(owner)
      .setAllowedMarket(await lendingVault.getAddress(), true);

    // 5. Wire Permissions
    await igUSDC
      .connect(owner)
      .addAllowedMarket(await lendingVault.getAddress());
    await vault.setIgarriUSDC(await igUSDC.getAddress());
    await vault.setLendingVault(await lendingVault.getAddress());

    // 6. User Setup: Get initial igUSDC
    await realUSDC.mint(user.address, INITIAL_DEPOSIT);
    await realUSDC
      .connect(user)
      .approve(await vault.getAddress(), INITIAL_DEPOSIT);
    await vault.connect(user).deposit(INITIAL_DEPOSIT);
  });

  it("Should have correct initial state", async function () {
    expect(await igUSDC.balanceOf(user.address)).to.equal(EXPECTED_IG_USDC);
    expect(await vault.totalRealUSDCInVault()).to.equal(INITIAL_DEPOSIT);
    expect(await lendingVault.totalAssets()).to.equal(0);
    // Ensure Insurance Fund starts empty
    expect(await insuranceFund.totalAssets()).to.equal(0);
  });

  it("Should atomically move realUSDC to Aave when user stakes igUSDC", async function () {
    const stakeAmount = EXPECTED_IG_USDC;

    await igUSDC
      .connect(user)
      .approve(await lendingVault.getAddress(), stakeAmount);
    await expect(lendingVault.connect(user).stake(stakeAmount))
      .to.emit(lendingVault, "Staked")
      .withArgs(user.address, stakeAmount, stakeAmount);

    expect(await igUSDC.balanceOf(user.address)).to.equal(0);
    expect(await lendingVault.balanceOf(user.address)).to.equal(stakeAmount);
    expect(await vault.totalRealUSDCInVault()).to.equal(0);
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

    const interest = ethers.parseUnits("100", DECIMALS_USDC);
    await aavePool.simulateInterest(await lendingVault.getAddress(), interest);

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

    const interest = ethers.parseUnits("100", DECIMALS_USDC);

    await aavePool.simulateInterest(await lendingVault.getAddress(), interest);
    await realUSDC.mint(await aavePool.getAddress(), interest);

    await lendingVault.connect(user).unstake(stakeAmount);

    const expectedReturn = ethers.parseUnits("1100", DECIMALS_IG);
    expect(await igUSDC.balanceOf(user.address)).to.equal(expectedReturn);
    expect(await lendingVault.totalSupply()).to.equal(0);

    const expectedVaultBal = ethers.parseUnits("1100", DECIMALS_USDC);
    expect(await vault.totalRealUSDCInVault()).to.equal(expectedVaultBal);
  });

  // =========================================================================
  // NEW TEST: Ensure Reserve Factor correctly funds the Insurance Pool
  // =========================================================================
  it("Should route a percentage of repaid interest to the Insurance Fund", async function () {
    // 1. User stakes funds so the Lending Vault has liquidity
    const stakeAmount = EXPECTED_IG_USDC;
    await igUSDC
      .connect(user)
      .approve(await lendingVault.getAddress(), stakeAmount);
    await lendingVault.connect(user).stake(stakeAmount);

    // 2. Setup a Dummy Market and allow it to borrow
    await lendingVault.connect(owner).addAllowedMarket(dummyMarket.address);

    // 3. Dummy Market borrows 500 USDC
    const loanAmount = ethers.parseUnits("500", DECIMALS_USDC);
    await lendingVault.connect(dummyMarket).fundLoan(loanAmount);

    // Verify market received the physical USDC
    expect(await realUSDC.balanceOf(dummyMarket.address)).to.equal(loanAmount);

    // 4. Time passes... Market needs to repay loan + 100 USDC interest
    const interestAmount = ethers.parseUnits("100", DECIMALS_USDC);

    // Mint the extra 100 USDC to the market to simulate winning/interest gathering
    await realUSDC.mint(dummyMarket.address, interestAmount);
    const totalRepayment = loanAmount + interestAmount;

    // 5. Repay the Loan
    await realUSDC
      .connect(dummyMarket)
      .approve(await lendingVault.getAddress(), totalRepayment);
    await lendingVault
      .connect(dummyMarket)
      .repayLoan(loanAmount, interestAmount);

    // --- VERIFICATION ---

    // Total interest was 100. Reserve factor is 10% (1000 BPS).
    // Expected Insurance Cut = 10 USDC
    const expectedInsuranceCut = ethers.parseUnits("10", DECIMALS_USDC);

    // The Insurance Fund should now hold 10 USDC worth of yield tokens in Aave
    expect(await insuranceFund.totalAssets()).to.equal(expectedInsuranceCut);

    // The Lending Vault should have received the principal (500) + remaining interest (90)
    // Plus the 500 it still held that wasn't loaned out = 1090 total in Aave
    const expectedLendingVaultAssets = ethers.parseUnits("1090", DECIMALS_USDC);
    expect(
      await yieldToken.balanceOf(await lendingVault.getAddress()),
    ).to.equal(expectedLendingVaultAssets);
  });
});
