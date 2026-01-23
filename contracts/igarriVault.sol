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

    IERC20 public yieldToken;
    uint256 public totalRealUSDCInVault;

    address public owner;

    uint256 public constant SCALE_FACTOR = 10**12;


    event Deposited(address indexed user, uint256 realAmount, uint256 virtualAmount);
    event Redeemed(address indexed user, uint256 virtualAmount, uint256 realAmount);

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

    /**
     * @notice Sets the Aave Pool address
     */
    function setAavePool(address _aavePool) external onlyOwner {
        aavePool = IAavePool(_aavePool);

        realUSDC.approve(_aavePool, type(uint256).max);
    }

    function setYieldToken(address _yieldToken) external onlyOwner {
        yieldToken = IERC20(_yieldToken);
    }

    /**
     * @notice Withdraws yields from the Aave Pool
     */
    function withdrawYields(address _to) external onlyOwner {
        uint256 actualBalance = IERC20(yieldToken).balanceOf(address(this));

       if (actualBalance > totalRealUSDCInVault) {
           uint256 amountToWithdraw = actualBalance - totalRealUSDCInVault;
           aavePool.withdraw(address(realUSDC), amountToWithdraw, _to);
       }
    }

    /**
     * @notice Transfers ownership of the contract
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }
}