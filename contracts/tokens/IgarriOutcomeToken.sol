// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract IgarriOutcomeToken is ERC20 {
    address public immutable market;

    error OnlyMarket();

    constructor(string memory name, string memory symbol, address _market) ERC20(name, symbol) {
        market = _market;
    }

    modifier onlyMarket() {
        if (msg.sender != market) revert OnlyMarket();
        _;
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }

    function transferFrom(address, address, uint256) public pure override returns (bool) {
        revert("Transfers disabled");
    }

    function mint(address to, uint256 amount) external onlyMarket {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyMarket {
        _burn(from, amount);
    }
}