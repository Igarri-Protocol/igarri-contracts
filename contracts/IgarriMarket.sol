// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol"; 

import "./interfaces/IIgarriUSDC.sol";
import "./interfaces/IIgarriVault.sol";
import "./interfaces/IIgarriLendingVault.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IIgarriInsuranceFund.sol";
import "./interfaces/IRealityETH.sol";
import "./interfaces/IIgarriOutcomeToken.sol";

import "./common/Singleton.sol";
import "./common/StorageAccessible.sol";
import "./library/IgarriMathLib.sol"; 
import "./library/IgarriSignatureLib.sol";

contract IgarriMarket is Singleton, StorageAccessible, ReentrancyGuard {
    uint256 private constant K = 100;
    uint256 private constant MAX_LEVERAGE = 5; 
    uint256 private constant BPS = 10000;
    uint256 private constant SCALE_FACTOR = 10**12;

    // --- State ---
    address public serverSigner; 
    uint256 public migrationThreshold;
    uint256 public tradingEndTime; 
    
    IRealityETH public realityETH;
    bytes32 public questionID;
    bool public marketInvalidated;
    
    IIgarriUSDC public igUSDC;
    IERC20 public realUSDC;
    IIgarriOutcomeToken public yesToken; 
    IIgarriOutcomeToken public noToken;  
    
    IIgarriVault public vault;
    IIgarriLendingVault public lendingVault;
    IIgarriInsuranceFund public insuranceFund;

    uint256 public totalCapital;
    uint256 public currentSupply;
    bool public migrated;
    bool public phase2Active;

    uint256 public vUSDC;
    uint256 public vYES;
    uint256 public vNO;
    uint256 public constantProductK;

    struct LeveragedPosition {
        uint128 collateral;
        uint128 loanAmount;
        uint128 shares;
        uint128 entryPrice;
        uint64 openedAt;
        bool isYes;
        bool active;
    }

    mapping(address => mapping(bool => LeveragedPosition)) private _positions;
    uint256 public totalBorrowed;

    bool public marketResolved;
    bool public winningOutcomeIsYes;
    uint256 public settlementPrice18;
    uint256 public resolvedAt; 

    mapping(address => uint256) public nonces;

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
    event MarketCanceled();
    event WinningsClaimed(address indexed user, bool isPhase1, uint256 totalPayoutUSDC);

    // --- Errors ---
    error AlreadyInitialized();
    error NotAuthorized();
    error MarketMigrated();
    error TradingHalted();
    error MarketIsInvalid();
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
    error Phase2NotActive();
    error SignatureExpired();
    error ClaimTooEarly();

    // --- Modifier Routing (Saves massive bytecode duplication) ---
    function _checkPhase2() private view { if (!phase2Active) revert Phase2NotActive(); }
    modifier onlyPhase2() { _checkPhase2(); _; }

    function _checkBeforeEnd() private view { if (block.timestamp >= tradingEndTime) revert TradingHalted(); }
    modifier onlyBeforeEnd() { _checkBeforeEnd(); _; }

    function _checkNotInvalidated() private view { if (marketInvalidated) revert MarketIsInvalid(); }
    modifier notInvalidated() { _checkNotInvalidated(); _; }

    // --- Core Logic ---

    function initialize(
        address _igUSDC, 
        address _vault, 
        uint256 _migrationThreshold, 
        address _lendingVault, 
        address _serverSigner, 
        address _insuranceFund,
        uint256 _tradingEndTime,
        address _realityETH,     
        address _arbitrator,     
        uint32 _timeout,         
        string memory _question,
        address _yesToken,       
        address _noToken         
    ) external payable { 
        if (address(igUSDC) != address(0)) revert AlreadyInitialized();
        igUSDC = IIgarriUSDC(_igUSDC);
        vault = IIgarriVault(_vault);
        lendingVault = IIgarriLendingVault(_lendingVault);
        migrationThreshold = _migrationThreshold * SCALE_FACTOR;
        serverSigner = _serverSigner;
        tradingEndTime = _tradingEndTime; 
        
        realityETH = IRealityETH(_realityETH);
        realUSDC = IERC20(vault.realUSDC());
        
        yesToken = IIgarriOutcomeToken(_yesToken);
        noToken = IIgarriOutcomeToken(_noToken);
        
        realUSDC.approve(address(vault), type(uint256).max);
        realUSDC.approve(address(lendingVault), type(uint256).max);
        insuranceFund = IIgarriInsuranceFund(_insuranceFund);
        realUSDC.approve(address(insuranceFund), type(uint256).max);

        questionID = realityETH.askQuestion{value: msg.value}(0, _question, _arbitrator, _timeout, uint32(_tradingEndTime), 0);
    }

    function setServerSigner(address _newSigner) external {
        if (msg.sender != serverSigner) revert NotAuthorized();
        serverSigner = _newSigner;
        emit ServerSignerUpdated(_newSigner);
    }

    function buyShares(address _buyer, bool _isYes, uint256 _shareAmount, uint256 _deadline, bytes calldata _userSignature, bytes calldata _serverSignature) external nonReentrant onlyBeforeEnd notInvalidated { 
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (marketResolved) revert MarketAlreadyResolved();
        if (migrated) revert MarketMigrated();

        IgarriSignatureLib.verifyBuyShares(address(this), _buyer, _isYes, _shareAmount, _useNonce(_buyer), _deadline, _userSignature, _serverSignature, serverSigner);

        uint256 finalShareAmount = _shareAmount;
        (uint256 rawCost, uint256 fee) = IgarriMathLib.getQuote(currentSupply, _shareAmount);
        
        if (totalCapital + rawCost > migrationThreshold) {
            uint256 neededCapital = migrationThreshold - totalCapital;
            uint256 sStart = currentSupply;
            uint256 sEnd = IgarriMathLib.sqrt((2 * 1e24 * neededCapital / K) + (sStart**2));
            finalShareAmount = sEnd - sStart;
            (rawCost, fee) = IgarriMathLib.getQuote(currentSupply, finalShareAmount);
            if (totalCapital + rawCost >= migrationThreshold - 1e12) rawCost = migrationThreshold - totalCapital;
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
        phase2Active = true;
        uint256 vAmt = (migrationThreshold / SCALE_FACTOR) * SCALE_FACTOR;
        vUSDC = vAmt;
        vYES = vAmt * 2;
        vNO = vAmt * 2;
        constantProductK = vUSDC * vYES;
        emit Migrated(totalCapital, currentSupply);
        emit Phase2Activated(migrationThreshold / SCALE_FACTOR, constantProductK);
    }

    function openPosition(address _trader, bool _isYes, uint256 _collateral, uint256 _leverage, uint256 _minSharesExpected, uint256 _deadline, bytes calldata _userSignature, bytes calldata _serverSignature) external nonReentrant onlyPhase2 onlyBeforeEnd notInvalidated { 
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (_positions[_trader][_isYes].active) revert ActivePositionExists();
        if (_collateral < 10**6) revert MinCollateralNotMet();
        if (_leverage < 1 || _leverage > MAX_LEVERAGE) revert InvalidLeverage();

        IgarriSignatureLib.verifyOpenPosition(address(this), _trader, _isYes, _collateral, _leverage, _minSharesExpected, _useNonce(_trader), _deadline, _userSignature, _serverSignature, serverSigner);

        uint256 collateral18 = _collateral * SCALE_FACTOR;
        igUSDC.transferFrom(_trader, address(this), collateral18);
        igUSDC.approve(address(vault), collateral18);
        vault.redeem(collateral18);

        uint256 loanAmount = _collateral * (_leverage - 1);
        if (loanAmount > 0) lendingVault.fundLoan(loanAmount);

        uint256 sharesReceived = _buyFromvAMM(_isYes, _collateral * _leverage * SCALE_FACTOR);
        if (sharesReceived < _minSharesExpected) revert SlippageExceeded();
        
        _positions[_trader][_isYes] = LeveragedPosition({
            collateral: uint128(_collateral), loanAmount: uint128(loanAmount), shares: uint128(sharesReceived),
            isYes: _isYes, entryPrice: uint128(getCurrentPrice(_isYes)), active: true, openedAt: uint64(block.timestamp) 
        });
        
        totalBorrowed += loanAmount;
        _updateOI(_isYes, sharesReceived, true);

        emit PositionOpened(_trader, _isYes, _collateral, loanAmount, sharesReceived, uint256(_positions[_trader][_isYes].entryPrice));
    }

    function closePosition(address _trader, bool _isYes, uint256 _minUSDCReturned, uint256 _deadline, bytes calldata _userSignature, bytes calldata _serverSignature) external nonReentrant onlyPhase2 onlyBeforeEnd notInvalidated { 
        if (block.timestamp > _deadline) revert SignatureExpired();
        
        IgarriSignatureLib.verifyClosePosition(address(this), _trader, _isYes, _minUSDCReturned, _useNonce(_trader), _deadline, _userSignature, _serverSignature, serverSigner);

        LeveragedPosition storage pos = _positions[_trader][_isYes];
        if (!pos.active) revert NoActivePosition();

        uint256 usdcReturned18 = _sellTovAMM(_isYes, uint256(pos.shares));
        if (usdcReturned18 < _minUSDCReturned) revert SlippageExceeded();

        (uint256 userPayout6, ) = _settleDebt(usdcReturned18 / SCALE_FACTOR, uint256(pos.loanAmount), uint256(pos.openedAt));
        
        if (userPayout6 > 0) _payoutRoute(_trader, userPayout6);
        _updateOI(_isYes, uint256(pos.shares), false);
        pos.active = false;
        
        int256 pnl;
        unchecked { pnl = int256(userPayout6) - int256(uint256(pos.collateral)); }
        emit PositionClosed(_trader, _isYes, userPayout6, uint256(pos.loanAmount), pnl);
    }
    
    function liquidatePosition(address _trader, bool _isYes) external nonReentrant onlyPhase2 onlyBeforeEnd notInvalidated { 
        _liquidate(_trader, _isYes, msg.sender);
    }
    
    function bulkLiquidate(address[] calldata _traders, bool[] calldata _isYesSides, uint256 _deadline, bytes calldata _serverSignature) external nonReentrant onlyPhase2 onlyBeforeEnd notInvalidated returns (uint256 liquidatedCount) { 
        if (block.timestamp > _deadline) revert SignatureExpired();
        if (_traders.length != _isYesSides.length) revert ArrayLengthMismatch();

        IgarriSignatureLib.verifyBulkLiquidate(address(this), _traders, _isYesSides, _useNonce(msg.sender), _deadline, _serverSignature, serverSigner);

        for (uint i = 0; i < _traders.length; i++) {
            if (!_positions[_traders[i]][_isYesSides[i]].active) continue;
            if (getHealthFactor(_traders[i], _isYesSides[i]) < BPS) {
                _liquidate(_traders[i], _isYesSides[i], msg.sender);
                liquidatedCount++;
            }
        }
        emit BulkLiquidationExecuted(liquidatedCount);
    }

    function _liquidate(address _trader, bool _isYes, address _keeper) internal {
        LeveragedPosition storage pos = _positions[_trader][_isYes];
        if (!pos.active) revert NoActivePosition();
        if (getHealthFactor(_trader, _isYes) >= BPS) revert PositionIsHealthy();

        uint256 usdcReturned18 = _sellTovAMM(_isYes, uint256(pos.shares));
        (uint256 surplus6, ) = _settleDebt(usdcReturned18 / SCALE_FACTOR, uint256(pos.loanAmount), uint256(pos.openedAt));
        
        uint256 keeperReward = 0;
        uint256 traderRefund = 0;

        if (surplus6 > 0) {
            uint256 insuranceFee = (surplus6 * 1000) / BPS;
            if (insuranceFee > 0) insuranceFund.depositFee(insuranceFee);
            uint256 remainingSurplus = surplus6 - insuranceFee;
            keeperReward = (remainingSurplus * 500) / BPS; 
            traderRefund = remainingSurplus - keeperReward;
        }

        if (keeperReward > 0) _payoutRoute(_keeper, keeperReward);
        if (traderRefund > 0) _payoutRoute(_trader, traderRefund);
        
        _updateOI(_isYes, uint256(pos.shares), false);
        pos.active = false;
        
        emit PositionLiquidated(_trader, _isYes, _keeper, keeperReward, uint256(pos.loanAmount), traderRefund);
    }

    function resolveMarket() external nonReentrant {
        if (marketResolved || marketInvalidated) revert MarketAlreadyResolved();
        
        bytes32 result = realityETH.resultFor(questionID);
        
        if (result == bytes32(uint256(1))) {
            winningOutcomeIsYes = true;
        } else if (result == bytes32(uint256(0))) {
            winningOutcomeIsYes = false;
        } else {
            marketInvalidated = true;
            phase2Active = false;
            emit MarketCanceled();
            return;
        }

        marketResolved = true;
        phase2Active = false; 
        resolvedAt = block.timestamp; 

        if (!migrated) {
            uint256 igBalance = igUSDC.balanceOf(address(this));
            if (igBalance > 0) {
                igUSDC.approve(address(vault), igBalance);
                vault.redeem(igBalance); 
            }
        }

        uint256 totalWinningShares18 = winningOutcomeIsYes ? (yesToken.totalSupply() + phase2YesOI) : (noToken.totalSupply() + phase2NoOI);
        uint256 availableUSDC6 = realUSDC.balanceOf(address(this));
        uint256 liabilities6 = totalWinningShares18 / SCALE_FACTOR; 
        
        if (liabilities6 <= availableUSDC6 || liabilities6 == 0) {
            settlementPrice18 = 1e18;
        } else {
            settlementPrice18 = (availableUSDC6 * 1e18) / liabilities6;
        }
        emit MarketResolved(winningOutcomeIsYes, settlementPrice18);
    }

    function cancelAndRefundPosition(address _trader, bool _isYes) external nonReentrant {
        if (!marketInvalidated) revert MarketNotResolved();

        LeveragedPosition storage pos = _positions[_trader][_isYes];
        if (!pos.active) revert NoActivePosition();

        uint256 collateralToReturn = uint256(pos.collateral);
        
        if (pos.loanAmount > 0) {
            lendingVault.repayLoan(uint256(pos.loanAmount), 0);
            totalBorrowed -= uint256(pos.loanAmount);
        }

        _updateOI(_isYes, uint256(pos.shares), false);
        pos.active = false;

        _payoutRoute(_trader, collateralToReturn);
    }

    function claimWinningsFor(address _user, bool _isPhase1, UserTier _tier, uint256 _deadline, bytes calldata _serverSignature) external nonReentrant {
        if (!marketResolved) revert MarketNotResolved();
        if (block.timestamp > _deadline) revert SignatureExpired();

        IgarriSignatureLib.verifyClaimTier(address(this), _user, uint8(_tier), _useNonce(_user), _deadline, _serverSignature, serverSigner);

        uint256 payout6 = _isPhase1 ? _processPhase1Claim(_user) : _processPhase2Claim(_user, false, _tier);
        if (payout6 > 0) _payoutRoute(_user, payout6); 
        emit WinningsClaimed(_user, _isPhase1, payout6);
    }

    function sweepUnclaimed(address _user, bool _isPhase1) external nonReentrant {
        if (msg.sender != serverSigner) revert NotAuthorized();
        if (!marketResolved) revert MarketNotResolved();
        if (block.timestamp < resolvedAt + 30 days) revert ClaimTooEarly();

        uint256 payout6 = _isPhase1 ? _processPhase1Claim(_user) : _processPhase2Claim(_user, true, UserTier.Standard);
        
        if (payout6 > 0) {
            vault.deposit(payout6);
            igUSDC.transfer(address(insuranceFund), payout6 * SCALE_FACTOR);
        }
        emit WinningsClaimed(_user, _isPhase1, payout6); 
    }
    
    // --- Internal Helpers ---

    function _processPhase2Claim(address _user, bool _isSweep, UserTier _tier) internal returns (uint256 payout6) {
        LeveragedPosition storage pos = _positions[_user][winningOutcomeIsYes];
        if (!pos.active) revert NoWinningPhase2Position();

        uint256 grossValue6 = (uint256(pos.shares) * settlementPrice18) / 1e18 / SCALE_FACTOR;
        bool isSolvent;
        
        (payout6, isSolvent) = _settleDebt(grossValue6, uint256(pos.loanAmount), uint256(pos.openedAt));

        if (!_isSweep && isSolvent) {
            uint256 yieldMultiplier = _tier == UserTier.FanToken ? 20 : (_tier == UserTier.Early ? 15 : 10);
            payout6 += (((uint256(pos.collateral) * 5) / 100) * yieldMultiplier) / 10;
        }

        _updateOI(winningOutcomeIsYes, uint256(pos.shares), false);
        pos.active = false;
    }

    function _settleDebt(uint256 _value6, uint256 _loanAmount, uint256 _openedAt) internal returns (uint256 surplus6, bool isSolvent) {
        uint256 interestOwed = IgarriMathLib.calculateInterest(_loanAmount, _openedAt, block.timestamp);
        uint256 totalDebt = _loanAmount + interestOwed;

        if (_value6 >= totalDebt) {
            surplus6 = _value6 - totalDebt;
            isSolvent = true;
        } else {
            insuranceFund.coverBadDebt(totalDebt - _value6);
            surplus6 = 0;
            isSolvent = false;
        }

        if (_loanAmount > 0 || interestOwed > 0) {
            lendingVault.repayLoan(_loanAmount, interestOwed);
            if (_loanAmount > 0) totalBorrowed -= _loanAmount;
        }
    }

    function _processPhase1Claim(address _user) internal returns (uint256) {
        uint256 userShares = winningOutcomeIsYes ? yesToken.balanceOf(_user) : noToken.balanceOf(_user);
        if (userShares == 0) revert NoWinningPhase1Shares();
        
        if (winningOutcomeIsYes) yesToken.burn(_user, userShares);
        else noToken.burn(_user, userShares);
        
        return (userShares * settlementPrice18) / 1e18 / SCALE_FACTOR;
    }

    function _useNonce(address _owner) internal returns (uint256) {
        return nonces[_owner]++;
    }

    function _payoutRoute(address _to, uint256 _amount6) internal {
        vault.deposit(_amount6);
        igUSDC.transfer(_to, _amount6 * SCALE_FACTOR);
    }

    function _updateOI(bool _isYes, uint256 _shares, bool _isAdd) internal {
        if (_isYes) { if (_isAdd) phase2YesOI += _shares; else phase2YesOI -= _shares; } 
        else { if (_isAdd) phase2NoOI += _shares; else phase2NoOI -= _shares; }
    }

    function _applyAMMState(bool _isYes, uint256 _newVUSDC, uint256 _newVToken) internal {
        vUSDC = _newVUSDC;
        if (_isYes) { 
            vYES = _newVToken; 
            vNO = IgarriMathLib.getRebalancePrice(vUSDC, vYES);
        } else { 
            vNO = _newVToken; 
            vYES = IgarriMathLib.getRebalancePrice(vUSDC, vNO);
        }
        emit Rebalanced(!_isYes, vUSDC, _isYes ? vNO : vYES);
    }

    function _buyFromvAMM(bool _isYes, uint256 _usdcAmount18) internal returns (uint256 shares) {
        uint256 newVToken;
        uint256 newVUSDC;
        (newVUSDC, newVToken, shares) = IgarriMathLib.buyFromvAMM(vUSDC, _isYes ? vYES : vNO, constantProductK, _usdcAmount18);
        _applyAMMState(_isYes, newVUSDC, newVToken);
        return shares;
    }

    function _sellTovAMM(bool _isYes, uint256 _shares) internal returns (uint256 usdcReceived) {
        uint256 newVToken;
        uint256 newVUSDC;
        (newVUSDC, newVToken, usdcReceived) = IgarriMathLib.sellTovAMM(vUSDC, _isYes ? vYES : vNO, constantProductK, _shares);
        _applyAMMState(_isYes, newVUSDC, newVToken);
        return usdcReceived;
    }

    // --- View Functions ---

    function getCurrentPrice(bool _isYes) public view returns (uint256) {
        if (!phase2Active) {
            return (K * currentSupply) / 1e6; 
        }
        if (_isYes) { 
            return vYES > 0 ? (vUSDC * 1e18) / vYES : 0; 
        } else { 
            return vNO > 0 ? (vUSDC * 1e18) / vNO : 0; 
        }
    }

    function getHealthFactor(address _trader, bool _isYes) public view returns (uint256) {
        LeveragedPosition memory pos = _positions[_trader][_isYes];
        if (!pos.active) return type(uint256).max;
        return IgarriMathLib.getHealthFactor(uint256(pos.shares), uint256(pos.loanAmount), getCurrentPrice(_isYes));
    }
    
    function previewOpen(bool _isYes, uint256 _collateral6, uint256 _leverage) external view returns (uint256 shares, uint256 priceImpact) {
        if (!phase2Active) return (0, 0);
        uint256 vIn = _isYes ? vYES : vNO;
        return IgarriMathLib.previewOpen(vUSDC, vIn, constantProductK, _collateral6 * _leverage * SCALE_FACTOR);
    }

    // @audit Expose position info manually since it is now private
    function getPosition(address _trader, bool _isYes) external view returns (LeveragedPosition memory) {
        return _positions[_trader][_isYes];
    }
}