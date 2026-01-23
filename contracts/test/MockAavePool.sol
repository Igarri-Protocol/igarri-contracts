// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

contract MockAavePool {
    event Supply(address indexed user, uint256 amount, address onBehalfOf, uint16 referralCode);
    event Withdraw(address indexed user, uint256 amount);

    IMintableERC20 public yieldToken;

    constructor(address _yieldToken) {
        yieldToken = IMintableERC20(_yieldToken);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        yieldToken.mint(onBehalfOf, amount);

        emit Supply(msg.sender, amount, onBehalfOf, referralCode);
    }

    function withdraw(address asset, uint256 amount, address to) external {
        yieldToken.burn(msg.sender, amount);
        IERC20(asset).transfer(to, amount);

        emit Withdraw(msg.sender, amount);
    }

    function simulateInterest(address vault, uint256 interestAmount) external {
        yieldToken.mint(vault, interestAmount);
    }
}