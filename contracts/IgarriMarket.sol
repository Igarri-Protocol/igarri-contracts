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

    error InvalidSignature();
    error SignatureExpired();
    error AccessDenied();

    constructor() EIP712("IgarriMarket", "1") {
        igUSDC = IIgarriUSDC(address(0x1));
    }

    modifier onlyPhase2() { require(phase2Active, "Phase 2 not active"); _; }
    modifier noActivePosition(bool _isYes) { 
        require(!positions[msg.sender][_isYes].active, "Active position exists"); 
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
        require(address(igUSDC) == address(0), "Already initialized");
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
        require(msg.sender == serverSigner, "Not authorized");
        serverSigner = _newSigner;
        emit ServerSignerUpdated(_newSigner);
    }

    // --- PHASE 1 (UPDATED with Server Signatures) ---
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
        require(!migrated, "Market migrated");

        bytes32 structHash = keccak256(abi.encode(
            BUY_SHARES_TYPEHASH, 
            _buyer, 
            _isYes, 
            _shareAmount, 
            _useNonce(_buyer), 
            _deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        
        if (!SignatureChecker.isValidSignatureNow(_buyer, digest, _userSignature)) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSignature)) revert InvalidSignature();

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
        require(!positions[_trader][_isYes].active, "Active position exists");
        require(_collateral >= 10**6, "Min 1 USDC");
        require(_leverage >= 1 && _leverage <= MAX_LEVERAGE, "Invalid leverage");

        bytes32 structHash = keccak256(abi.encode(
            OPEN_POSITION_TYPEHASH, 
            _trader, 
            _isYes, 
            _collateral,
            _leverage, 
            _minSharesExpected, 
            _useNonce(_trader), 
            _deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        
        if (!SignatureChecker.isValidSignatureNow(_trader, digest, _userSignature)) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSignature)) revert InvalidSignature();

        uint256 collateral18 = _collateral * SCALE_FACTOR;
        igUSDC.transferFrom(_trader, address(this), collateral18);
        igUSDC.approve(address(vault), collateral18);
        vault.redeem(collateral18);

        uint256 loanAmount = _collateral * (_leverage - 1);
        if (loanAmount > 0) {
            lendingVault.fundLoan(loanAmount);
        }

        uint256 totalPositionUSDC = _collateral * _leverage * SCALE_FACTOR;
        uint256 sharesReceived = _buyFromvAMM(_isYes, totalPositionUSDC);
        require(sharesReceived >= _minSharesExpected, "Slippage");
        
        positions[_trader][_isYes] = LeveragedPosition({
            collateral: _collateral,
            loanAmount: loanAmount,
            shares: sharesReceived,
            isYes: _isYes,
            entryPrice: getCurrentPrice(_isYes),
            active: true
        });
        totalBorrowed += loanAmount;
        emit PositionOpened(_trader, _isYes, _collateral, loanAmount, sharesReceived, positions[_trader][_isYes].entryPrice);
    }

    function closePosition(address _trader, bool _isYes, uint256 _minUSDCReturned, uint256 _deadline, bytes calldata _userSignature, bytes calldata _serverSignature) external nonReentrant onlyPhase2 {
        if (block.timestamp > _deadline) revert SignatureExpired();
        bytes32 structHash = keccak256(abi.encode(CLOSE_POSITION_TYPEHASH, _trader, _isYes, _minUSDCReturned, _useNonce(_trader), _deadline));
        bytes32 digest = _hashTypedDataV4(structHash);
        
        if (!SignatureChecker.isValidSignatureNow(_trader, digest, _userSignature)) revert InvalidSignature();
        if (!SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSignature)) revert InvalidSignature();

        LeveragedPosition storage pos = positions[_trader][_isYes];
        require(pos.active, "No active position");
        uint256 usdcReturned18 = _sellTovAMM(_isYes, pos.shares);
        require(usdcReturned18 >= _minUSDCReturned, "Slippage");
        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        uint256 amountToRepay = usdcReturned6 >= pos.loanAmount ? pos.loanAmount : usdcReturned6;
        uint256 userPayout6 = usdcReturned6 > pos.loanAmount ? usdcReturned6 - pos.loanAmount : 0;

        if (amountToRepay > 0) lendingVault.repayLoan(amountToRepay, 0);
        if (userPayout6 > 0) {
            vault.deposit(userPayout6);
            uint256 igMinted = userPayout6 * SCALE_FACTOR;
            igUSDC.transfer(_trader, igMinted);
        }
        totalBorrowed -= amountToRepay;
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
        require(_traders.length == _isYesSides.length, "Mismatch");

        bytes32 payloadHash = keccak256(abi.encode(_traders, _isYesSides));

        bytes32 structHash = keccak256(abi.encode(
            BULK_LIQUIDATE_TYPEHASH,
            payloadHash,
            _useNonce(msg.sender), 
            _deadline
        ));

        bytes32 digest = _hashTypedDataV4(structHash);
        
        if (!SignatureChecker.isValidSignatureNow(serverSigner, digest, _serverSignature)) revert InvalidSignature();

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
        require(pos.active, "No active position");
        require(getHealthFactor(_trader, _isYes) < BPS, "Healthy");

        uint256 usdcReturned18 = _sellTovAMM(_isYes, pos.shares);
        uint256 usdcReturned6 = usdcReturned18 / SCALE_FACTOR;
        
        uint256 amountToRepay;
        uint256 keeperReward;
        uint256 traderRefund;

        if (usdcReturned6 < pos.loanAmount) {
            uint256 shortfall = pos.loanAmount - usdcReturned6;
            insuranceFund.coverBadDebt(shortfall);
            amountToRepay = pos.loanAmount; 
            keeperReward = 0;
            traderRefund = 0;
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

        if (amountToRepay > 0) lendingVault.repayLoan(amountToRepay, 0);

        if (keeperReward > 0) {
            vault.deposit(keeperReward);
            igUSDC.transfer(_keeper, keeperReward * SCALE_FACTOR);
        }
        if (traderRefund > 0) {
            vault.deposit(traderRefund);
            igUSDC.transfer(_trader, traderRefund * SCALE_FACTOR);
        }

        totalBorrowed -= amountToRepay;
        pos.active = false;
        emit PositionLiquidated(_trader, _isYes, _keeper, keeperReward, amountToRepay, traderRefund);
    }

    // --- vAMM & VIEW FUNCTIONS ---
    function _buyFromvAMM(bool _isYes, uint256 _usdcAmount18) internal returns (uint256 shares) {
        uint256 vIn = _isYes ? vYES : vNO;
        uint256 newVUSDC = vUSDC + _usdcAmount18;
        uint256 newVToken = constantProductK / newVUSDC;
        shares = vIn - newVToken;
        require(shares > 0, "Zero shares");
        vUSDC = newVUSDC;
        if (_isYes) { vYES = newVToken; _rebalanceNO(); } 
        else { vNO = newVToken; _rebalanceYES(); }
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
        if (_isYes) { vYES = newVToken; _rebalanceNO(); } 
        else { vNO = newVToken; _rebalanceYES(); }
        return usdcReceived;
    }

    function _rebalanceNO() internal {
        uint256 priceYES = (vUSDC * 1e18) / vYES;
        if (priceYES > 99e16) priceYES = 99e16;
        uint256 targetPriceNO = 1e18 - priceYES;
        vNO = (vUSDC * 1e18) / targetPriceNO;
        emit Rebalanced(false, vUSDC, vNO);
    }

    function _rebalanceYES() internal {
        uint256 priceNO = (vUSDC * 1e18) / vNO;
        if (priceNO > 99e16) priceNO = 99e16;
        uint256 targetPriceYES = 1e18 - priceNO;
        vYES = (vUSDC * 1e18) / targetPriceYES;
        emit Rebalanced(true, vUSDC, vYES);
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