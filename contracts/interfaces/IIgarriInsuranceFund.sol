// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IIgarriInsuranceFund {
    function depositFee(uint256 _amount) external;
    
    function setAllowedMarket(address _market, bool _allowed) external;

    function coverBadDebt(uint256 _shortfallAmount) external;
}