// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAavePool.sol"; 

contract IgarriInsuranceFund is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable realUSDC;
    IAavePool public aavePool;
    IERC20 public aToken;

    mapping(address => bool) public allowedMarkets;
    address public marketFactory;

    event FeeDeposited(address indexed market, uint256 amount);
    event BadDebtCovered(address indexed market, uint256 amount);
    event MarketAllowed(address indexed market, bool status);
    event AavePoolUpdated(address indexed newPool);

    error Unauthorized();
    error InsufficientInsuranceFunds();

    constructor(
        address _realUSDC, 
        address _marketFactory,
        address _aavePool,
        address _aToken
    ) Ownable(msg.sender) {
        realUSDC = IERC20(_realUSDC);
        marketFactory = _marketFactory;
        aavePool = IAavePool(_aavePool);
        aToken = IERC20(_aToken);

        realUSDC.approve(_aavePool, type(uint256).max);
    }

    modifier onlyAllowedMarket() {
        if (!allowedMarkets[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyMarketFactory() {
        if (msg.sender != marketFactory) revert Unauthorized();
        _;
    }

    /**
     * @notice Allows the Factory to authorize new proxy markets to interact with the insurance fund.
     */
    function setAllowedMarket(address _market, bool _status) external onlyMarketFactory {
        allowedMarkets[_market] = _status;
        emit MarketAllowed(_market, _status);
    }

    /**
     * @notice Markets call this to deposit collected Phase 1 fees, liquidation fees, or interest.
     */
    function depositFee(uint256 _amount) external onlyAllowedMarket nonReentrant {
        require(_amount > 0, "Zero amount");
        
        realUSDC.safeTransferFrom(msg.sender, address(this), _amount);
        
        aavePool.supply(address(realUSDC), _amount, address(this), 0);
        
        emit FeeDeposited(msg.sender, _amount);
    }

    /**
     * @notice Markets call this during liquidation if the returned USDC doesn't cover the virtual loan.
     */
    function coverBadDebt(uint256 _shortfallAmount) external onlyAllowedMarket nonReentrant {
        require(_shortfallAmount > 0, "Zero shortfall");
        
        if (aToken.balanceOf(address(this)) < _shortfallAmount) {
            revert InsufficientInsuranceFunds();
        }
        aavePool.withdraw(address(realUSDC), _shortfallAmount, address(this));
        realUSDC.safeTransfer(msg.sender, _shortfallAmount);
        emit BadDebtCovered(msg.sender, _shortfallAmount);
    }

    /**
     * @notice Returns the total value locked in the insurance fund (Principal + Yield)
     */
    function totalAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Emergency withdrawal by owner (governance).
     */
    function emergencyWithdraw(address _to, uint256 _amount) external onlyOwner {
        require(_amount <= totalAssets(), "Amount exceeds balance");
        
        aavePool.withdraw(address(realUSDC), _amount, address(this));
        realUSDC.safeTransfer(_to, _amount);
    }

    /**
     * @notice Admin function to update the Aave pool address if a migration happens
     */
    function setAavePool(address _aavePool) external onlyOwner {
        aavePool = IAavePool(_aavePool);
        realUSDC.approve(_aavePool, type(uint256).max);
        emit AavePoolUpdated(_aavePool);
    }
}