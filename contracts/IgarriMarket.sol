// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IIgarriUSDC.sol";
import "./interfaces/IIgarriVault.sol";
import "./tokens/IgarriOutcomeToken.sol";
import "./common/Singleton.sol";
import "./common/StorageAccessible.sol";
import "./interfaces/IAavePool.sol";

contract IgarriMarket is Singleton, StorageAccessible, ReentrancyGuard {
    uint256 public constant K = 100; 
    uint256 public constant INSURANCE_FEE_BPS = 50; 
    uint256 public migrationThreshold;
  
    IIgarriUSDC public igUSDC;
    IgarriOutcomeToken public yesToken;
    IgarriOutcomeToken public noToken;
    IIgarriVault public vault;
    IAavePool public aavePool;
    
    uint256 public totalCapital; 
    uint256 public currentSupply; 
    bool public migrated;

    event BulkBuy(address indexed user, bool isYes, uint256 igUSDCCost, uint256 sharesMinted);
    event Migrated(uint256 finalCapital, uint256 finalSupply);

    constructor() {
        // Prevents implementation contract from being initialized
        igUSDC = IIgarriUSDC(address(0x1));
    }

    /**
     * @notice Proxy initialization
     * @param _igUSDC Address of the IgarriUSDC contract
     * @param _vault Address of the IgarriVault contract
     * @param _marketName Name used to prefix the YES/NO tokens
     * @param _aavePool Address of the AavePool contract
     */
    function initialize(address _igUSDC, address _vault, string memory _marketName, uint256 _migrationThreshold, address _aavePool) external {
        require(address(igUSDC) == address(0), "Already initialized");

        require(_igUSDC != address(0), "Invalid igUSDC address");
        require(_vault != address(0), "Invalid vault address");
        require(bytes(_marketName).length > 0, "Invalid market name");
        require(_migrationThreshold > 0, "Invalid migration threshold");

        igUSDC = IIgarriUSDC(_igUSDC);
        vault = IIgarriVault(_vault);
        aavePool = IAavePool(_aavePool);
        
        yesToken = new IgarriOutcomeToken(
            string(abi.encodePacked(_marketName, " YES")), 
            "YES", 
            address(this)
        );
        noToken = new IgarriOutcomeToken(
            string(abi.encodePacked(_marketName, " NO")), 
            "NO", 
            address(this)
        );

        migrationThreshold = _migrationThreshold;
    }

    /**
     * @notice Current spot price based on P = k * S
     */
    function getCurrentPrice() public view returns (uint256) {
        return (K * currentSupply) / 1e6; 
    }

    /**
     * @notice Cost for bulk purchase using Integral Cost = (k/2) * (Send^2 - Sstart^2)
     */
    function getQuote(uint256 _amount) public view returns (uint256 rawCost, uint256 fee) {
        uint256 sStart = currentSupply;
        uint256 sEnd = sStart + _amount;

        rawCost = (K * (sEnd**2 - sStart**2)) / (2 * 1e6);
        fee = (rawCost * INSURANCE_FEE_BPS) / 10000;
    }

    /**
     * @notice Execute bulk purchase of YES or NO shares
     */
   function buyShares(bool _isYes, uint256 _shareAmount) external nonReentrant {
        require(!migrated, "Market migrated");
        
        uint256 finalShareAmount = _shareAmount;
        (uint256 rawCost, uint256 fee) = getQuote(_shareAmount);

        if (totalCapital + rawCost > migrationThreshold) {
            uint256 neededCapital = migrationThreshold - totalCapital;
            uint256 sStart = currentSupply;
            
            // Recalculate sEnd
            uint256 sEnd = _sqrt((2 * 1e6 * neededCapital / K) + (sStart**2));
            finalShareAmount = sEnd - sStart;
            (rawCost, fee) = getQuote(finalShareAmount);
            
            // FORCE SNAP: If we are very close to the threshold after calculation, 
            // we override rawCost to ensure the if() statement triggers.
            if (totalCapital + rawCost >= migrationThreshold - 1e12) { // 1e12 is a small dust buffer
                rawCost = migrationThreshold - totalCapital;
            }
        }

        uint256 totalCost = rawCost + fee;
        igUSDC.transferFrom(msg.sender, address(this), totalCost);

        currentSupply += finalShareAmount;
        totalCapital += rawCost;

        if (_isYes) yesToken.mint(msg.sender, finalShareAmount);
        else noToken.mint(msg.sender, finalShareAmount);

        emit BulkBuy(msg.sender, _isYes, totalCost, finalShareAmount);

        if (totalCapital >= migrationThreshold) {
            _migrate();
        }
    }

    function _migrate() internal {
        migrated = true;

        vault.transferToMarket(address(this), migrationThreshold);
    
        emit Migrated(totalCapital, currentSupply);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) z = 1;
    }
}