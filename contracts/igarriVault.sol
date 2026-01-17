// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IIgarriUSDC.sol";

contract IgarriVault is ReentrancyGuard {
    IERC20 public immutable realUSDC;
    IIgarriUSDC public igUSDC;
    mapping(address => bool) public allowedMarkets;
    address public igarriMarketFactory;
    
    address public owner;

    uint256 public constant SCALE_FACTOR = 10**12;

    event Deposited(address indexed user, uint256 realAmount, uint256 virtualAmount);
    event Redeemed(address indexed user, uint256 virtualAmount, uint256 realAmount);

    error TransferFailed();
    error Unauthorized();
    error InsufficientLiquidity();

    constructor(address _realUSDC) {
        realUSDC = IERC20(_realUSDC);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyIgarriMarketFactory() {
        if (msg.sender != igarriMarketFactory) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyAllowedMarket() {
        if (!allowedMarkets[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    /**
     * @notice Deposit USDC -> Mint igUSDC
     */
    function deposit(uint256 _amount) external nonReentrant {
        bool success = realUSDC.transferFrom(msg.sender, address(this), _amount);
        if (!success) revert TransferFailed();

        uint256 amountToMint = _amount * SCALE_FACTOR;
        igUSDC.mint(msg.sender, amountToMint);

        emit Deposited(msg.sender, _amount, amountToMint);
    }

    /**
     * @notice Burn igUSDC -> Redeem USDC 
     */
    function redeem(uint256 _amount) external nonReentrant {
        igUSDC.burn(msg.sender, _amount);

        uint256 amountToReturn = _amount / SCALE_FACTOR;
        
        if (realUSDC.balanceOf(address(this)) < amountToReturn) revert InsufficientLiquidity();

        bool success = realUSDC.transfer(msg.sender, amountToReturn);
        if (!success) revert TransferFailed();

        emit Redeemed(msg.sender, _amount, amountToReturn);
    }

    /**
     * @notice Adds a new allowed market
     * @param _newAllowedMarket The new allowed market address
     */
    function addAllowedMarket(address _newAllowedMarket) external onlyIgarriMarketFactory {
        allowedMarkets[_newAllowedMarket] = true;
    }

    /**
     * @notice Sets the Igarri USDC address
     */
    function setIgarriUSDC(address _igUSDC) external onlyOwner {
        igUSDC = IIgarriUSDC(_igUSDC);
    }

    /**
     * @notice Sets the Igarri Market Factory address
     */
    function setIgarriMarketFactory(address _igarriMarketFactory) external onlyOwner {
        igarriMarketFactory = _igarriMarketFactory;
    }
}