// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IACPHook.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @notice RNWY Trust Oracle read interface (deployed on Base mainnet)
interface IRNWYTrustOracle {
    function meetsThreshold(
        uint256 agentId,
        uint256 chainId,
        string calldata registry,
        uint8 threshold
    ) external view returns (bool);

    function getScore(
        uint256 agentId,
        uint256 chainId,
        string calldata registry
    ) external view returns (uint8 score, uint8 tier, uint8 sybilSeverity, uint40 updatedAt);
}

/**
 * @title RNWYTrustGateHook
 * @notice IACPHook that gates ERC-8183 job lifecycle by RNWY trust score.
 *
 * @dev Reads from the RNWY Trust Oracle — 138,000+ agent scores on Base mainnet
 *      covering 3 registries (ERC-8004, Olas, Virtuals) across 11 chains.
 *      Scores are transparent and verifiable: base 50, cap 95, computed from
 *      reviewer wallet ages, sybil detection, ownership history, and on-chain activity.
 *
 * Hook points:
 *   - beforeAction(fund)    → Check client trust, revert if below threshold
 *   - beforeAction(submit)  → Check provider trust, revert if below threshold
 *   - afterAction(complete) → Emit outcome event
 *   - afterAction(reject)   → Emit outcome event
 *
 * The hook maps wallet addresses to ERC-8004 agent IDs via a registry managed
 * by the hook owner. The oracle does all scoring — the hook is a gate, not a judge.
 *
 * Oracle: https://basescan.org/address/0xD5fdccD492bB5568bC7aeB1f1E888e0BbA6276f4
 * Methodology: https://rnwy.com/scoring
 */
contract RNWYTrustGateHook is IACPHook, Ownable {
    /*//////////////////////////////////////////////////////////////
                            STORAGE
    //////////////////////////////////////////////////////////////*/

    IRNWYTrustOracle public oracle;
    uint8 public threshold;
    uint256 public defaultChainId;
    string public defaultRegistry;

    /// @notice Wallet address → ERC-8004 agent ID
    mapping(address => uint256) public agentIds;

    /// @dev Well-known selectors from AgenticCommerce
    bytes4 public constant FUND_SEL     = bytes4(keccak256("fund(uint256,bytes)"));
    bytes4 public constant SUBMIT_SEL   = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 public constant COMPLETE_SEL = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 public constant REJECT_SEL   = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    /*//////////////////////////////////////////////////////////////
                            EVENTS
    //////////////////////////////////////////////////////////////*/

    event TrustGated(uint256 indexed jobId, address indexed agent, uint256 agentId, bool allowed);
    event OutcomeRecorded(uint256 indexed jobId, bool completed);

    /*//////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error RNWYTrustGateHook__NoAgentId(address agent);
    error RNWYTrustGateHook__BelowThreshold(uint256 jobId, address agent, uint256 agentId, uint8 threshold);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @param oracle_    RNWY Trust Oracle address
     * @param threshold_ Minimum trust score (0-95) to pass the gate
     * @param chainId_   Default chain ID for oracle lookups (e.g., 8453 for Base)
     * @param registry_  Default registry for oracle lookups (e.g., "erc8004")
     */
    constructor(
        address oracle_,
        uint8 threshold_,
        uint256 chainId_,
        string memory registry_
    ) Ownable(msg.sender) {
        oracle = IRNWYTrustOracle(oracle_);
        threshold = threshold_;
        defaultChainId = chainId_;
        defaultRegistry = registry_;
    }

    /*//////////////////////////////////////////////////////////////
                    IACPHook: beforeAction
    //////////////////////////////////////////////////////////////*/

    /// @notice Gates fund and submit transitions by trust score. Reverts to block.
    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override {
        if (selector == FUND_SEL) {
            (address caller,) = abi.decode(data, (address, bytes));
            _checkTrust(jobId, caller);
        } else if (selector == SUBMIT_SEL) {
            (address caller,,) = abi.decode(data, (address, bytes32, bytes));
            _checkTrust(jobId, caller);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    IACPHook: afterAction
    //////////////////////////////////////////////////////////////*/

    /// @notice Records outcome events. Never reverts.
    function afterAction(uint256 jobId, bytes4 selector, bytes calldata) external override {
        if (selector == COMPLETE_SEL) emit OutcomeRecorded(jobId, true);
        else if (selector == REJECT_SEL) emit OutcomeRecorded(jobId, false);
    }

    /*//////////////////////////////////////////////////////////////
                    ERC-165
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IACPHook).interfaceId
            || interfaceId == 0x01ffc9a7; // IERC165
    }

    /*//////////////////////////////////////////////////////////////
                    ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Register a wallet → agent ID mapping.
    function setAgentId(address wallet, uint256 agentId) external onlyOwner {
        agentIds[wallet] = agentId;
    }

    /// @notice Batch-register wallet → agent ID mappings.
    function setAgentIds(address[] calldata wallets, uint256[] calldata ids) external onlyOwner {
        require(wallets.length == ids.length, "RNWY: array length mismatch");
        for (uint256 i = 0; i < wallets.length; i++) {
            agentIds[wallets[i]] = ids[i];
        }
    }

    /// @notice Update the minimum trust score threshold.
    function setThreshold(uint8 threshold_) external onlyOwner {
        threshold = threshold_;
    }

    /// @notice Update the oracle address.
    function setOracle(address oracle_) external onlyOwner {
        oracle = IRNWYTrustOracle(oracle_);
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _checkTrust(uint256 jobId, address agent) internal {
        uint256 agentId = agentIds[agent];
        if (agentId == 0) revert RNWYTrustGateHook__NoAgentId(agent);

        bool passes = oracle.meetsThreshold(agentId, defaultChainId, defaultRegistry, threshold);

        if (!passes) {
            emit TrustGated(jobId, agent, agentId, false);
            revert RNWYTrustGateHook__BelowThreshold(jobId, agent, agentId, threshold);
        }

        emit TrustGated(jobId, agent, agentId, true);
    }
}
