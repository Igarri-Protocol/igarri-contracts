// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IAavePool {
    event Supply(address indexed user, uint256 amount, address onBehalfOf, uint16 referralCode);
    event Withdraw(address indexed user, uint256 amount);

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external;
}
