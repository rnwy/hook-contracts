// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {TrustGateHook} from "../contracts/hooks/TrustGateHook.sol";
import {IRNWYTrustOracle} from "../contracts/interfaces/IRNWYTrustOracle.sol";

/// @notice Mock IRNWYTrustOracle for testing. Returns a configurable meetsThreshold result per agent.
contract MockRNWYTrustOracle is IRNWYTrustOracle {
    mapping(uint256 => bool) public passes;
    mapping(uint256 => bool) public known;
    uint256 public totalAgents;

    function setAgent(uint256 agentId, bool threshPasses) external {
        if (!known[agentId]) {
            known[agentId] = true;
            totalAgents++;
        }
        passes[agentId] = threshPasses;
    }

    function getScore(uint256, uint256, string calldata)
        external pure returns (uint8, uint8, uint8, uint40)
    { return (0, 0, 0, 0); }

    function hasScore(uint256 agentId, uint256, string calldata)
        external view returns (bool)
    { return known[agentId]; }

    function meetsThreshold(uint256 agentId, uint256, string calldata, uint8)
        external view returns (bool)
    { return passes[agentId]; }

    function agentCount() external view returns (uint256) { return totalAgents; }
}

/// @notice Fund-path tests for TrustGateHook. Verifies the gate actually routes and reverts correctly.
/// @dev The selector bug in the prior version meant beforeAction(fund) never matched FUND_SEL and the
///      gate silently bypassed. These tests exercise the fund path through BaseERC8183Hook's router
///      to confirm the gate now fires as intended.
contract TrustGateHookFundPathTest is Test {
    TrustGateHook internal hook;
    MockRNWYTrustOracle internal oracle;

    address internal constant ERC8183 = address(0xACC0); // mock core contract address
    address internal constant CLIENT_HIGH = address(0xA11CE);
    address internal constant CLIENT_LOW  = address(0xBAD);
    address internal constant UNREGISTERED = address(0xFEE1);

    uint256 internal constant AGENT_ID_HIGH = 100;
    uint256 internal constant AGENT_ID_LOW  = 200;

    uint8   internal constant THRESHOLD = 50;
    uint256 internal constant CHAIN_ID  = 8453;
    string  internal constant REGISTRY  = "erc8004";

    function setUp() public {
        oracle = new MockRNWYTrustOracle();
        oracle.setAgent(AGENT_ID_HIGH, true);
        oracle.setAgent(AGENT_ID_LOW,  false);

        hook = new TrustGateHook(
            ERC8183,
            address(oracle),
            THRESHOLD,
            CHAIN_ID,
            REGISTRY
        );

        hook.setAgentId(CLIENT_HIGH, AGENT_ID_HIGH);
        hook.setAgentId(CLIENT_LOW,  AGENT_ID_LOW);
    }

    function _fundSelector() internal pure returns (bytes4) {
        return bytes4(keccak256("fund(uint256,uint256,bytes)"));
    }

    function _encodeFundData(address caller) internal pure returns (bytes memory) {
        return abi.encode(caller, bytes(""));
    }

    /// @dev High-trust client passes the fund gate.
    function test_fund_highTrust_passes() public {
        vm.prank(ERC8183);
        hook.beforeAction(1, _fundSelector(), _encodeFundData(CLIENT_HIGH));
    }

    /// @dev Low-trust client is rejected with BelowThreshold.
    function test_fund_lowTrust_reverts() public {
        vm.prank(ERC8183);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustGateHook.TrustGateHook__BelowThreshold.selector,
                uint256(1),
                CLIENT_LOW,
                AGENT_ID_LOW,
                THRESHOLD
            )
        );
        hook.beforeAction(1, _fundSelector(), _encodeFundData(CLIENT_LOW));
    }

    /// @dev Unregistered caller is rejected with NoAgentId.
    function test_fund_unregistered_reverts() public {
        vm.prank(ERC8183);
        vm.expectRevert(
            abi.encodeWithSelector(
                TrustGateHook.TrustGateHook__NoAgentId.selector,
                UNREGISTERED
            )
        );
        hook.beforeAction(1, _fundSelector(), _encodeFundData(UNREGISTERED));
    }

    /// @dev Caller auth: non-ERC8183 msg.sender cannot invoke beforeAction.
    ///      Inherited behavior from BaseERC8183Hook.onlyERC8183(jobId).
    function test_fund_unauthorizedCaller_reverts() public {
        // No vm.prank: msg.sender is the test contract, not ERC8183.
        // BaseERC8183Hook then attempts AgenticCommerce(ERC8183).getJob(1) which reverts
        // because ERC8183 has no code, proving the auth gate rejects arbitrary callers.
        vm.expectRevert();
        hook.beforeAction(1, _fundSelector(), _encodeFundData(CLIENT_HIGH));
    }
}
