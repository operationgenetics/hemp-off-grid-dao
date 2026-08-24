// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EcoBrickDAO.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        balances[sender] -= amount;
        balances[recipient] += amount;
        return true;
    }
}

contract EcoBrickDAOAdvancedTest is Test {
    EcoBrickDAO public dao;
    MockERC20 public obsToken;

    address updateWallet = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address roomieBot = address(0x999);
    address member1 = address(0x1);
    address member2 = address(0x2);

    function setUp() public {
        obsToken = new MockERC20();
        address targetObs = 0x2D8760e2877148d239a54952A458710553B2B54b;
        bytes memory code = address(obsToken).code;
        vm.etch(targetObs, code);

        dao = new EcoBrickDAO();
    }

    function testInitialState() public view {
        assertEq(dao.updateWallet(), updateWallet);
        assertEq(dao.adminAddress(), updateWallet);
        assertFalse(dao.isImmutable());
        assertEq(dao.patentedEcoBrickModel(), "Pending Patent: Eco-Brick & Recycled Glass Tile Matrix");
    }

    function testMemberJoinAndMonthlyLPIssuance() public {
        vm.prank(member1);
        dao.joinDAO();

        assertTrue(dao.members(member1));
        assertEq(dao.getEffectiveLPBalance(member1), 100 * 1e18);
    }

    function testProposalCreationAndVotingFlow() public {
        vm.prank(member1);
        dao.joinDAO();

        vm.prank(member1);
        dao.createProposal("Expand off-grid solar array for extrusion line", 7);

        assertEq(dao.proposalCount(), 1);
        assertEq(dao.getEffectiveLPBalance(member1), 50 * 1e18);

        vm.prank(member2);
        dao.joinDAO();

        vm.prank(member2);
        dao.vote(1, true);

        (
            ,
            address proposer,
            ,
            uint256 forVotes,
            uint256 againstVotes,
            ,
            ,
        ) = dao.proposals(1);

        assertEq(forVotes, 100 * 1e18);
        assertEq(againstVotes, 0);
        assertEq(proposer, member1);
    }

    function testMonthlyLpExpiration() public {
        vm.prank(member1);
        dao.joinDAO();
        assertEq(dao.getEffectiveLPBalance(member1), 100 * 1e18);

        vm.warp(block.timestamp + 35 days);
        assertEq(dao.getEffectiveLPBalance(member1), 0);
    }

    function testRoomieRobotLockAndBimonthlyMilestoneGating() public {
        vm.prank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, hex"aabbcc");

        assertEq(dao.roomieBot(), roomieBot);

        vm.prank(updateWallet);
        vm.expectRevert("Bimonthly time-lock active: Must wait 2 months between releases");
        dao.checkAndAuthorizeBimonthlySpending(hex"1234");

        vm.warp(block.timestamp + 60 days);

        vm.prank(roomieBot);
        dao.checkAndAuthorizeBimonthlySpending(hex"1234");
    }

    function testPatentUpdatesRestricted() public {
        vm.prank(updateWallet);
        dao.updatePatentInfo("Eco-Brick Matrix v2.0", "US-PATENT-999");

        assertEq(dao.patentedEcoBrickModel(), "Eco-Brick Matrix v2.0");
        assertEq(dao.patentNumber(), "US-PATENT-999");

        vm.prank(member1);
        vm.expectRevert("Unauthorized: Only designated update wallet");
        dao.updatePatentInfo("Malicious Model", "BAD-000");
    }

    function testRevocableImmutability() public {
        vm.prank(updateWallet);
        dao.revokeAndUpdatePermissions();

        assertTrue(dao.isImmutable());
        assertEq(dao.updateWallet(), address(0));

        vm.prank(updateWallet);
        vm.expectRevert("Unauthorized: Only designated update wallet");
        dao.updatePatentInfo("New Model After Lock", "FAIL-000");
    }
}
