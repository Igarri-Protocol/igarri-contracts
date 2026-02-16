// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

import "./interfaces/IIgarriUSDC.sol";
import "./interfaces/IIgarriVault.sol";
import "./interfaces/IIgarriLendingVault.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IIgarriInsuranceFund.sol";

import "./tokens/IgarriOutcomeToken.sol";
import "./common/Singleton.sol";
import "./common/StorageAccessible.sol";

contract IgarriMarket is Singleton, StorageAccessible, ReentrancyGuard, EIP712, Nonces {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // --- Configuration ---
    uint256 public constant K = 100;
    uint256 public constant INSURANCE_FEE_BPS = 50;
    uint256 public constant MAX_LEVERAGE = 5; 
    uint256 public constant LIQUIDATION_THRESHOLD = 12000;
    uint256 public constant BPS = 10000;
    uint256 public constant SCALE_FACTOR = 10**12;

    // --- TypeHashes ---
    bytes32 private constant BUY_SHARES_TYPEHASH = keccak256(
        "BuyShares(address buyer,bool isYes,uint256 shareAmount,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant OPEN_POSITION_TYPEHASH = keccak256(
        "OpenPosition(address trader,bool isYes,uint256 collateral,uint256 leverage,uint256 minShares,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant CLOSE_POSITION_TYPEHASH = keccak256(
        "ClosePosition(address trader,bool isYes,uint256 minUSDCReturned,uint256 nonce,uint256 deadline)"
    );

    bytes32 private constant BULK_LIQUIDATE_TYPEHASH = keccak256(
        "BulkLiquidate(bytes32 payloadHash,uint256 nonce,uint256 deadline)"
    );

    // --- State ---
    address public serverSigner; 

    uint256 public migrationThreshold;
    IIgarriUSDC public igUSDC;
    IERC20 public realUSDC;
    IgarriOutcomeToken public yesToken;
    IgarriOutcomeToken public noToken;
    IIgarriVault public vault;
    IIgarriLendingVault public lendingVault;
    IIgarriInsuranceFund public insuranceFund;

    uint256 public totalCapital;
    uint256 public currentSupply;
    bool public migrated;
    bool public phase2Active;

    // vAMM State
    uint256 public vUSDC;
    uint256 public vYES;
    uint256 public vNO;
    uint256 public constantProductK;

    struct LeveragedPosition {
        uint256 collateral;
        uint256 loanAmount;
        uint256 shares;
        bool isYes;
        uint256 entryPrice;
        bool active;
    }

    mapping(address => mapping(bool => LeveragedPosition)) public positions;
    uint256 public totalBorrowed;

    bool public marketResolved;
    bool public winningOutcomeIsYes;
    uint256 public settlementPrice18;

    enum UserTier { Standard, Early, FanToken }

    uint256 public phase2YesOI;
    uint256 public phase2NoOI;

    // --- Events ---
    event BulkBuy(address indexed user, bool isYes, uint256 igUSDCCost, uint256 sharesMinted);
    event Migrated(uint256 finalCapital, uint256 finalSupply);
    event Phase2Activated(uint256 initialLiquidity, uint256 vK);
    event PositionOpened(address indexed trader, bool isYes, uint256 collateral, uint256 loanAmount, uint256 shares, uint256 entryPrice);
    event PositionClosed(address indexed trader, bool isYes, uint256 payout, uint256 loanRepaid, int256 pnl);
    event PositionLiquidated(address indexed trader, bool isYes, address indexed keeper, uint256 keeperReward, uint256 loanRepaid, uint256 traderRefund);
    event Rebalanced(bool isYesSide, uint256 newVUSDC, uint256 newVToken);
    event BulkLiquidationExecuted(uint256 count);
    event ServerSignerUpdated(address newSigner); 
    event MarketResolved(bool isYesWinner, uint256 settlementPrice18);
    event WinningsClaimed(address indexed user, bool isPhase1, uint256 totalPayoutUSDC);

    // --- Custom Errors ---
    error AlreadyInitialized();
    error NotAuthorized();
    error MarketMigrated();
    error ActivePositionExists();
    error MinCollateralNotMet();
    error InvalidLeverage();
    error SlippageExceeded();
    error NoActivePosition();
    error ArrayLengthMismatch();
    error PositionIsHealthy();
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error NoWinningPhase1Shares();
    error NoWinningPhase2Position();
    error ZeroPayout();
    error ZeroShares();
    error ZeroReturn();
    error Phase2NotActive();
    error InvalidSignature();
    error SignatureExpired();
    error AccessDenied();

    constructor() EIP712("IgarriMarket", "1") {
        igUSDC = IIgarriUSDC(address(0x1));
    }

    // --- Modifiers ---
    function _checkPhase2() internal view {
        if (!phase2Active) revert Phase2NotActive();
    }
    
    function _checkNoActivePosition(bool _isYes) internal view {
        if (positions[msg.sender][_isYes].active) revert ActivePositionExists();
    }

    modifier onlyPhase2() { 
        _checkPhase2(); 
        _; 
    }

    modifier noActivePosition(bool _isYes) { 
        _checkNoActivePosition(_isYes); 
        _; 
    }

    function initialize(
        address _igUSDC,
        address _vault,
        string memory _marketName,
        uint256 _migrationThreshold,
        address _lendingVault,
        address _serverSigner,
        address _insuranceFund
    ) external {
        if (address(igUSDC) != address(0)) revert AlreadyInitialized();
        igUSDC = IIgarriUSDC(_igUSDC);
        vault = IIgarriVault(_vault);
        lendingVault = IIgarriLendingVault(_lendingVault);
        migrationThreshold = _migrationThreshold * SCALE_FACTOR;
        serverSigner = _serverSigner;
        realUSDC = IERC20(vault.realUSDC());
        yesToken = new IgarriOutcomeToken(string(abi.encodePacked(_marketName, " YES")), "YES", address(this));
        noToken = new IgarriOutcomeToken(string(abi.encodePacked(_marketName, " NO")), "NO", address(this));
        realUSDC.approve(address(vault), type(uint256).max);
        realUSDC.approve(address(lendingVault), type(uint256).max);
        insuranceFund = IIgarriInsuranceFund(_insuranceFund);
    }

    function setServerSigner(address _newSigner) external {
        if (msg.sender != serverSigner) revert NotAuthorized();
        serverSigner = _newSigner;
        emit ServerSignerUpdated(_newSigner);
    }

    // --- PHASE 1 ---
    function getCurrentPrice() public view returns (uint256) {
        return (K * currentSupply) / 1e6;
    }

    function getQuote(uint256 _amount) public view returns (uint256 rawCost, uint256 fee) {
        uint256 sStart = currentSupply;
        uint256 sEnd = sStart + _amount;
        rawCost = (K * (sEnd**2 - sStart**2)) / (2 * 1e24);
        fee = (rawCost * INSURANCE_FEE_BPS) / 10000;
    }

    function buyShares(
        address _buyer,
        bool _isYes, 
        uint256 _shareAmount, 
        uint256 _deadline,
        bytes calldata _userSignature, 
        bytes calldata _serverSignature
    ) external nonReentrant {
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (migrated) revert MarketMigrated();

        bytes32 structHash = keccak256(abi.encode(BUY_SHARES_TYPEHASH, _buyer, _isYes, _shareAmount, _useNonce(_buyer), _deadline));
        _verifySigs(_buyer, structHash, _userSignature, _serverSignature);

        uint256 finalShareAmount = _shareAmount;
        (uint256 rawCost, uint256 fee) = getQuote(_shareAmount);
        
        if (totalCapital + rawCost > migrationThreshold) {
            uint256 neededCapital = migrationThreshold - totalCapital;
            uint256 sStart = currentSupply;
            uint256 sEnd = _sqrt((2 * 1e24 * neededCapital / K) + (sStart**2));
            finalShareAmount = sEnd - sStart;
            (rawCost, fee) = getQuote(finalShareAmount);
            if (totalCapital + rawCost >= migrationThreshold - 1e12) {
                rawCost = migrationThreshold - totalCapital;
            }
        }
        uint256 totalCost = rawCost + fee;
        igUSDC.transferFrom(_buyer, address(this), totalCost);
        currentSupply += finalShareAmount;
        totalCapital += rawCost;
        
        if (_isYes) yesToken.mint(_buyer, finalShareAmount);
        else noToken.mint(_buyer, finalShareAmount);
        
        emit BulkBuy(_buyer, _isYes, totalCost, finalShareAmount);
        
        if (totalCapital >= migrationThreshold) _migrate();
    }

    function _migrate() internal {
        migrated = true;
        vault.transferToMarket(address(this), migrationThreshold);
        _initializePhase2(migrationThreshold / SCALE_FACTOR);
        emit Migrated(totalCapital, currentSupply);
    }

    function _initializePhase2(uint256 _initialLiquidity) internal {
        phase2Active = true;
        uint256 vAmt = _initialLiquidity * SCALE_FACTOR;
        vUSDC = vAmt;
        vYES = vAmt * 2;
        vNO = vAmt * 2;
        constantProductK = vUSDC * vYES;
        emit Phase2Activated(_initialLiquidity, constantProductK);
    }

    // --- PHASE 2 ---
    function openPosition(
        address _trader, 
        bool _isYes, 
        uint256 _collateral, 
        uint256 _leverage, 
        uint256 _minSharesExpected, 
        uint256 _deadline, 
        bytes calldata _userSignature, 
        bytes calldata _serverSignature
    ) external nonReentrant onlyPhase2 {
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (positions[_trader][_isYes].active) revert ActivePositionExists();
        if (_collateral < 10**6) revert MinCollateralNotMet();
        if (_leverage < 1 || _leverage > MAX_LEVERAGE) revert InvalidLeverage();

        bytes32 structHash = keccak256(abi.encode(OPEN_POSITION_TYPEHASH, _trader, _isYes, _collateral, _leverage, _minSharesExpected, _useNonce(_trader), _deadline));
        _verifySigs(_trader, structHash, _userSignature, _serverSignature);

        uint256 collateral18 = _collateral * SCALE_FACTOR;
        igUSDC.transferFrom(_trader, address(this), collateral18);
        igUSDC.approve(address(vault), collateral18);
        vault.redeem(collateral18);

        uint256 loanAmount = _collateral * (_leverage - 1);
        if (loanAmount > 0) lendingVault.fundLoan(loanAmount);

        uint256 totalPositionUSDC = _collateral * _leverage * SCALE_FACTOR;
        uint256 sharesReceived = _buyFromvAMM(_isYes, totalPositionUSDC);
        if (sharesReceived < _minSharesExpected) revert SlippageExceeded();
        
        positions[_trader][_isYes] = LeveragedPosition({
            collateral: _collateral,
            loanAmount: loanAmount,
            shares: sharesReceived,
            isYes: _isYes,
            entryPrice: getCurrentPrice(_isYes),
            active: true
        });
        
        totalBorrowed += loanAmount;
        _updateOI(_isYes, sharesReceived, true);

        emit PositionOpened(_trader, _isYes, _collateral, loanAmount, sharesReceived, positions[_trader][_isYes].entryPrice);
    }

    function closePosition(address _trader, bool _isYes, uint256 _minUSDCReturned, uint256 _deadline, bytes calldata _userSignature, bytes calldata _serverSignature) external nonReentrant onlyPhase2 {
        if (block.timestamp > _deadline) revert SignatureExpired();
        
        bytes32 structHash = keccak256(abi.encode(CLOSE_POSITION_TYPEHASH, _trader, _isYes, _minUSDCReturned, _useNonce(_trader), _deadline));
        _verifySigs(_trader, structHash, _userSignature, _serverSignature);

        LeveragedPosition storage pos = positions[_trader][_isYes];
        if (!pos.active) revert NoActivePosition();

        uint256 usdcReturned18 = _sellTovAMM(_isYes, pos.shares);
        if (usdcReturned18 < _minUSDCReturned) revert SlippageExceeded();

        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        uint256 amountToRepay = usdcReturned6 >= pos.loanAmount ? pos.loanAmount : usdcReturned6;
        uint256 userPayout6 = usdcReturned6 > pos.loanAmount ? usdcReturned6 - pos.loanAmount : 0;

        _repayLoan(amountToRepay);
        _payoutRoute(_trader, userPayout6);
        _updateOI(_isYes, pos.shares, false);

        pos.active = false;
        emit PositionClosed(_trader, _isYes, userPayout6, amountToRepay, int256(userPayout6) - int256(pos.collateral));
    }
    
    // --- LIQUIDATION ---
    function liquidatePosition(address _trader, bool _isYes) external nonReentrant onlyPhase2 {
        _liquidate(_trader, _isYes, msg.sender);
    }
    
    function bulkLiquidate(
        address[] calldata _traders, 
        bool[] calldata _isYesSides,
        uint256 _deadline,
        bytes calldata _serverSignature
    ) external nonReentrant onlyPhase2 returns (uint256 liquidatedCount) {
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (_traders.length != _isYesSides.length) revert ArrayLengthMismatch();

        bytes32 payloadHash = keccak256(abi.encode(_traders, _isYesSides));
        bytes32 structHash = keccak256(abi.encode(BULK_LIQUIDATE_TYPEHASH, payloadHash, _useNonce(msg.sender), _deadline));
        _verifyServerSig(structHash, _serverSignature);

        liquidatedCount = 0;
        for (uint i = 0; i < _traders.length; i++) {
            if (!positions[_traders[i]][_isYesSides[i]].active) continue;
            if (getHealthFactor(_traders[i], _isYesSides[i]) < BPS) {
                _liquidate(_traders[i], _isYesSides[i], msg.sender);
                liquidatedCount++;
            }
        }
        emit BulkLiquidationExecuted(liquidatedCount);
    }

    function _liquidate(address _trader, bool _isYes, address _keeper) internal {
        LeveragedPosition storage pos = positions[_trader][_isYes];
        if (!pos.active) revert NoActivePosition();
        if (getHealthFactor(_trader, _isYes) >= BPS) revert PositionIsHealthy();

        uint256 usdcReturned18 = _sellTovAMM(_isYes, pos.shares);
        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        
        uint256 amountToRepay;
        uint256 keeperReward;
        uint256 traderRefund;

        if (usdcReturned6 < pos.loanAmount) {
            uint256 shortfall = pos.loanAmount - usdcReturned6;
            insuranceFund.coverBadDebt(shortfall);
            amountToRepay = pos.loanAmount; 
        } else {
            amountToRepay = pos.loanAmount;
            uint256 surplus = usdcReturned6 - pos.loanAmount;
            
            uint256 insuranceFee = (surplus * 1000) / BPS;
            if (insuranceFee > 0) {
                realUSDC.approve(address(insuranceFund), insuranceFee);
                insuranceFund.depositFee(insuranceFee);
            }
            
            uint256 remainingSurplus = surplus - insuranceFee;
            keeperReward = (remainingSurplus * 500) / BPS; 
            traderRefund = remainingSurplus - keeperReward;
        }

        _repayLoan(amountToRepay);
        _payoutRoute(_keeper, keeperReward);
        _payoutRoute(_trader, traderRefund);
        _updateOI(_isYes, pos.shares, false);

        pos.active = false;
        emit PositionLiquidated(_trader, _isYes, _keeper, keeperReward, amountToRepay, traderRefund);
    }
    
    // --- PHASE 3 ---
    function resolveMarket(bool _winningOutcomeIsYes) external {
        if (marketResolved) revert MarketAlreadyResolved();
        
        marketResolved = true;
        phase2Active = false; 
        winningOutcomeIsYes = _winningOutcomeIsYes;

        uint256 totalWinningShares18 = _winningOutcomeIsYes 
            ? (yesToken.totalSupply() + phase2YesOI) 
            : (noToken.totalSupply() + phase2NoOI);

        uint256 availableUSDC6 = realUSDC.balanceOf(address(this));
        uint256 liabilities6 = totalWinningShares18 / SCALE_FACTOR; 
        
        if (liabilities6 <= availableUSDC6 || liabilities6 == 0) {
            settlementPrice18 = 1e18;
        } else {
            settlementPrice18 = (availableUSDC6 * 1e18) / liabilities6;
        }

        emit MarketResolved(_winningOutcomeIsYes, settlementPrice18);
    }

    function claimWinnings(bool _isPhase1, UserTier _tier) external nonReentrant {
        if (!marketResolved) revert MarketNotResolved();

        uint256 totalPayout6 = 0;

        if (_isPhase1) {
            IgarriOutcomeToken winningToken = winningOutcomeIsYes ? yesToken : noToken;
            uint256 userShares = winningToken.balanceOf(msg.sender);
            if (userShares == 0) revert NoWinningPhase1Shares();

            winningToken.burn(msg.sender, userShares);
            totalPayout6 = (userShares * settlementPrice18) / 1e18 / SCALE_FACTOR;

        } else {
            LeveragedPosition storage pos = positions[msg.sender][winningOutcomeIsYes];
            if (!pos.active) revert NoWinningPhase2Position();

            uint256 grossValue18 = (pos.shares * settlementPrice18) / 1e18;
            uint256 grossValue6 = grossValue18 / SCALE_FACTOR;

            uint256 netTradingProfit6 = 0;
            if (grossValue6 > pos.loanAmount) netTradingProfit6 = grossValue6 - pos.loanAmount;
    
            _repayLoan(pos.loanAmount);

            uint256 mockBaseYield6 = (pos.collateral * 5) / 100; 
            uint256 yieldMultiplier = 10;
            if (_tier == UserTier.Early) yieldMultiplier = 15;     
            else if (_tier == UserTier.FanToken) yieldMultiplier = 20; 

            totalPayout6 = pos.collateral + netTradingProfit6 + ((mockBaseYield6 * yieldMultiplier) / 10);
            
            _updateOI(winningOutcomeIsYes, pos.shares, false);
            pos.active = false;
        }

        if (totalPayout6 == 0) revert ZeroPayout();

        _payoutRoute(msg.sender, totalPayout6);
        emit WinningsClaimed(msg.sender, _isPhase1, totalPayout6);
    }

    // --- BYTECODE OPTIMIZATION HELPERS ---
    function _verifySigs(address _user, bytes32 _structHash, bytes calldata _userSig, bytes calldata _serverSig) internal view {
        bytes32 digest = _hashTypedDataV4(_structHash);
        if (!SignatureChecker.isValidSignatureNow(_user, digest, _userSig) || 
            !SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSig)) revert InvalidSignature();
    }

    function _verifyServerSig(bytes32 _structHash, bytes calldata _serverSig) internal view {
        bytes32 digest = _hashTypedDataV4(_structHash);
        if (!SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSig)) revert InvalidSignature();
    }

    function _payoutRoute(address _to, uint256 _amount6) internal {
        if (_amount6 > 0) {
            vault.deposit(_amount6);
            igUSDC.transfer(_to, _amount6 * SCALE_FACTOR);
        }
    }

    function _repayLoan(uint256 _amount) internal {
        if (_amount > 0) {
            lendingVault.repayLoan(_amount, 0);
            totalBorrowed -= _amount;
        }
    }

    function _updateOI(bool _isYes, uint256 _shares, bool _isAdd) internal {
        if (_isYes) {
            if (_isAdd) phase2YesOI += _shares; else phase2YesOI -= _shares;
        } else {
            if (_isAdd) phase2NoOI += _shares; else phase2NoOI -= _shares;
        }
    }

    // --- vAMM & VIEW FUNCTIONS ---
    function _buyFromvAMM(bool _isYes, uint256 _usdcAmount18) internal returns (uint256 shares) {
        uint256 vIn = _isYes ? vYES : vNO;
        uint256 newVUSDC = vUSDC + _usdcAmount18;
        uint256 newVToken = constantProductK / newVUSDC;
        shares = vIn - newVToken;
        if (shares == 0) revert ZeroShares();
        vUSDC = newVUSDC;
        if (_isYes) { vYES = newVToken; _rebalance(false); } 
        else { vNO = newVToken; _rebalance(true); }
        return shares;
    }

    function _sellTovAMM(bool _isYes, uint256 _shares) internal returns (uint256 usdcReceived) {
        if (_shares == 0) revert ZeroShares();
        uint256 vToken = _isYes ? vYES : vNO;
        uint256 newVToken = vToken + _shares;
        uint256 newVUSDC = constantProductK / newVToken;
        usdcReceived = vUSDC - newVUSDC;
        if (usdcReceived == 0) revert ZeroReturn();
        vUSDC = newVUSDC;
        if (_isYes) { vYES = newVToken; _rebalance(false); } 
        else { vNO = newVToken; _rebalance(true); }
        return usdcReceived;
    }

    function _rebalance(bool _updateYES) internal {
        if (_updateYES) { 
            uint256 priceNO = (vUSDC * 1e18) / vNO;
            if (priceNO > 99e16) priceNO = 99e16;
            vYES = (vUSDC * 1e18) / (1e18 - priceNO);
            emit Rebalanced(true, vUSDC, vYES);
        } else { 
            uint256 priceYES = (vUSDC * 1e18) / vYES;
            if (priceYES > 99e16) priceYES = 99e16;
            vNO = (vUSDC * 1e18) / (1e18 - priceYES);
            emit Rebalanced(false, vUSDC, vNO);
        }
    }

    function getCurrentPrice(bool _isYes) public view returns (uint256) {
        if (!phase2Active) return 0;
        if (_isYes) { return vYES > 0 ? (vUSDC * 1e18) / vYES : 0; } 
        else { return vNO > 0 ? (vUSDC * 1e18) / vNO : 0; }
    }
    
    function getHealthFactor(address _trader, bool _isYes) public view returns (uint256) {
        LeveragedPosition memory pos = positions[_trader][_isYes];
        if (!pos.active) return type(uint256).max;
        uint256 currentPrice = getCurrentPrice(_isYes);
        if (currentPrice == 0) return 0;
        uint256 currentValue18 = (pos.shares * currentPrice) / 1e18;
        uint256 currentValue6 = currentValue18 / SCALE_FACTOR;
        uint256 liquidationReq = (pos.loanAmount * LIQUIDATION_THRESHOLD) / BPS;
        if (currentValue6 == 0) return 0;
        return (currentValue6 * BPS) / liquidationReq;
    }
    
    function hasPosition(address _trader, bool _isYes) external view returns (bool) {
        return positions[_trader][_isYes].active;
    }
    
    function getBothHealthFactors(address _trader) external view returns (uint256 healthYes, uint256 healthNo) {
        healthYes = getHealthFactor(_trader, true);
        healthNo = getHealthFactor(_trader, false);
    }

    function previewOpen(bool _isYes, uint256 _collateral6, uint256 _leverage) external view returns (uint256 shares, uint256 priceImpact) {
        if (!phase2Active) return (0, 0);
        uint256 positionValue = _collateral6 * _leverage * SCALE_FACTOR;
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
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } } 
        else if (y != 0) { z = 1; }
    }
}