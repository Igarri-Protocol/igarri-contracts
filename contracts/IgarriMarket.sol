// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IIgarriUSDC.sol";
import "./interfaces/IIgarriVault.sol";
import "./tokens/IgarriOutcomeToken.sol";
import "./common/Singleton.sol";
import "./common/StorageAccessible.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IIgarriLendingVault.sol";

contract IgarriMarket is Singleton, StorageAccessible, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- Configuration ---
    uint256 public constant K = 100; 
    uint256 public constant INSURANCE_FEE_BPS = 50; 
    uint256 public constant LEVERAGE = 5;              
    uint256 public constant LIQUIDATION_THRESHOLD = 12000; // 120%
    uint256 public constant BPS = 10000;
    uint256 public constant SCALE_FACTOR = 10**12;     

    // --- State ---
    uint256 public migrationThreshold;
    IIgarriUSDC public igUSDC;
    IERC20 public realUSDC; 
    IgarriOutcomeToken public yesToken;
    IgarriOutcomeToken public noToken;
    IIgarriVault public vault;
    IIgarriLendingVault public lendingVault;
    
    uint256 public totalCapital; 
    uint256 public currentSupply; 
    bool public migrated;
    bool public phase2Active;
    
    // vAMM State (18 decimals)
    uint256 public vUSDC;
    uint256 public vYES;
    uint256 public vNO;
    uint256 public constantProductK;
    
    struct LeveragedPosition {
        uint256 collateral;     // 6 decimals
        uint256 loanAmount;     // 6 decimals
        uint256 shares;         // 18 decimals
        bool isYes;
        uint256 entryPrice;     // 18 decimals
        bool active;
    }
    
    mapping(address => LeveragedPosition) public positions;
    uint256 public totalBorrowed;  

    // --- Events ---
    event BulkBuy(address indexed user, bool isYes, uint256 igUSDCCost, uint256 sharesMinted);
    event Migrated(uint256 finalCapital, uint256 finalSupply);
    event Phase2Activated(uint256 initialLiquidity, uint256 vK);
    event PositionOpened(address indexed trader, bool isYes, uint256 collateral, uint256 loanAmount, uint256 shares, uint256 entryPrice);
    event PositionClosed(address indexed trader, uint256 payout, uint256 loanRepaid, int256 pnl);
    event PositionLiquidated(address indexed trader, address indexed keeper, uint256 keeperReward, uint256 loanRepaid, uint256 traderRefund);
    event Rebalanced(bool isYesSide, uint256 newVUSDC, uint256 newVToken);

    constructor() {
        igUSDC = IIgarriUSDC(address(0x1));
    }

    // --- Modifiers ---
    modifier onlyPhase2() { require(phase2Active, "Phase 2 not active"); _; }
    modifier noActivePosition() { require(!positions[msg.sender].active, "Active position exists"); _; }

    // ==========================================
    // INITIALIZATION
    // ==========================================

    function initialize(
        address _igUSDC, 
        address _vault, 
        string memory _marketName, 
        uint256 _migrationThreshold, 
        address _lendingVault
    ) external {
        require(address(igUSDC) == address(0), "Already initialized");
        
        igUSDC = IIgarriUSDC(_igUSDC);
        vault = IIgarriVault(_vault);
        lendingVault = IIgarriLendingVault(_lendingVault);
        migrationThreshold = _migrationThreshold;
        
        // Cache realUSDC address
        realUSDC = IERC20(vault.realUSDC());
        
        yesToken = new IgarriOutcomeToken(string(abi.encodePacked(_marketName, " YES")), "YES", address(this));
        noToken = new IgarriOutcomeToken(string(abi.encodePacked(_marketName, " NO")), "NO", address(this));
        
        // Approve vault to spend realUSDC (for when we deposit back to user)
        realUSDC.approve(address(vault), type(uint256).max);
        
        // Approve lending vault to spend realUSDC (for repayments)
        realUSDC.approve(address(lendingVault), type(uint256).max);
    }

    // ==========================================
    // PHASE 1: BONDING CURVE
    // ==========================================

    function getCurrentPrice() public view returns (uint256) {
        return (K * currentSupply) / 1e6; 
    }

    function getQuote(uint256 _amount) public view returns (uint256 rawCost, uint256 fee) {
        uint256 sStart = currentSupply;
        uint256 sEnd = sStart + _amount;
        rawCost = (K * (sEnd**2 - sStart**2)) / (2 * 1e6);
        fee = (rawCost * INSURANCE_FEE_BPS) / 10000;
    }

    function buyShares(bool _isYes, uint256 _shareAmount) external nonReentrant {
        require(!migrated, "Market migrated");
        
        uint256 finalShareAmount = _shareAmount;
        (uint256 rawCost, uint256 fee) = getQuote(_shareAmount);

        if (totalCapital + rawCost > migrationThreshold) {
            uint256 neededCapital = migrationThreshold - totalCapital;
            uint256 sStart = currentSupply;
            
            // Calculate exact shares needed to hit threshold
            uint256 sEnd = _sqrt((2 * 1e6 * neededCapital / K) + (sStart**2));
            finalShareAmount = sEnd - sStart;
            (rawCost, fee) = getQuote(finalShareAmount);
            
            // Snap to threshold to avoid rounding errors
            if (totalCapital + rawCost >= migrationThreshold - 1e12) {
                rawCost = migrationThreshold - totalCapital;
            }
        }

        uint256 totalCost = rawCost + fee;
        igUSDC.transferFrom(msg.sender, address(this), totalCost);

        currentSupply += finalShareAmount;
        totalCapital += rawCost;

        if (_isYes) yesToken.mint(msg.sender, finalShareAmount);
        else noToken.mint(msg.sender, finalShareAmount);

        emit BulkBuy(msg.sender, _isYes, totalCost, finalShareAmount);

        if (totalCapital >= migrationThreshold) _migrate();
    }

    function _migrate() internal {
        migrated = true;
        
        // Pull real USDC from vault (the $50k)
        vault.transferToMarket(address(this), migrationThreshold);
        
        // Initialize vAMM
        _initializePhase2(migrationThreshold / SCALE_FACTOR);
        
        emit Migrated(totalCapital, currentSupply);
    }

    function _initializePhase2(uint256 _initialLiquidity) internal {
        phase2Active = true;
        uint256 vAmt = _initialLiquidity * SCALE_FACTOR; 
        vUSDC = vAmt;
        vYES = vAmt;
        vNO = vAmt;
        constantProductK = vAmt * vAmt;
        emit Phase2Activated(_initialLiquidity, constantProductK);
    }
    
    function openPosition(bool _isYes, uint256 _collateral, uint256 _minSharesExpected) 
        external 
        nonReentrant 
        onlyPhase2 
        noActivePosition 
    {
        require(_collateral >= 10**6, "Min 1 USDC");
        
        uint256 collateral18 = _collateral * SCALE_FACTOR;
        igUSDC.transferFrom(msg.sender, address(this), collateral18);
        
        igUSDC.approve(address(vault), collateral18);
        vault.redeem(collateral18);
        
        // Take virtual loan from lending vault (tracks utilization)
        uint256 loanAmount = _collateral * (LEVERAGE - 1);
        lendingVault.fundLoan(loanAmount);
        
        // Execute virtual trade against vAMM
        uint256 totalPositionUSDC = _collateral * LEVERAGE * SCALE_FACTOR;
        uint256 sharesReceived = _buyFromvAMM(_isYes, totalPositionUSDC);

        require(sharesReceived >= _minSharesExpected, "Slippage too high");

        uint256 entryPrice = getCurrentPrice(_isYes);
        
        // Store position
        positions[msg.sender] = LeveragedPosition({
            collateral: _collateral,
            loanAmount: loanAmount,
            shares: sharesReceived,
            isYes: _isYes,
            entryPrice: entryPrice,
            active: true
        });
        
        totalBorrowed += loanAmount;
        
        emit PositionOpened(msg.sender, _isYes, _collateral, loanAmount, sharesReceived, entryPrice);
    }
    
    function closePosition(uint256 _minUSDCReturned) external nonReentrant onlyPhase2 {
        LeveragedPosition storage pos = positions[msg.sender];
        require(pos.active, "No active position");
        
        // Sell shares in vAMM (returns virtual USDC value)
        // This value represents the TOTAL equity (Collateral + Loan + Profit/Loss)
        uint256 usdcReturned18 = _sellTovAMM(pos.isYes, pos.shares);
        require(usdcReturned18 >= _minUSDCReturned, "Slippage too high");

        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        
        // Repay Logic
        // Priority: Loan repayment first. Remainder goes to user.
        uint256 amountToRepay = usdcReturned6 >= pos.loanAmount ? pos.loanAmount : usdcReturned6;
        uint256 userPayout6 = usdcReturned6 > pos.loanAmount ? usdcReturned6 - pos.loanAmount : 0;

        // Execute Transfers
        if (amountToRepay > 0) {
            // Market has RealUSDC from the sell + original redeem/loan
            lendingVault.repayLoan(amountToRepay, 0);
        }
        
        if (userPayout6 > 0) {
            // Deposit RealUSDC -> Vault -> igUSDC -> User
            vault.deposit(userPayout6);
            uint256 igMinted = userPayout6 * SCALE_FACTOR;
            igUSDC.transfer(msg.sender, igMinted);
        }
        
        // Accounting
        // We reduce totalBorrowed by the amount actually repaid. 
        // If usdcReturned6 < loanAmount, we have Bad Debt left on the books (correct behavior for now).
        totalBorrowed -= amountToRepay;
        
        int256 pnl = int256(userPayout6) - int256(pos.collateral);
        
        pos.active = false;
        emit PositionClosed(msg.sender, userPayout6, amountToRepay, pnl);
    }

    function liquidatePosition(address _trader) external nonReentrant onlyPhase2 {
        LeveragedPosition storage pos = positions[_trader];
        require(pos.active, "No active position");
        
        uint256 healthFactor = getHealthFactor(_trader);
        require(healthFactor < BPS, "Position healthy"); 
        
        // Force sell shares
        uint256 usdcReturned18 = _sellTovAMM(pos.isYes, pos.shares);
        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        
        // Calculate liquidation breakdown
        // Priority: Loan > Keeper > Trader
        uint256 amountToRepay = usdcReturned6 >= pos.loanAmount ? pos.loanAmount : usdcReturned6;
        uint256 surplus = usdcReturned6 > pos.loanAmount ? usdcReturned6 - pos.loanAmount : 0;
        
        uint256 keeperReward = (surplus * 500) / BPS; // 5% of surplus
        uint256 traderRefund = surplus - keeperReward;
        
        // Execute Transfers
        if (amountToRepay > 0) lendingVault.repayLoan(amountToRepay, 0);
        
        if (keeperReward > 0) {
            vault.deposit(keeperReward);
            igUSDC.transfer(msg.sender, keeperReward * SCALE_FACTOR);
        }
        
        if (traderRefund > 0) {
            vault.deposit(traderRefund);
            igUSDC.transfer(_trader, traderRefund * SCALE_FACTOR);
        }
        
        totalBorrowed -= amountToRepay;
        pos.active = false;
        
        emit PositionLiquidated(_trader, msg.sender, keeperReward, amountToRepay, traderRefund);
    }

    // ==========================================
    // vAMM LOGIC (Standard)
    // ==========================================

    function _buyFromvAMM(bool _isYes, uint256 _usdcAmount18) internal returns (uint256 shares) {
        uint256 vIn = _isYes ? vYES : vNO;
        uint256 newVUSDC = vUSDC + _usdcAmount18;
        uint256 newVToken = constantProductK / newVUSDC;
        
        shares = vIn - newVToken;
        require(shares > 0, "Zero shares received");
        
        vUSDC = newVUSDC;
        
        if (_isYes) {
            vYES = newVToken;
            _rebalanceNO(); 
        } else {
            vNO = newVToken;
            _rebalanceYES(); 
        }
        return shares;
    }

    function _sellTovAMM(bool _isYes, uint256 _shares) internal returns (uint256 usdcReceived) {
        require(_shares > 0, "Zero shares");
        uint256 vToken = _isYes ? vYES : vNO;
        uint256 newVToken = vToken + _shares;
        uint256 newVUSDC = constantProductK / newVToken;
        
        usdcReceived = vUSDC - newVUSDC;
        require(usdcReceived > 0, "Zero return");
        
        vUSDC = newVUSDC;
        
        if (_isYes) {
            vYES = newVToken;
            _rebalanceNO(); 
        } else {
            vNO = newVToken;
            _rebalanceYES(); 
        }
        return usdcReceived;
    }

    function _rebalanceNO() internal {
        uint256 priceYES = (vUSDC * 1e18) / vYES;
        if (priceYES > 2e18) priceYES = 2e18; 
        uint256 targetPriceNO = 2e18 > priceYES ? 2e18 - priceYES : 0;
        
        if (targetPriceNO > 0) {
            vNO = (vUSDC * 1e18) / targetPriceNO;
            emit Rebalanced(false, vUSDC, vNO);
        }
    }
    
    function _rebalanceYES() internal {
        uint256 priceNO = (vUSDC * 1e18) / vNO;
        if (priceNO > 2e18) priceNO = 2e18;
        uint256 targetPriceYES = 2e18 > priceNO ? 2e18 - priceNO : 0;
        
        if (targetPriceYES > 0) {
            vYES = (vUSDC * 1e18) / targetPriceYES;
            emit Rebalanced(true, vUSDC, vYES);
        }
    }

    // ==========================================
    // VIEW FUNCTIONS
    // ==========================================

    function getCurrentPrice(bool _isYes) public view returns (uint256) {
        if (!phase2Active) return 0;
        if (_isYes) {
            return vYES > 0 ? (vUSDC * 1e18) / vYES : 0;
        } else {
            return vNO > 0 ? (vUSDC * 1e18) / vNO : 0;
        }
    }

    function getHealthFactor(address _trader) public view returns (uint256) {
        LeveragedPosition memory pos = positions[_trader];
        if (!pos.active) return type(uint256).max;
        
        uint256 currentPrice = getCurrentPrice(pos.isYes);
        if (currentPrice == 0) return 0;
        
        uint256 currentValue18 = (pos.shares * currentPrice) / 1e18;
        uint256 currentValue6 = currentValue18 / SCALE_FACTOR;
        
        // Liquidation requirement: 120% of loan
        uint256 liquidationReq = (pos.loanAmount * LIQUIDATION_THRESHOLD) / BPS;
        
        if (currentValue6 == 0) return 0;
        return (currentValue6 * BPS) / liquidationReq;
    }
    
    function previewOpen(bool _isYes, uint256 _collateral6) external view returns (uint256 shares, uint256 priceImpact) {
        if (!phase2Active) return (0, 0);
        
        uint256 positionValue = _collateral6 * LEVERAGE * SCALE_FACTOR;
        uint256 vIn = _isYes ? vYES : vNO;
        
        uint256 newVUSDC = vUSDC + positionValue;
        uint256 newVToken = constantProductK / newVUSDC;
        shares = vIn - newVToken;
        
        uint256 spotPriceBefore = (vUSDC * 1e18) / vIn;
        uint256 spotPriceAfter = (newVUSDC * 1e18) / newVToken;
        priceImpact = ((spotPriceAfter - spotPriceBefore) * BPS) / spotPriceBefore;
        
        return (shares, priceImpact);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}