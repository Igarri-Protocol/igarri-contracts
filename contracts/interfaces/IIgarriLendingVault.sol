// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IIgarriLendingVault is IERC20 {
    event Staked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event Unstaked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event LoanFunded(uint256 amount);
    event LoanRepaid(uint256 principalRepaid, uint256 interestPaid);

    function igUSDC() external view returns (address);
    function realUSDC() external view returns (address);
    function vault() external view returns (address);
    function aavePool() external view returns (address);
    function aToken() external view returns (address);
    function marketFactory() external view returns (address);
    function totalBorrowed() external view returns (uint256);
    function allowedMarkets(address market) external view returns (bool);

    function addAllowedMarket(address _market) external;
    function totalAssets() external view returns (uint256);
    function stake(uint256 _amount) external;
    function unstake(uint256 _shares) external;
    function fundLoan(uint256 _amount) external;
    function repayLoan(uint256 _amount, uint256 _interest) external;
    function previewUserBalance(address _user) external view returns (uint256);
}