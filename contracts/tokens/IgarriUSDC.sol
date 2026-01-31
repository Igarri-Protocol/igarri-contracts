// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract IgarriUSDC is ERC20 {

    address public igarriVault;
    mapping(address => bool) public allowedMarkets;
    address public igarriMarketFactory;
    
    address private authorizedManager;

    error NotAuthorized();

    constructor(
        address _manager,
        address _igarriVault,
        address _igarriMarketFactory
    ) ERC20("IgarriUSDC", "igUSDC") {
        authorizedManager = _manager;
        igarriVault = _igarriVault;
        igarriMarketFactory = _igarriMarketFactory;
    }

    modifier onlyAuthorized() {
        if (msg.sender != authorizedManager) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyIgarriVault() {
        if (msg.sender != igarriVault) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyAllowed() {
        if (!allowedMarkets[msg.sender]) {
            revert NotAuthorized();
        }
        _;
    }

    modifier onlyIgarriMarketFactory() {
        if (msg.sender != igarriMarketFactory) {
            revert NotAuthorized();
        }
        _;
    }

    function setManager(address _newManager) external onlyAuthorized {
        authorizedManager = _newManager;
    }

    function transfer(address to, uint256 amount) public override onlyAllowed() returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override onlyAllowed() returns (bool) {
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external onlyIgarriVault {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyIgarriVault {
        _burn(from, amount);
    }

    function changeIgarriVault(address _newIgarriVault) external onlyAuthorized {
        igarriVault = _newIgarriVault;
    }

    function addAllowedMarket(address _newAllowedMarket) external {
        if (msg.sender != igarriMarketFactory && msg.sender != authorizedManager) {
            revert NotAuthorized();
        }
        allowedMarkets[_newAllowedMarket] = true;
    }
}