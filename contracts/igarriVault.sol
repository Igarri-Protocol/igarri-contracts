// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IIgarriUSDC.sol";
import "./interfaces/IAavePool.sol";

contract IgarriVault is ReentrancyGuard {
    IERC20 public immutable realUSDC;
    IIgarriUSDC public igUSDC;
    mapping(address => bool) public allowedMarkets;
    address public igarriMarketFactory;
    IAavePool public aavePool;
    
    address public lendingVault; 

    IERC20 public yieldToken;
    uint256 public totalRealUSDCInVault;

    address public owner;

    uint256 public constant SCALE_FACTOR = 10**12;

    event Deposited(address indexed user, uint256 realAmount, uint256 virtualAmount);
    event Redeemed(address indexed user, uint256 virtualAmount, uint256 realAmount);
    event FundsMovedToLending(uint256 realAmount);
    event FundsReceivedFromLending(uint256 realAmount);

    error TransferFailed();
    error Unauthorized();
    error InsufficientLiquidity();

    constructor(address _realUSDC, address _aavePool, address _yieldToken) {
        realUSDC = IERC20(_realUSDC);
        aavePool = IAavePool(_aavePool);
        yieldToken = IERC20(_yieldToken);

        realUSDC.approve(address(aavePool), type(uint256).max);

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

    modifier onlyLendingVault() {
        if (msg.sender != lendingVault) {
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

        aavePool.supply(address(realUSDC), _amount, address(this), 0);

        totalRealUSDCInVault += _amount;

        emit Deposited(msg.sender, _amount, amountToMint);
    }

    /**
     * @notice Burn igUSDC -> Redeem USDC 
     */
    function redeem(uint256 _amount) external nonReentrant {
        igUSDC.burn(msg.sender, _amount);

        uint256 amountToReturn = _amount / SCALE_FACTOR;
        
        aavePool.withdraw(address(realUSDC), amountToReturn, msg.sender);

        totalRealUSDCInVault -= amountToReturn;

        emit Redeemed(msg.sender, _amount, amountToReturn);
    }

    /**
     * @notice Transfer real USDC to a market
     */
    function transferToMarket(address _market, uint256 _amount) external nonReentrant onlyAllowedMarket() {
        uint256 amountToTransfer = _amount / SCALE_FACTOR;

        aavePool.withdraw(address(realUSDC), amountToTransfer, _market);

        totalRealUSDCInVault -= amountToTransfer;
    }

    /**
     * @notice Sets the Lending Vault address
     */
    function setLendingVault(address _lendingVault) external onlyOwner {
        lendingVault = _lendingVault;
    }

    /**
     * @notice Moves underlying realUSDC to the Lending Vault when a user stakes igUSDC
     * @param _igUsdcAmount The amount of igUSDC the user staked
     */
    function moveFundsToLendingPool(uint256 _igUsdcAmount) external nonReentrant onlyLendingVault {
        uint256 realAmount = _igUsdcAmount / SCALE_FACTOR;

        // 1. BURN the igUSDC held by the Lending Vault
        // This ensures igUSDC supply shrinks when backing assets leave
        igUSDC.burn(msg.sender, _igUsdcAmount);

        aavePool.withdraw(address(realUSDC), realAmount, address(this));

        totalRealUSDCInVault -= realAmount;

        bool success = realUSDC.transfer(lendingVault, realAmount);
        if (!success) revert TransferFailed();

        emit FundsMovedToLending(realAmount);
    }

    /**
     * @notice Receives underlying realUSDC from Lending Vault when a user unstakes
     * @param _realUsdcAmount The amount of realUSDC returning
     */
    function receiveFundsFromLendingPool(uint256 _realUsdcAmount) external nonReentrant onlyLendingVault {
        bool success = realUSDC.transferFrom(msg.sender, address(this), _realUsdcAmount);
        if (!success) revert TransferFailed();

        aavePool.supply(address(realUSDC), _realUsdcAmount, address(this), 0);
        totalRealUSDCInVault += _realUsdcAmount;

        // 2. MINT new igUSDC to the Lending Vault
        // This creates the tokens for Principal + Yield
        uint256 igToMint = _realUsdcAmount * SCALE_FACTOR;
        igUSDC.mint(msg.sender, igToMint);

        emit FundsReceivedFromLending(_realUsdcAmount);
    }

    function addAllowedMarket(address _newAllowedMarket) external onlyIgarriMarketFactory {
        allowedMarkets[_newAllowedMarket] = true;
    }

    function setIgarriUSDC(address _igUSDC) external onlyOwner {
        igUSDC = IIgarriUSDC(_igUSDC);
    }

    function setIgarriMarketFactory(address _igarriMarketFactory) external onlyOwner {
        igarriMarketFactory = _igarriMarketFactory;
    }

    function setAavePool(address _aavePool) external onlyOwner {
        aavePool = IAavePool(_aavePool);
        realUSDC.approve(_aavePool, type(uint256).max);
    }

    function setYieldToken(address _yieldToken) external onlyOwner {
        yieldToken = IERC20(_yieldToken);
    }

    function withdrawYields(address _to) external onlyOwner {
        uint256 actualBalance = IERC20(yieldToken).balanceOf(address(this));
       if (actualBalance > totalRealUSDCInVault) {
           uint256 amountToWithdraw = actualBalance - totalRealUSDCInVault;
           aavePool.withdraw(address(realUSDC), amountToWithdraw, _to);
       }
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }
}