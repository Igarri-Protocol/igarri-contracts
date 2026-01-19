// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IIgarriUSDC.sol";
import "./tokens/IgarriOutcomeToken.sol";
import "./common/Singleton.sol";
import "./common/StorageAccessible.sol";

contract IgarriMarketPhase1 is Singleton, StorageAccessible, ReentrancyGuard {
    uint256 public constant K = 100; 
    uint256 public constant INSURANCE_FEE_BPS = 50; 
    uint256 public migrationThreshold;
  
    IIgarriUSDC public igUSDC;
    IgarriOutcomeToken public yesToken;
    IgarriOutcomeToken public noToken;
    
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
     * @param _marketName Name used to prefix the YES/NO tokens
     */
    function initialize(address _igUSDC, string memory _marketName, uint256 _migrationThreshold) external {
        require(address(igUSDC) == address(0), "Already initialized");

        require(_igUSDC != address(0), "Invalid igUSDC address");
        require(bytes(_marketName).length > 0, "Invalid market name");
        require(migrationThreshold > 0, "Invalid migration threshold");

        igUSDC = IIgarriUSDC(_igUSDC);
        
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
        
        (uint256 rawCost, uint256 fee) = getQuote(_shareAmount);
        uint256 totalCost = rawCost + fee;

        // Execute the transfer (Allowed via Factory whitelist)
        igUSDC.transferFrom(msg.sender, address(this), totalCost);

        currentSupply += _shareAmount;
        totalCapital += rawCost;

        if (_isYes) {
            yesToken.mint(msg.sender, _shareAmount);
        } else {
            noToken.mint(msg.sender, _shareAmount);
        }

        emit BulkBuy(msg.sender, _isYes, totalCost, _shareAmount);

        // TRIGGER: If we are at or ABOVE threshold, we migrate immediately
        if (totalCapital >= migrationThreshold) {
            _migrate();
        }
    }

    function _migrate() internal {
        migrated = true;
    
        emit Migrated(totalCapital, currentSupply);
    }
}