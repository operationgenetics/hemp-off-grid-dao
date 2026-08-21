// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/EcoBrickDAO.sol";

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

contract EcoBrickDAOTest is Test {
    EcoBrickDAO dao;
    MockDAI dai;
    
    address admin = address(0x1);
    address user1 = address(0x2);
    address updateWallet = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address roomieBot = address(0x4);

    function setUp() public {
        dai = new MockDAI();
        dao = new EcoBrickDAO(address(dai), admin);
    }

    function test_PatentAndUpdateFunctionality() public {
        vm.prank(updateWallet);
        dao.updatePatentInfo("Patented Eco-Brick Matrix v1", "US-PATENT-998877");
        assertEq(dao.patentedEcoBrickModel(), "Patented Eco-Brick Matrix v1");
    }

    function test_RobotSetupAndImmutability() public {
        vm.prank(updateWallet);
        dao.setupRoomieRobotAndLock(roomieBot, hex"ec01");
        assertEq(dao.roomieBot(), roomieBot);

        vm.prank(updateWallet);
        dao.revokeAndUpdatePermissions();
        assertTrue(dao.isImmutable());
    }
}
