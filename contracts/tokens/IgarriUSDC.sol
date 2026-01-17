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

    modifier onlyAllowedMarket() {
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

    /**
     * @notice Updates which contract has the power to move tokens
     */
    function setManager(address _newManager) external onlyAuthorized {
        authorizedManager = _newManager;
    }

    /**
     * @dev Overriding transfer to restrict access
     */
    function transfer(address to, uint256 amount) public override onlyAllowedMarket() returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    /**
     * @dev Overriding transferFrom to restrict access
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override onlyAllowedMarket() returns (bool) {
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Minting is handled by the igarri vault
     */
    function mint(address to, uint256 amount) external onlyIgarriVault {
        _mint(to, amount);
    }

    /**
     * @notice Burning is handled by the igarri vault
     */
    function burn(address from, uint256 amount) external onlyIgarriVault {
        _burn(from, amount);
    }

    /**
     * @notice Changes the Igarri Vault address
     * @param _newIgarriVault The new Igarri Vault address
     */
    function changeIgarriVault(address _newIgarriVault) external onlyAuthorized {
        igarriVault = _newIgarriVault;
    }

    /**
     * @notice Adds a new allowed market
     * @param _newAllowedMarket The new allowed market address
     */
    function addAllowedMarket(address _newAllowedMarket) external onlyIgarriMarketFactory {
        allowedMarkets[_newAllowedMarket] = true;
    }
}