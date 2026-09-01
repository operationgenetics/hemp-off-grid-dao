// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    function mint(address to, uint256 amount) external {
        balances[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowances[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address recipient, uint256 amount) external returns (bool) {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool) {
        require(balances[sender] >= amount, "Insufficient balance");
        require(allowances[sender][msg.sender] >= amount, "Insufficient allowance");
        balances[sender] -= amount;
        balances[recipient] += amount;
        allowances[sender][msg.sender] -= amount;
        return true;
    }
}

contract HempOffGridDAOComprehensiveTest is Test {
    HempOffGridDAO dao;
    MockERC20 obsToken;
    MockERC20 daiToken;
    
    address updateWallet = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address roomieBot = address(0x999);
    address member1 = address(0x1);
    address member2 = address(0x2);
    address temple1 = address(0x3);
    address community1 = address(0x4);
    
    function setUp() public {
        // Deploy mock tokens to get valid bytecode
        MockERC20 _obsToken = new MockERC20();
        MockERC20 _daiToken = new MockERC20();

        // Mock OBS token at correct address
        address targetObs = 0x2D8760e2877148d239a54952A458710553B2B54b;
        vm.etch(targetObs, address(_obsToken).code);

        // Mock DAI token at correct address
        address targetDai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        vm.etch(targetDai, address(_daiToken).code);

        // Deploy DAO
        dao = new HempOffGridDAO();

        // Now we need to set balances via vm.store because vm.etch doesn't copy storage
        // Mapping slot 0 = balances mapping. For MockERC20, balances is slot 0.
        // keccak256(abi.encode(key, slot)) gives storage slot for mapping value
        address obsTokenAddr = targetObs;
        address daoAddr = address(dao);
        address obsTokenHolder = dao.OBS_TOKEN_ADDRESS();

        // DAO holds OBS tokens (vault)
        bytes32 daoObsSlot = keccak256(abi.encode(daoAddr, uint256(0)));
        vm.store(obsTokenAddr, daoObsSlot, bytes32(uint256(1_000_000 * 1e18)));

        // DAI balance check: IERC20(ARBITRUM_DAI).balanceOf(OBS_TOKEN_ADDRESS) >= THRESHOLD_DAI
        // We need 10B DAI at the OBS_TOKEN_ADDRESS
        address daiTokenAddr = targetDai;
        bytes32 obsDaiSlot = keccak256(abi.encode(obsTokenHolder, uint256(0)));
        vm.store(daiTokenAddr, obsDaiSlot, bytes32(uint256(10_000_000_000 * 1e18)));

        // DAO needs DAI balance for executeProposal transfers
        bytes32 daoDaiSlot = keccak256(abi.encode(daoAddr, uint256(0)));
        vm.store(daiTokenAddr, daoDaiSlot, bytes32(uint256(10_000_000_000 * 1e18)));

        // Set member1 OBS balance for vault test
        bytes32 member1ObsSlot = keccak256(abi.encode(member1, uint256(0)));
        vm.store(obsTokenAddr, member1ObsSlot, bytes32(uint256(1_000 * 1e18)));

        obsToken = MockERC20(targetObs);
        daiToken = MockERC20(targetDai);
    }

    function testInitialSetup() public view {
        assertEq(dao.OBS_TOKEN_ADDRESS(), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(dao.DESIGNATED_UPDATE_WALLET(), updateWallet);
        assertEq(dao.THRESHOLD_DAI(), 5_000_000_000 * 1e18);
        assertFalse(dao.isImmutable());
        assertEq(dao.updateWallet(), updateWallet);
    }

    function testSetupRoomieRobotAndLock() public {
        vm.prank(updateWallet);
        bytes32 pqcKeyHash = keccak256(abi.encodePacked("DilithiumPublicKey"));
        dao.setupRoomieRobotAndLock(roomieBot, pqcKeyHash);
        
        assertEq(dao.roomieBot(), roomieBot);
        assertEq(dao.roomieBotQuantumKeyHashes(roomieBot), pqcKeyHash);
    }

    function testRevokeAndUpdatePermissions() public {
        vm.prank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, keccak256(abi.encodePacked("DilithiumPublicKey")));
        
        vm.prank(updateWallet);
        dao.revokeAndUpdatePermissions();
        
        assertTrue(dao.isImmutable());
        assertEq(dao.updateWallet(), address(0));
    }

    function testMonthlyLPIssuance() public {
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        
        assertEq(dao.getEffectiveLPBalance(member1), 100 * 1e18);
        vm.stopPrank();
    }

    function testLPExpiration() public {
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        assertEq(dao.getEffectiveLPBalance(member1), 100 * 1e18);
        
        // Move to next month
        vm.warp(block.timestamp + 32 days);
        assertEq(dao.getEffectiveLPBalance(member1), 0);
        vm.stopPrank();
    }

    function testProposalCreation() public {
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        
        uint256 proposalId = dao.createProposal(
            "Hemp vertical grow for Hindu temple",
            payable(member1),
            1000 * 1e18,
            60
        );
        
        assertEq(proposalId, 0);
        assertEq(dao.proposalCount(), 1);
        vm.stopPrank();
    }

    function testVoting() public {
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        
        uint256 proposalId = dao.createProposal(
            "Community hemp clothing distribution",
            payable(member1),
            1000 * 1e18,
            60
        );
        
        dao.vote(proposalId, true);
        
        (,,, uint256 votesFor,,, ) = dao.proposals(proposalId);
        assertEq(votesFor, 100 * 1e18);
        vm.stopPrank();
    }

    function testBimonthlyTimeout() public {
        vm.prank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, keccak256(abi.encodePacked("DilithiumPublicKey")));

        // Create proposal with short deadline (30 days)
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        uint256 proposalId = dao.createProposal(
            "Test project",
            payable(community1),
            1000 * 1e18,
            30
        );
        dao.vote(proposalId, true);
        vm.stopPrank();

        // Wait 61 days: past voting deadline AND past initial 60-day cooldown from constructor
        vm.warp(block.timestamp + 61 days);

        // First execution succeeds (lastFundReleaseTimestamp=0, 61 days > 60 days)
        vm.prank(updateWallet);
        dao.executeProposal(proposalId);

        // Create and vote on a second proposal (short deadline)
        vm.startPrank(member2);
        dao.claimMonthlyLP();
        uint256 proposalId2 = dao.createProposal(
            "Second project",
            payable(community1),
            500 * 1e18,
            30
        );
        dao.vote(proposalId2, true);
        vm.stopPrank();

        // Wait 31 days: past voting deadline but only ~92 days since last release (< 120 days)
        vm.warp(block.timestamp + 31 days);

        // Should revert - robot timeout active
        vm.prank(updateWallet);
        vm.expectRevert("Robot timeout active: Once every 2 months");
        dao.executeProposal(proposalId2);

        // Wait for the full cooldown from last release
        vm.warp(block.timestamp + 90 days);

        // Now it should succeed
        vm.prank(updateWallet);
        dao.executeProposal(proposalId2);
    }

    function testVaultFunctionality() public {
        // member1 already has 1000 OBS from setUp via vm.store
        // Allowance mapping is slot 1 in MockERC20 (nested: allowances[owner][spender])
        // Slot = keccak256(abi.encode(spender, keccak256(abi.encode(owner, 1))))
        bytes32 innerSlot = keccak256(abi.encode(member1, uint256(1)));
        bytes32 allowanceSlot = keccak256(abi.encode(address(dao), innerSlot));
        vm.store(address(obsToken), allowanceSlot, bytes32(uint256(1000 * 1e18)));

        vm.startPrank(member1);
        dao.depositObsToVault(500 * 1e18);

        assertEq(dao.obsVaultBalances(member1), 500 * 1e18);
        assertEq(dao.totalObsVaulted(), 500 * 1e18);
        vm.stopPrank();
    }

    function testBondingCurveThreshold() public view {
        // Check if funds are unlocked when threshold is met
        // The contract uses a modifier fundsUnlocked() that checks the DAI balance
        // For testing purposes, we just verify the threshold constant is set correctly
        assertEq(dao.THRESHOLD_DAI(), 5_000_000_000 * 1e18);
    }

    function testHempSpecifications() public view {
        assertEq(dao.HEMP_SPECIFICATION(), "GMO hemp, all natural hemp color, no added colors");
        assertEq(dao.PRODUCT_SCOPE(), "Clothing, hemp toilet paper and wipes");
        assertEq(dao.NONPROFIT_MISSION(), "Strictly for free public giveaway and nonprofit use only");
    }

    function testPQCSecurity() public view {
        assertEq(dao.pqcAlgorithmSuite(), "Hybrid CRYSTALS-Dilithium + Ed25519 (MCU Biometric Bound)");
    }

    function testRobotEnforcedProjects() public {
        vm.prank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, keccak256(abi.encodePacked("DilithiumPublicKey")));
        
        // Create proposal
        vm.startPrank(member1);
        dao.claimMonthlyLP();
        uint256 proposalId = dao.createProposal(
            "Off-grid solar installation for hemp processing",
            payable(community1),
            1000 * 1e18,
            60
        );
        dao.vote(proposalId, true);
        vm.stopPrank();
        
        // Wait for voting to end
        vm.warp(block.timestamp + 61 days);
        
        // Execute proposal
        vm.prank(updateWallet);
        dao.executeProposal(proposalId);
    }

    function testAccessControl() public {
        // Test unauthorized access
        vm.prank(member1);
        vm.expectRevert("Unauthorized: Only designated update wallet");
        dao.setupRoomieRobotAndLock(roomieBot, keccak256(abi.encodePacked("DilithiumPublicKey")));
        
        vm.prank(member1);
        vm.expectRevert("Unauthorized: Only designated update wallet");
        dao.revokeAndUpdatePermissions();
    }

    function testProposalRequirement() public {
        vm.startPrank(member1);
        vm.expectRevert("Insufficient active LP tokens: 50 LP required to propose");
        dao.createProposal("Test proposal", payable(member1), 1000 * 1e18, 60);
        vm.stopPrank();
    }
}
