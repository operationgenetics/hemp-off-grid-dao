// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";

contract MockDAI is IERC20 {
    mapping(address => uint256) public balances;
    function transfer(address recipient, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        balances[sender] -= amount;
        balances[recipient] += amount;
        return true;
    }
    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }
    function mint(address account, uint256 amount) external {
        balances[account] += amount;
    }
}

contract HempOffGridDAOTest is Test {
    HempOffGridDAO hempDAO;
    MockDAI dai;
    address admin = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address roomieBot = address(0x2);
    address user = address(0x3);

    function setUp() public {
        dai = new MockDAI();
        hempDAO = new HempOffGridDAO(
            address(dai),
            admin,
            roomieBot
        );
    }

    function test_DeploymentAndConstants() public {
        assertEq(hempDAO.OBS_TOKEN_ADDRESS(), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(hempDAO.DESIGNATED_UPDATE_WALLET(), admin);
        assertEq(hempDAO.HEMP_SPECIFICATION(), "GMO hemp, all natural hemp color, no added colors");
    }

    function test_MonthlyLPClaim() public {
        vm.prank(user);
        hempDAO.claimMonthlyLP();
        assertEq(hempDAO.getEffectiveLPBalance(user), 100 * 1e18);
    }

    function test_ProposalCreationAndVoting() public {
        vm.startPrank(user);
        hempDAO.claimMonthlyLP();
        
        uint256 proposalId = hempDAO.createProposal(
            "Hemp Fiber Harvesting",
            payable(user),
            1000 * 1e18,
            3
        );

        hempDAO.vote(proposalId, true);
        vm.stopPrank();

        (,, , uint256 yesVotes,,,) = hempDAO.proposals(proposalId);
        assertEq(yesVotes, 100 * 1e18);
    }
}
