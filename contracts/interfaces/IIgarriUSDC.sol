// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IIgarriUSDC is IERC20 {
    // --- Events ---
    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event VaultUpdated(address indexed oldVault, address indexed newVault);
    event MarketAllowed(address indexed market);

    // --- State View Functions ---
    function igarriVault() external view returns (address);
    function igarriMarketFactory() external view returns (address);
    function allowedMarkets(address market) external view returns (bool);

    // --- Restricted Logic ---
    function setManager(address _newManager) external;
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function changeIgarriVault(address _newIgarriVault) external;
    function addAllowedMarket(address _newAllowedMarket) external;
}