// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

library IgarriMathLib {
    uint256 public constant K = 100;
    uint256 public constant INSURANCE_FEE_BPS = 50;
    uint256 public constant LIQUIDATION_THRESHOLD = 12000;
    uint256 public constant BPS = 10000;
    uint256 public constant SCALE_FACTOR = 10**12;
    uint256 public constant BORROW_RATE_BPS = 1000;

    error ZeroShares();
    error ZeroReturn();

    function getQuote(uint256 currentSupply, uint256 amount) external pure returns (uint256 rawCost, uint256 fee) {
        uint256 sEnd = currentSupply + amount;
        rawCost = (K * (sEnd**2 - currentSupply**2)) / (2 * 1e24);
        fee = (rawCost * INSURANCE_FEE_BPS) / BPS;
    }

    function sqrt(uint256 y) external pure returns (uint256 z) {
        if (y > 3) { z = y; uint256 x = y / 2 + 1; while (x < z) { z = x; x = (y / x + x) / 2; } } 
        else if (y != 0) { z = 1; }
    }

    function calculateInterest(uint256 loanAmount, uint256 openedAt, uint256 currentTime) external pure returns (uint256) {
        if (openedAt == 0 || loanAmount == 0) return 0;
        return (loanAmount * BORROW_RATE_BPS * (currentTime - openedAt)) / (BPS * 365 days);
    }

    function getHealthFactor(uint256 shares, uint256 loanAmount, uint256 currentPrice) external pure returns (uint256) {
        if (loanAmount == 0) return type(uint256).max;
        uint256 currentValue6 = (shares * currentPrice) / 1e18 / SCALE_FACTOR;
        if (currentValue6 == 0) return 0;
        return (currentValue6 * BPS) / ((loanAmount * LIQUIDATION_THRESHOLD) / BPS);
    }

    function buyFromvAMM(uint256 _vUSDC, uint256 _vToken, uint256 _k, uint256 _usdcAmount18) external pure returns (uint256 newVUSDC, uint256 newVToken, uint256 shares) {
        newVUSDC = _vUSDC + _usdcAmount18;
        newVToken = _k / newVUSDC;
        shares = _vToken - newVToken;
        if (shares == 0) revert ZeroShares();
    }

    function sellTovAMM(uint256 _vUSDC, uint256 _vToken, uint256 _k, uint256 _shares) external pure returns (uint256 newVUSDC, uint256 newVToken, uint256 usdcReceived) {
        if (_shares == 0) revert ZeroShares();
        newVToken = _vToken + _shares;
        newVUSDC = _k / newVToken;
        usdcReceived = _vUSDC - newVUSDC;
        if (usdcReceived == 0) revert ZeroReturn();
    }

    function getRebalancePrice(uint256 vUSDC, uint256 vToken) external pure returns (uint256) {
        uint256 price = (vUSDC * 1e18) / vToken;
        if (price > 99e16) price = 99e16;
        return (vUSDC * 1e18) / (1e18 - price);
    }

    function previewOpen(uint256 _vUSDC, uint256 _vIn, uint256 _k, uint256 _positionValue) external pure returns (uint256 shares, uint256 priceImpact) {
        uint256 newVUSDC = _vUSDC + _positionValue;
        uint256 newVToken = _k / newVUSDC;
        shares = _vIn - newVToken;
        
        uint256 spotPriceBefore = (_vUSDC * 1e18) / _vIn;
        uint256 spotPriceAfter = (newVUSDC * 1e18) / newVToken;
        priceImpact = ((spotPriceAfter - spotPriceBefore) * BPS) / spotPriceBefore;
    }
}