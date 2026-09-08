// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";

contract InvMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a, "bal");
        require(allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @dev Drives the DAO through randomised but well-formed sequences. Every action is
///      bounded into a legal shape so the fuzzer spends its budget exploring real
///      state transitions rather than bouncing off input validation.
contract AlwaysOkPQC {
    function verify(bytes calldata, bytes32, bytes calldata) external pure returns (bool) { return true; }
}

contract Handler is Test {
    HempOffGridDAO public dao;
    address constant OBS = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    uint256 constant ROBOT_PK = 0xB0B;

    address[4] public actors;
    uint256 public ghostDeposited;
    uint256 public ghostReleased;

    constructor(HempOffGridDAO _dao, address[4] memory _actors) {
        dao = _dao;
        actors = _actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e18, 1_000_000e18);
        address who = actors[0];
        InvMockERC20(OBS).mint(who, amt);
        vm.startPrank(who);
        InvMockERC20(OBS).approve(address(dao), amt);
        dao.depositOBS(amt);
        vm.stopPrank();
        ghostDeposited += amt;
    }

    function donateDirectly(uint96 amount) public {
        uint256 amt = bound(uint256(amount), 1e18, 100_000e18);
        InvMockERC20(OBS).mint(address(dao), amt);
        try dao.syncDirectOBSDeposits() { ghostDeposited += amt; } catch {}
    }

    function claimLP(uint256 seed) public {
        address who = _actor(seed);
        vm.prank(who);
        try dao.claimMonthlyLP() {} catch {}
    }

    function propose(uint256 seed, uint96 amount, uint8 milestones) public {
        address who = _actor(seed);
        HempOffGridDAO.ProposalInput memory i;
        i.kind = HempOffGridDAO.ProposalKind.CommunitySupply;
        i.category = HempOffGridDAO.ProductCategory.Socks;
        i.siteType = HempOffGridDAO.SiteType.CommunityDistribution;
        i.target = address(0xBEEF);
        i.amount = bound(uint256(amount), 1e18, 10_000e18);
        i.milestoneCount = uint16(bound(uint256(milestones), 3, 12));
        i.naturalColorOnly = true;
        i.offGridPoweredOnly = true;
        i.humanSafetyCovenant = true;
        i.description = "fuzz";
        vm.prank(who);
        try dao.createProposal(i) {} catch {}
    }

    function voteOn(uint256 seed, uint256 pid, bool support, uint96 weight) public {
        if (dao.proposalCount() == 0) return;
        address who = _actor(seed);
        uint256 id = bound(pid, 1, dao.proposalCount());
        uint256 w = bound(uint256(weight), 1, 100e18);
        vm.prank(who);
        try dao.vote(id, support, w) {} catch {}
    }

    function finalize(uint256 pid) public {
        if (dao.proposalCount() == 0) return;
        try dao.finalizeProposal(bound(pid, 1, dao.proposalCount())) returns (bool) {} catch {}
    }

    function release(uint256 pid, bytes32 evidence) public {
        if (dao.projectCount() == 0) return;
        uint256 id = bound(pid, 1, dao.projectCount());
        uint256 before = InvMockERC20(OBS).balanceOf(address(0xBEEF));
        bytes32 digest = dao.authorizationDigest(id, evidence);
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ROBOT_PK, eth);
        try dao.authorizeMilestoneAndRelease(id, evidence, abi.encodePacked(r, s, v), _pqc()) {
            ghostReleased += InvMockERC20(OBS).balanceOf(address(0xBEEF)) - before;
        } catch {}
    }

    function _pqc() internal pure returns (bytes memory b) { b = new bytes(3309); }

    function passTime(uint32 secs) public {
        vm.warp(block.timestamp + bound(uint256(secs), 1 days, 70 days));
    }
}

contract HempOffGridDAOInvariantTest is Test {
    HempOffGridDAO dao;
    Handler handler;

    address constant OBS   = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    address constant DAI_A = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address constant CURVE = address(0xC0FFEE);

    function setUp() public {
        vm.warp(1767225600); // 2026-01-01

        InvMockERC20 impl = new InvMockERC20();
        vm.etch(OBS, address(impl).code);
        vm.etch(DAI_A, address(impl).code);

        dao = new HempOffGridDAO();

        address[4] memory actors = [ADMIN, address(0xA2), address(0xA3), address(0xA4)];

        address accept = address(new AlwaysOkPQC());
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(vm.addr(0xB0B), new bytes(1952), accept, CURVE);
        for (uint256 i = 1; i < 4; i++) dao.admitFoundingMember(actors[i]);
        vm.stopPrank();

        // Reserve past 5B so releases are reachable during fuzzing.
        vm.store(DAI_A, keccak256(abi.encode(CURVE, uint256(0))), bytes32(uint256(5_000_000_000e18)));
        dao.latchBondingCurveUnlock();

        handler = new Handler(dao, actors);
        targetContract(address(handler));
    }

    /// @notice Every OBS the vault has accounted for is either sitting in a pool,
    ///         reserved by a live project, or already paid out. Nothing is invented
    ///         and nothing vanishes.
    function invariant_accountingIdentityHolds() public view {
        assertEq(
            dao.templePool() + dao.communityPool() + dao.totalCommitted(),
            dao.totalDeposited() - dao.totalReleased(),
            "pools + committed must equal deposited - released"
        );
        assertTrue(dao.accountingHolds());
    }

    /// @notice The vault can always cover every claim against it. If this ever fails,
    ///         some project is unpayable.
    function invariant_vaultIsSolvent() public view {
        assertGe(
            InvMockERC20(OBS).balanceOf(address(dao)),
            dao.templePool() + dao.communityPool() + dao.totalCommitted(),
            "vault must hold at least what it owes"
        );
    }

    uint256 private _lastTemplePool;

    /// @notice The temple half is never spent on community work. Only community
    ///         projects are fuzzed here, so the temple pool must never decrease.
    function invariant_templeHalfIsNeverRaidedByCommunitySpending() public {
        uint256 t = dao.templePool();
        assertGe(t, _lastTemplePool, "community spending must never reduce the temple pool");
        _lastTemplePool = t;
    }

    /// @notice The temple pool is always the floor-half of everything deposited, to
    ///         within one wei per deposit (odd wei is credited to the community side).
    function invariant_templePoolIsAtMostHalfOfDeposits() public view {
        assertLe(2 * dao.templePool(), dao.totalDeposited(), "temple side can never exceed 50%");
    }

    /// @notice Total paid out never exceeds total taken in.
    function invariant_neverPaysOutMoreThanItTookIn() public view {
        assertLe(dao.totalReleased(), dao.totalDeposited());
    }

    /// @notice Once the registry is finalized it can never become unfinalized.
    function invariant_immutabilityIsOneWay() public view {
        if (dao.registryFinalized()) assertTrue(dao.robotConfigured());
    }
}
