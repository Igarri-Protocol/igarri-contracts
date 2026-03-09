// SPDX-License-Identifier: LGPL-3.0-only
pragma solidity ^0.8.0;

interface IRealityETH {
    /**
     * @notice Asks a new question on Reality.eth and returns the question ID.
     * @param template_id The template ID (0 for Boolean/Binary questions).
     * @param question The formatted question string (e.g., "Did BTC hit $100k?␟crypto␟en").
     * @param arbitrator The address of the Kleros Arbitrator Proxy.
     * @param timeout The time in seconds the system waits for counter-answers before finalizing.
     * @param opening_ts The earliest timestamp someone can answer (matches your tradingEndTime).
     * @param nonce A nonce to disambiguate identical questions (can be 0).
     */
    function askQuestion(
        uint256 template_id,
        string memory question,
        address arbitrator,
        uint32 timeout,
        uint32 opening_ts,
        uint256 nonce
    ) external payable returns (bytes32 question_id);

    /**
     * @notice Fetches the final answer for a question. Reverts if not finalized.
     * @param question_id The ID of the question to check.
     */
    function resultFor(bytes32 question_id) external view returns (bytes32);
}