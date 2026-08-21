// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EcoBrickDAO.sol";

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balances;

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        balances[msg.sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function balanceOf(address account) external view override returns (uint256) {
        return balances[account];
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        balances[sender] -= amount;
        balances[recipient] += amount;
        return true;
    }

    function mint(address account, uint256 amount) external {
        balances[account] += amount;
    }
}

contract EcoBrickDAOTest is Test {
    EcoBrickDAO dao;
    MockERC20 dai;
    address updateWallet = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    function setUp() public {
        dai = new MockERC20();
        // Zero-argument deployment as requested
        dao = new EcoBrickDAO();
    }

    function test_DeploymentAndConstants() public {
        assertEq(dao.updateWallet(), updateWallet);
        assertEq(dao.OBS_TOKEN_ADDRESS(), 0x2D8760e2877148d239a54952A458710553B2B54b);
        assertEq(dao.THRESHOLD_DAI(), 5_000_000_000 * 1e18);
    }

    function test_MonthlyLPAndProposal() public {
        vm.startPrank(updateWallet);
        dao.joinDAO();
        
        // Check initial 100 LP tokens
        assertEq(dao.getEffectiveLPBalance(updateWallet), 100 * 1e18);

        // Create proposal (costs 50 LP tokens)
        dao.createProposal("Recycle global plastic waste into eco-bricks", 7);
        assertEq(dao.getEffectiveLPBalance(updateWallet), 50 * 1e18);
        vm.stopPrank();
    }

    function test_RobotSetupAndImmutability() public {
        address roomieBot = address(0x999);
        bytes memory pqcKey = hex"deadbeef";

        vm.startPrank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, pqcKey);
        assertEq(dao.roomieBot(), roomieBot);

        dao.revokeAndUpdatePermissions();
        assertTrue(dao.isImmutable());
        vm.stopPrank();
    }
}
