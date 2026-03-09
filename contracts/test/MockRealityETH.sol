// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockRealityETH {
    mapping(bytes32 => bytes32) public results;
    mapping(bytes32 => bool) public isFinalized;
    
    uint256 private nextId = 1;

    event QuestionAsked(bytes32 questionId, string question, address arbitrator, uint32 timeout, uint32 opening_ts, uint256 nonce);

    function askQuestion(
        uint256 template_id,
        string memory question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) external payable returns (bytes32) {
        bytes32 questionId = bytes32(nextId++);
        emit QuestionAsked(questionId, question, arbitrator, timeout, opening_ts, nonce);
        return questionId;
    }

    function resultFor(bytes32 question_id) external view returns (bytes32) {
        require(isFinalized[question_id], "MockRealityETH: Question not finalized");
        return results[question_id];
    }

    function setMockResult(bytes32 question_id, bytes32 result) external {
        results[question_id] = result;
        isFinalized[question_id] = true;
    }
}