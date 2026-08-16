// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";

contract MockDAI is IERC20 {
    mapping(address => uint256) public balances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }
}

contract HempOffGridDAOTest is Test {
    HempOffGridDAO public hempDAO;
    MockDAI public dai;

    address public updateWallet = address(0x1);
    address public admin = address(0x2);
    address public roomieBot = address(0x3);
    address public hinduTemple = address(0x4);
    address public member1 = address(0x5);
    address public communityRecipient = address(0x6);
    address public obsCurve = address(0x7);
    address public worker = address(0x8);

    function setUp() public {
        dai = new MockDAI();

        address[] memory members = new address[](1);
        members[0] = member1;

        uint256[] memory weights = new uint256[](1);
        weights[0] = 100;

        hempDAO = new HempOffGridDAO(
            obsCurve,
            address(dai),
            updateWallet,
            admin,
            roomieBot,
            hinduTemple,
            members,
            weights
        );

        dai.mint(address(hempDAO), 10_000 * 1e18);
    }

    function testHempSpecifications() public view {
        assertEq(hempDAO.HEMP_SPECIFICATION(), "GMO hemp, all natural hemp color, no added colors");
        assertEq(hempDAO.hinduTempleBeneficiary(), hinduTemple);
    }

    function testHybridPQCAndRoomieBotAttestation() public {
        // 1. Register PQC quantum key hash for the RoomieBot from updateWallet
        bytes32 mockPqcKeyHash = keccak256("PQC-Falcon512-Dilithium3-Key-Material");
        vm.prank(updateWallet);
        hempDAO.registerRoomieBotQuantumKey(roomieBot, mockPqcKeyHash);
        assertEq(hempDAO.roomieBotQuantumKeyHashes(roomieBot), mockPqcKeyHash);

        // 2. RoomieBot verifies manufacturing site presence with hybrid PQC signature hash
        bytes32 pqcSigHash = keccak256("Valid-PQC-Signature-Payload-For-Worker");
        vm.prank(roomieBot);
        hempDAO.verifyManufacturingPresenceWithPQC(worker, true, pqcSigHash);

        assertTrue(hempDAO.verifiedManufacturingSitePresence(worker));
        assertTrue(hempDAO.verifiedPQCAuthorizations(pqcSigHash));
    }

    function testUpdateRoomieBotHardwareAndRotatePQCKey() public {
        address newHardwareBot = address(0x999);
        bytes32 newPqcKeyHash = keccak256("New-RoomieBot-Quantum-Hardware-Key");

        // Update Roomie Bot address via updateWallet
        vm.prank(updateWallet);
        hempDAO.setRoomieBot(newHardwareBot);
        assertEq(hempDAO.roomieBot(), newHardwareBot);

        // Register PQC key for the new bot
        vm.prank(updateWallet);
        hempDAO.registerRoomieBotQuantumKey(newHardwareBot, newPqcKeyHash);

        // Verify old bot fails
        vm.prank(roomieBot);
        vm.expectRevert("Unauthorized: Only Roomie Bot");
        hempDAO.verifyManufacturingPresenceWithPQC(worker, true, keccak256("old"));

        // Verify new bot succeeds with PQC attestation
        bytes32 newSigHash = keccak256("New-Hardware-PQC-Sig");
        vm.prank(newHardwareBot);
        hempDAO.verifyManufacturingPresenceWithPQC(worker, true, newSigHash);

        assertTrue(hempDAO.verifiedManufacturingSitePresence(worker));
    }

    function testCommunitySupplyProposalExecution() public {
        vm.prank(member1);
        uint256 proposalId = hempDAO.createProposal(
            "Supply hemp clothing, toilet paper, and wipes to community in need",
            payable(communityRecipient),
            1_500 * 1e18,
            1,
            false
        );

        vm.prank(member1);
        hempDAO.vote(proposalId, true);

        vm.warp(block.timestamp + 2 days);
        dai.mint(obsCurve, 5_000_000_000 * 1e18);

        vm.prank(member1);
        hempDAO.executeProposal(proposalId);

        (, , , , , , bool executed,) = hempDAO.proposals(proposalId);
        assertTrue(executed);
        assertEq(dai.balanceOf(communityRecipient), 1_500 * 1e18);
    }
}
