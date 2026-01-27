// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IIgarriVault.sol";

contract IgarriLendingVault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable igUSDC;      
    IERC20 public immutable realUSDC;   
    IIgarriVault public vault;           
    IAavePool public aavePool;          
    IERC20 public aToken;                

    address public market;
    uint256 public totalBorrowed; // Tracks 6-decimal RealUSDC value

    // CONSTANT FOR CONVERSION
    uint256 public constant SCALE_FACTOR = 10**12; 
    uint256 public constant MAX_UTILIZATION_RATE = 90;

    event Staked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event Unstaked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event LoanFunded(uint256 amount);
    event LoanRepaid(uint256 principalRepaid, uint256 interestPaid);

    constructor(
        address _igUSDC, 
        address _realUSDC, 
        address _vault,
        address _aavePool,
        address _aToken
    ) ERC20("Igarri LP Token", "igLP") Ownable(msg.sender) {
        igUSDC = IERC20(_igUSDC);
        realUSDC = IERC20(_realUSDC);
        vault = IIgarriVault(_vault);
        aavePool = IAavePool(_aavePool);
        aToken = IERC20(_aToken);

        realUSDC.approve(_aavePool, type(uint256).max);
    }

    modifier onlyMarket() {
        require(msg.sender == market, "Only Market");
        _;
    }

    function setMarket(address _market) external onlyOwner {
        market = _market;
    }

    /**
     * @notice Total Assets in Underlying Terms (6 Decimals)
     */
    function totalAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this)) + totalBorrowed;
    }

    /**
     * @notice Stake igUSDC (18 dec) -> Mint igLP (18 dec) -> Supply RealUSDC (6 dec)
     */
    function stake(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");

        uint256 assets = totalAssets(); // 6 Decimals
        uint256 supply = totalSupply(); // 18 Decimals
        uint256 shares;

        if (supply == 0) {
            shares = _amount;
        } else {
            // MATH FIX: We must scale assets up to 18 decimals to match supply/amount
            // shares = (amount * supply) / (assets * SCALE)
            shares = (_amount * supply) / (assets * SCALE_FACTOR);
        }

        // 1. Pull igUSDC (18 Decimals)
        igUSDC.safeTransferFrom(msg.sender, address(this), _amount);
        
        // 2. Move Real Funds (Vault handles the 18->6 logic internally or we trigger it)
        // Note: Vault.moveFunds expects igUSDC amount and calculates 6 decimal amount itself
        vault.moveFundsToLendingPool(_amount);

        // 3. Supply to Aave (MUST USE 6 DECIMALS)
        uint256 realAmount = _amount / SCALE_FACTOR; // <--- FIX IS HERE
        aavePool.supply(address(realUSDC), realAmount, address(this), 0);

        _mint(msg.sender, shares);
        emit Staked(msg.sender, _amount, shares);
    }

    /**
     * @notice Unstake igLP (18 dec) -> Withdraw RealUSDC (6 dec) -> Return igUSDC (18 dec)
     */
    function unstake(uint256 _shares) external nonReentrant {
        require(_shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= _shares, "Insufficient balance");

        uint256 assets = totalAssets(); // 6 Decimals
        uint256 supply = totalSupply(); // 18 Decimals
        
        // Calculate the 6-decimal value of these shares
        // Amount = (Shares * Assets) / Supply
        // Result is in 6 decimals because 'Assets' is 6 decimals
        uint256 amount = (_shares * assets) / supply;

        require(aToken.balanceOf(address(this)) >= amount, "Utilization high");

        _burn(msg.sender, _shares);

        // Withdraw 6 Decimals from Aave
        aavePool.withdraw(address(realUSDC), amount, address(this));

        // Return 6 Decimals to Vault
        realUSDC.approve(address(vault), amount);
        vault.receiveFundsFromLendingPool(amount);

        // Return 18 Decimals to User
        uint256 igUsdcAmount = amount * SCALE_FACTOR; // <--- FIX IS HERE
        igUSDC.safeTransfer(msg.sender, igUsdcAmount);

        emit Unstaked(msg.sender, igUsdcAmount, _shares);
    }

    function fundLoan(uint256 _amount) external onlyMarket {
        uint256 liquidity = aToken.balanceOf(address(this));
        uint256 assets = totalAssets();
        
        require(totalBorrowed + _amount <= (assets * MAX_UTILIZATION_RATE) / 100, "Max utilization");
        require(liquidity >= _amount, "Insufficient liquidity");
        
        totalBorrowed += _amount;
        emit LoanFunded(_amount);
    }

    function repayLoan(uint256 _amount, uint256 _interest) external onlyMarket nonReentrant {
        if (_amount >= totalBorrowed) totalBorrowed = 0;
        else totalBorrowed -= _amount;

        uint256 totalRepayment = _amount + _interest;

        realUSDC.safeTransferFrom(msg.sender, address(this), totalRepayment);
        aavePool.supply(address(realUSDC), totalRepayment, address(this), 0);
        
        emit LoanRepaid(_amount, _interest);
    }

    function previewUserBalance(address _user) external view returns (uint256) {
        uint256 userShares = balanceOf(_user);
        uint256 supply = totalSupply();
        
        if (supply == 0) return 0;

        // Formula: (UserShares * TotalAssets) / TotalSupply
        // Result is 6 decimals. Scale up to 18 for display.
        uint256 assets18 = totalAssets() * SCALE_FACTOR;
        return (userShares * assets18) / supply;
    }
}