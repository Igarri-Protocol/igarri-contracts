// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

/**
 * @title IIgarriVault
 * @notice Interface for the Igarri Vault handling USDC deposits and igUSDC minting
 */
interface IIgarriVault {
    // --- Events ---
    event Deposited(address indexed user, uint256 realAmount, uint256 virtualAmount);
    event Redeemed(address indexed user, uint256 virtualAmount, uint256 realAmount);

    // --- State Views ---
    function realUSDC() external view returns (address);
    function igUSDC() external view returns (address);
    function igarriMarketFactory() external view returns (address);
    function allowedMarkets(address market) external view returns (bool);
    function SCALE_FACTOR() external view returns (uint256);
    function totalRealUSDCInVault() external view returns (uint256);

    // --- Core Functions ---
    function deposit(uint256 _amount) external;
    function redeem(uint256 _amount) external;

    // --- Restricted Admin/Factory Functions ---
    function addAllowedMarket(address _newAllowedMarket) external;
    function setIgarriUSDC(address _igUSDC) external;
    function setIgarriMarketFactory(address _igarriMarketFactory) external;
    function transferToMarket(address _market, uint256 _amount) external;

    function moveFundsToLendingPool(uint256 amount) external;
    function receiveFundsFromLendingPool(uint256 amount) external;
}