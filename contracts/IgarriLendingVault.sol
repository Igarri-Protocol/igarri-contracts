// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAavePool.sol";
import "./interfaces/IIgarriVault.sol";
import "./interfaces/IIgarriInsuranceFund.sol";

contract IgarriLendingVault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable igUSDC;      
    IERC20 public immutable realUSDC;   
    IIgarriVault public vault;           
    IAavePool public aavePool;          
    IERC20 public aToken;               

    mapping(address => bool) public allowedMarkets; 

    address public marketFactory;
    uint256 public totalBorrowed;

    uint256 public constant SCALE_FACTOR = 10**12; 
    uint256 public constant MAX_UTILIZATION_RATE = 90;

    IIgarriInsuranceFund public insuranceFund;
    uint256 public reserveFactorBps = 1000;

    event Staked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event Unstaked(address indexed user, uint256 igUsdcAmount, uint256 lpShares);
    event LoanFunded(address indexed market, uint256 amount);
    event LoanRepaid(address indexed market, uint256 principalRepaid, uint256 interestPaid);
    event InsuranceFundUpdated(address indexed newFund);
    event ReserveFactorUpdated(uint256 newFactor);

    constructor(
        address _igUSDC, 
        address _realUSDC, 
        address _vault,
        address _aavePool,
        address _aToken,
        address _marketFactory
    ) ERC20("Igarri LP Token", "igLP") Ownable(msg.sender) {
        igUSDC = IERC20(_igUSDC);
        realUSDC = IERC20(_realUSDC);
        vault = IIgarriVault(_vault);
        aavePool = IAavePool(_aavePool);
        aToken = IERC20(_aToken);
        marketFactory = _marketFactory;
        realUSDC.approve(_aavePool, type(uint256).max);
    }

    modifier onlyMarketFactory() { require(msg.sender == marketFactory, "Only Market Factory"); _; }
    modifier onlyAllowedMarket() { require(allowedMarkets[msg.sender], "Only Allowed Markets"); _; }

    function addAllowedMarket(address _market) external onlyMarketFactory {
        allowedMarkets[_market] = true;
    }

    function totalAssets() public view returns (uint256) {
        return aToken.balanceOf(address(this)) + totalBorrowed;
    }

    function stake(uint256 _amount) external nonReentrant {
        require(_amount > 0, "Zero amount");
        uint256 assets = totalAssets(); 
        uint256 supply = totalSupply(); 
        uint256 shares;

        if (supply == 0) shares = _amount;
        else shares = (_amount * supply) / (assets * SCALE_FACTOR);

        igUSDC.safeTransferFrom(msg.sender, address(this), _amount);
        vault.moveFundsToLendingPool(_amount);

        uint256 realAmount = _amount / SCALE_FACTOR; 
        aavePool.supply(address(realUSDC), realAmount, address(this), 0);

        _mint(msg.sender, shares);
        emit Staked(msg.sender, _amount, shares);
    }

    function unstake(uint256 _shares) external nonReentrant {
        require(_shares > 0, "Zero shares");
        require(balanceOf(msg.sender) >= _shares, "Insufficient balance");

        uint256 assets = totalAssets();
        uint256 supply = totalSupply(); 
        uint256 amount = (_shares * assets) / supply;

        require(aToken.balanceOf(address(this)) >= amount, "Utilization high");

        _burn(msg.sender, _shares);
        aavePool.withdraw(address(realUSDC), amount, address(this));

        realUSDC.approve(address(vault), amount);
        vault.receiveFundsFromLendingPool(amount);

        uint256 igUsdcAmount = amount * SCALE_FACTOR; 
        igUSDC.safeTransfer(msg.sender, igUsdcAmount);

        emit Unstaked(msg.sender, igUsdcAmount, _shares);
    }

    function fundLoan(uint256 _amount) external onlyAllowedMarket {
        uint256 liquidity = aToken.balanceOf(address(this));
        uint256 assets = totalAssets();
        
        require(totalBorrowed + _amount <= (assets * MAX_UTILIZATION_RATE) / 100, "Max utilization");
        require(liquidity >= _amount, "Insufficient liquidity");
        
        totalBorrowed += _amount;

        aavePool.withdraw(address(realUSDC), _amount, address(this));
        realUSDC.safeTransfer(msg.sender, _amount);

        emit LoanFunded(msg.sender, _amount);
    }

    function repayLoan(uint256 _amount, uint256 _interest) external onlyAllowedMarket nonReentrant {
        if (_amount >= totalBorrowed) totalBorrowed = 0;
        else totalBorrowed -= _amount;

        uint256 totalRepayment = _amount + _interest;

        realUSDC.safeTransferFrom(msg.sender, address(this), totalRepayment);
        
        uint256 insuranceCut = 0;
        if (_interest > 0 && address(insuranceFund) != address(0)) {
            insuranceCut = (_interest * reserveFactorBps) / 10000;
            if (insuranceCut > 0) {
                realUSDC.approve(address(insuranceFund), insuranceCut);
                insuranceFund.depositFee(insuranceCut);
            }
        }
        
        uint256 aaveSupplyAmount = totalRepayment - insuranceCut;

        if (aaveSupplyAmount > 0) {
            aavePool.supply(address(realUSDC), aaveSupplyAmount, address(this), 0);
        }
        
        emit LoanRepaid(msg.sender, _amount, _interest);
    }

    function previewUserBalance(address _user) external view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 0;
        uint256 assets18 = totalAssets() * SCALE_FACTOR;
        return (balanceOf(_user) * assets18) / supply;
    }

    function setInsuranceFund(address _insuranceFund) external onlyOwner {
        insuranceFund = IIgarriInsuranceFund(_insuranceFund);
        emit InsuranceFundUpdated(_insuranceFund);
    }

    function setReserveFactor(uint256 _reserveFactorBps) external onlyOwner {
        require(_reserveFactorBps <= 10000, "Max 100%");
        reserveFactorBps = _reserveFactorBps;
        emit ReserveFactorUpdated(_reserveFactorBps);
    }
}