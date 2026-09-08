// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";

contract MockERC20 {
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

/// @dev Stub that accepts any PQC signature, to exercise the on-chain-verifier path.
contract AcceptAllPQC is IPQCVerifier {
    function verify(bytes calldata, bytes32, bytes calldata) external pure returns (bool) { return true; }
}

/// @dev Stub that rejects, to prove a bad PQC signature actually blocks a release.
contract RejectAllPQC is IPQCVerifier {
    function verify(bytes calldata, bytes32, bytes calldata) external pure returns (bool) { return false; }
}

contract HempOffGridDAOTest is Test {
    HempOffGridDAO dao;

    address constant OBS   = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    address constant DAI_A = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    address constant CURVE   = address(0xC0FFEE);
    address constant TEMPLE  = address(0x7E11);
    address constant VILLAGE = address(0x711A6E);

    address member2 = address(0xA2);
    address member3 = address(0xA3);
    address member4 = address(0xA4);

    uint256 constant ROBOT_PK = 0xB0B;
    address robotSigner;

    uint256 constant JAN_2026 = 1767225600; // 2026-01-01 00:00:00 UTC

    function setUp() public {
        vm.warp(JAN_2026);

        MockERC20 impl = new MockERC20();
        vm.etch(OBS, address(impl).code);
        vm.etch(DAI_A, address(impl).code);

        robotSigner = vm.addr(ROBOT_PK);
        dao = new HempOffGridDAO();
    }

    /*//////////////////////////////////////////////////////////////
                            WIRING / CONSTANTS
    //////////////////////////////////////////////////////////////*/

    function test_ObsTokenAddressIsCorrect() public view {
        assertEq(dao.OBS_TOKEN(), 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0);
    }

    function test_AdminWalletIsCorrect() public view {
        assertEq(dao.ROBOT_REGISTRY_ADMIN(), 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e);
    }

    function test_BondingCurveThresholdIsFiveBillionDai() public view {
        assertEq(dao.BONDING_CURVE_UNLOCK_DAI(), 5_000_000_000 * 1e18);
    }

    function test_GovernanceConstants() public view {
        assertEq(dao.LP_MONTHLY_ISSUANCE(), 100e18);
        assertEq(dao.LP_PROPOSAL_COST(), 50e18);
        assertEq(dao.MCU_AUTHORIZATION_INTERVAL(), 60 days);
    }

    function test_AdminIsFoundingMemberSoNoPostDeploySetupIsNeeded() public view {
        assertTrue(dao.isMember(ADMIN));
        assertEq(dao.memberCount(), 1);
    }

    function test_ContractRefusesEther() public {
        vm.deal(ADMIN, 1 ether);
        vm.prank(ADMIN);
        (bool ok,) = address(dao).call{value: 1 ether}("");
        assertFalse(ok, "ETH must be refused; the contract becomes immutable with no ETH exit");
    }

    /*//////////////////////////////////////////////////////////////
                    ROBOT REGISTRY: SETUP -> UPDATE -> REVOKE
    //////////////////////////////////////////////////////////////*/

    function test_SetupRoomieRobotAndLockWorksImmediatelyAfterDeploy() public {
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, hex"01", address(0), CURVE);

        assertTrue(dao.robotConfigured());
        assertEq(dao.robotSignerEOA(), robotSigner);
        assertEq(dao.pqcPublicKeyHash(), keccak256(hex"01"));
        assertFalse(dao.registryFinalized());
    }

    function test_RobotDetailsCanBeUpdatedWhenRealHardwareArrives() public {
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, hex"01", address(0), CURVE);

        address realRobot = vm.addr(0xBEEF);
        bytes memory realKey = _pqcKey(1952); // ML-DSA-65 public key size
        address verifier = address(new AcceptAllPQC());
        dao.setupRoomieRobotAndLock(realRobot, realKey, verifier, CURVE);
        vm.stopPrank();

        assertEq(dao.robotSignerEOA(), realRobot);
        assertEq(dao.pqcPublicKey(), realKey);
        assertEq(dao.pqcVerifier(), verifier);
    }

    function test_OnlyAdminWalletCanSetupRobot() public {
        vm.prank(member2);
        vm.expectRevert(HempOffGridDAO.NotRegistryAdmin.selector);
        dao.setupRoomieRobotAndLock(robotSigner, hex"01", address(0), CURVE);
    }

    function test_FinalizeIsRefusedOnAPlaceholderKey() public {
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, hex"01", address(0), CURVE);
        vm.expectRevert(HempOffGridDAO.PlaceholderKeyCannotBeFinalized.selector);
        dao.revokeAndFinalize();
        vm.stopPrank();
    }

    function test_RevokeMakesContractPermanentlyImmutable() public {
        address accept = address(new AcceptAllPQC());
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), accept, CURVE);
        dao.revokeAndFinalize();
        assertTrue(dao.registryFinalized());

        vm.expectRevert(HempOffGridDAO.RegistryIsFinalized.selector);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), accept, CURVE);

        vm.expectRevert(HempOffGridDAO.RegistryIsFinalized.selector);
        dao.admitFoundingMember(member2);

        vm.expectRevert(HempOffGridDAO.RegistryIsFinalized.selector);
        dao.revokeAndFinalize();
        vm.stopPrank();
    }

    function test_NoBiometricStorageExistsOnChain() public {
        // The ABI has no setter or getter that accepts or returns biometric data.
        // Only the PQC PUBLIC key is stored, exactly as specified.
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), address(0), CURVE);
        assertEq(dao.pqcPublicKey().length, 1952);
    }

    /*//////////////////////////////////////////////////////////////
                            CALENDAR-MONTH LP
    //////////////////////////////////////////////////////////////*/

    function test_CalendarMonthMathIsExactIncludingLeapYears() public {
        vm.warp(JAN_2026);            assertEq(dao.currentPeriod(), 202601);
        vm.warp(1772236800);          assertEq(dao.currentPeriod(), 202602); // 2026-02-28
        vm.warp(1772323200);          assertEq(dao.currentPeriod(), 202603); // 2026-03-01
        vm.warp(1835395200);          assertEq(dao.currentPeriod(), 202802); // 2028-02-29 (leap)
        vm.warp(1835481600);          assertEq(dao.currentPeriod(), 202803); // 2028-03-01
        vm.warp(1798761599);          assertEq(dao.currentPeriod(), 202612); // 2026-12-31 23:59:59
    }

    function test_HundredLpIssuedMonthlyAndOnlyOncePerMonth() public {
        vm.prank(ADMIN);
        dao.claimMonthlyLP();
        assertEq(dao.votingPower(ADMIN), 100e18);

        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.LPAlreadyClaimedThisMonth.selector);
        dao.claimMonthlyLP();
    }

    function test_UnusedLpExpiresAtEndOfMonthAndNeverAccumulates() public {
        vm.prank(ADMIN);
        dao.claimMonthlyLP();
        assertEq(dao.votingPower(ADMIN), 100e18);

        vm.warp(1772323200); // 2026-03-01: two months later, LP untouched
        assertEq(dao.votingPower(ADMIN), 0, "unused LP must expire at month end");

        vm.prank(ADMIN);
        dao.claimMonthlyLP();
        assertEq(dao.votingPower(ADMIN), 100e18, "new month grants exactly 100, not 200");
    }

    function test_NonMembersCannotClaimLp() public {
        vm.prank(member2);
        vm.expectRevert(HempOffGridDAO.NotAMember.selector);
        dao.claimMonthlyLP();
    }

    /*//////////////////////////////////////////////////////////////
                         PROPOSALS AND WEIGHTED VOTING
    //////////////////////////////////////////////////////////////*/

    function test_FiftyLpIsRequiredToPropose() public {
        _bootstrapMembers();

        // member2 has claimed nothing yet.
        vm.prank(member2);
        vm.expectRevert(HempOffGridDAO.InsufficientLP.selector);
        dao.createProposal(_memberInput(member4));

        vm.prank(member2);
        dao.claimMonthlyLP();
        vm.prank(member2);
        dao.createProposal(_memberInput(member4));

        assertEq(dao.votingPower(member2), 50e18, "proposing must consume exactly 50 LP");
    }

    function test_VotesAreOneToOneWithLpAndLpIsConsumed() public {
        _bootstrapMembers();
        _claimAll();

        vm.prank(ADMIN);
        uint256 id = dao.createProposal(_memberInput(member4));

        vm.prank(member2);
        dao.vote(id, true, 40e18);
        assertEq(dao.votingPower(member2), 60e18, "voting consumes LP 1:1");

        HempOffGridDAO.Proposal memory p = dao.getProposal(id);
        assertEq(p.forVotes, 40e18, "1 LP must equal exactly 1 vote");

        vm.prank(member2);
        vm.expectRevert(HempOffGridDAO.AlreadyVoted.selector);
        dao.vote(id, true, 10e18);
    }

    function test_CannotVoteWithMoreLpThanHeld() public {
        _bootstrapMembers();
        _claimAll();
        vm.prank(ADMIN);
        uint256 id = dao.createProposal(_memberInput(member4));

        vm.prank(member2);
        vm.expectRevert(HempOffGridDAO.InsufficientLP.selector);
        dao.vote(id, true, 101e18);
    }

    function test_QuorumAndMajorityAreEnforced() public {
        _bootstrapMembers();
        _claimAll(); // 3 members x 100 LP = 300 issued; quorum = 20% = 60 LP

        vm.prank(ADMIN);
        uint256 id = dao.createProposal(_memberInput(member4));
        vm.prank(ADMIN);
        dao.vote(id, true, 50e18); // turnout 50 < 60

        vm.warp(block.timestamp + 15 days);
        assertFalse(dao.finalizeProposal(id), "must fail on quorum");
        assertFalse(dao.isMember(member4));
    }

    function test_PassedAdmitMemberProposalGrantsMembership() public {
        _bootstrapMembers();
        _claimAll();
        uint256 id = _passProposal(_memberInput(member4));
        assertTrue(dao.isMember(member4));
        assertEq(dao.memberCount(), 4);
        HempOffGridDAO.Proposal memory p = dao.getProposal(id);
        assertTrue(p.passed);
    }

    /*//////////////////////////////////////////////////////////////
                       HARD-CODED PROGRAMME RULES
    //////////////////////////////////////////////////////////////*/

    function test_FundingProposalIsRejectedWithoutTheCovenants() public {
        _bootstrapFunded();
        HempOffGridDAO.ProposalInput memory i = _supplyInput();

        i.naturalColorOnly = false;
        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.CovenantNotAccepted.selector);
        dao.createProposal(i);

        i.naturalColorOnly = true; i.offGridPoweredOnly = false;
        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.CovenantNotAccepted.selector);
        dao.createProposal(i);

        i.offGridPoweredOnly = true; i.humanSafetyCovenant = false;
        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.CovenantNotAccepted.selector);
        dao.createProposal(i);
    }

    function test_TempleSupplyRequiresARegisteredTemple() public {
        _bootstrapFunded();
        HempOffGridDAO.ProposalInput memory i = _supplyInput();
        i.kind = HempOffGridDAO.ProposalKind.TempleSupply;
        i.siteType = HempOffGridDAO.SiteType.HinduTempleVerticalGrow;
        i.target = address(0xDEAD);

        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.TempleNotRegistered.selector);
        dao.createProposal(i);
    }

    function test_SiteTypeMustMatchTheFundingPool() public {
        _bootstrapFunded();
        HempOffGridDAO.ProposalInput memory i = _supplyInput();
        i.siteType = HempOffGridDAO.SiteType.HinduTempleVerticalGrow; // wrong for CommunitySupply

        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.CategorySiteMismatch.selector);
        dao.createProposal(i);
    }

    function test_MilestoneCountFloorIsEnforced() public {
        _bootstrapFunded();
        HempOffGridDAO.ProposalInput memory i = _supplyInput();
        i.milestoneCount = 2;

        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.BadMilestoneCount.selector);
        dao.createProposal(i);
    }

    function test_TrancheLargerThanTheReleaseCapIsRejectedUpFront() public {
        _bootstrapFunded(); // 1,000,000 OBS deposited => 5% window cap = 50,000
        HempOffGridDAO.ProposalInput memory i = _supplyInput();
        i.amount = 300_000e18;
        i.milestoneCount = 3; // 100,000 per tranche > 50,000 cap

        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.TrancheExceedsReleaseCap.selector);
        dao.createProposal(i);
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT AND 50/50 ALLOCATION
    //////////////////////////////////////////////////////////////*/

    function test_DepositsSplitFiftyFiftyBetweenTempleAndCommunity() public {
        _mintObs(ADMIN, 1_000e18);
        vm.startPrank(ADMIN);
        MockERC20(OBS).approve(address(dao), 1_000e18);
        dao.depositOBS(1_000e18);
        vm.stopPrank();

        assertEq(dao.templePool(), 500e18);
        assertEq(dao.communityPool(), 500e18);
        assertEq(dao.totalDeposited(), 1_000e18);
    }

    function test_DirectlyTransferredObsCanBeRecoveredIntoThePools() public {
        _mintObs(member2, 400e18);
        vm.prank(member2);
        MockERC20(OBS).transfer(address(dao), 400e18); // bypasses depositOBS

        assertEq(dao.templePool(), 0);
        dao.syncDirectOBSDeposits();
        assertEq(dao.templePool(), 200e18);
        assertEq(dao.communityPool(), 200e18);

        vm.expectRevert(HempOffGridDAO.NothingToSync.selector);
        dao.syncDirectOBSDeposits();
    }

    function test_VaultStaysLockedBelowFiveBillionDai() public {
        _bootstrapFunded();
        _setReserve(4_999_999_999e18);
        vm.expectRevert(HempOffGridDAO.ThresholdNotMet.selector);
        dao.latchBondingCurveUnlock();
        assertFalse(dao.bondingCurveUnlocked());
    }

    function test_UnlockLatchesAndSurvivesAReserveDip() public {
        _bootstrapFunded();
        _setReserve(5_000_000_000e18);
        dao.latchBondingCurveUnlock();
        assertTrue(dao.bondingCurveUnlocked());

        _setReserve(0); // curve drains later
        assertTrue(dao.bondingCurveUnlocked(), "unlock must latch, or live projects re-lock mid-build");
    }

    function test_NoObsCanLeaveTheVaultBeforeTheCurveUnlocks() public {
        (uint256 pid,) = _openFundedProject();
        vm.warp(block.timestamp + 61 days);

        (bytes memory ecdsa, bytes memory pqc) = _sign(pid, keccak256("evidence"));
        vm.expectRevert(HempOffGridDAO.VaultLocked.selector);
        dao.authorizeMilestoneAndRelease(pid, keccak256("evidence"), ecdsa, pqc);
    }

    /*//////////////////////////////////////////////////////////////
              HYBRID PQC MCU AUTHORISATION AND MILESTONE TIMEOUT
    //////////////////////////////////////////////////////////////*/

    function test_ValidMcuSignatureReleasesExactlyOneTranche() public {
        (uint256 pid,) = _openFundedProject();
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("milestone-1");
        (bytes memory ecdsa, bytes memory pqc) = _sign(pid, ev);
        dao.authorizeMilestoneAndRelease(pid, ev, ecdsa, pqc);

        assertEq(MockERC20(OBS).balanceOf(VILLAGE), 10_000e18, "one equal tranche of 30,000/3");
        HempOffGridDAO.Project memory pr = dao.getProject(pid);
        assertEq(pr.milestonesDone, 1);
        assertFalse(pr.complete);
    }

    function test_WrongSignerCannotReleaseFunds() public {
        (uint256 pid,) = _openFundedProject();
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m1");
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dao.authorizationDigest(pid, ev)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEADBEEF, eth); // impostor
        vm.expectRevert(HempOffGridDAO.BadMcuSignature.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, abi.encodePacked(r, s, v), hex"aa");
    }

    function test_MissingPqcHalfIsRejected() public {
        (uint256 pid,) = _openFundedProject();
        // Drop back to the anchor-only branch to exercise its length rule.
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), address(0), CURVE);
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m1");
        (bytes memory ecdsa,) = _sign(pid, ev);
        vm.expectRevert(HempOffGridDAO.BadPqcSignatureLength.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, ecdsa, "");
    }

    function test_RegisteredPqcVerifierIsActuallyCalledAndCanBlockRelease() public {
        (uint256 pid,) = _openFundedProject();
        // Swap in a rejecting PQC verifier before finalisation.
        address rejecting = address(new RejectAllPQC());
        vm.prank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), rejecting, CURVE);
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m1");
        (bytes memory ecdsa, bytes memory pqc) = _sign(pid, ev);
        vm.expectRevert(HempOffGridDAO.PqcSignatureRejected.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, ecdsa, pqc);
    }

    function test_SignatureCannotBeReplayedForASecondTranche() public {
        (uint256 pid,) = _openFundedProject();
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m1");
        (bytes memory ecdsa, bytes memory pqc) = _sign(pid, ev);
        dao.authorizeMilestoneAndRelease(pid, ev, ecdsa, pqc);

        vm.warp(block.timestamp + 61 days);
        vm.expectRevert(HempOffGridDAO.BadMcuSignature.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, ecdsa, pqc); // nonce advanced
    }

    function test_RobotCannotAuthorizeMoreOftenThanEveryTwoMonths() public {
        (uint256 pid,) = _openFundedProject();
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m1");
        (bytes memory e1, bytes memory p1) = _sign(pid, ev);
        dao.authorizeMilestoneAndRelease(pid, ev, e1, p1);

        vm.warp(block.timestamp + 59 days); // one day early
        (bytes memory e2, bytes memory p2) = _sign(pid, ev);
        vm.expectRevert(HempOffGridDAO.TooSoonForNextAuthorization.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, e2, p2);
    }

    function test_ProjectPaysOutInFullOnlyAfterEveryMilestone() public {
        (uint256 pid,) = _openFundedProject();
        _unlockCurve();

        // Hold the clock in a local: via-IR hoists a bare block.timestamp read out
        // of the loop, silently reusing the pre-warp value.
        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 3; i++) {
            t += 61 days;
            vm.warp(t);
            bytes32 ev = keccak256(abi.encode("m", i));
            (bytes memory e, bytes memory p) = _sign(pid, ev);
            dao.authorizeMilestoneAndRelease(pid, ev, e, p);
        }

        assertEq(MockERC20(OBS).balanceOf(VILLAGE), 30_000e18, "exactly the approved total, no dust lost");
        HempOffGridDAO.Project memory pr = dao.getProject(pid);
        assertTrue(pr.complete);
        assertEq(dao.totalReleased(), 30_000e18);
        assertEq(dao.totalCommitted(), 0);

        vm.warp(block.timestamp + 61 days);
        bytes32 ev2 = keccak256("extra");
        (bytes memory e2, bytes memory p2) = _sign(pid, ev2);
        vm.expectRevert(HempOffGridDAO.ProjectAlreadyComplete.selector);
        dao.authorizeMilestoneAndRelease(pid, ev2, e2, p2);
    }

    function test_ProjectCannotBeDrainedFasterThanItsMilestoneSchedule() public {
        (uint256 pid,) = _openFundedProject();
        assertEq(dao.minimumProjectDuration(pid), 3 * 60 days, "3 milestones x 60 days = 180 days minimum");
    }

    /*//////////////////////////////////////////////////////////////
                                FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_PeriodIsAlwaysAValidMonthAndNeverGoesBackwards(uint40 a, uint40 b) public {
        uint256 t1 = bound(uint256(a), JAN_2026, 4_102_444_800); // 2026 .. 2100
        uint256 t2 = bound(uint256(b), t1, 4_102_444_800);

        vm.warp(t1);
        uint256 p1 = dao.currentPeriod();
        vm.warp(t2);
        uint256 p2 = dao.currentPeriod();

        uint256 m1 = p1 % 100;
        assertTrue(m1 >= 1 && m1 <= 12, "month must be 1..12");
        assertTrue(p1 / 100 >= 2026 && p1 / 100 <= 2100, "year must be sane");
        assertGe(p2, p1, "calendar period must never run backwards");
    }

    function testFuzz_DepositSplitNeverLosesOrInventsAWei(uint128 amount) public {
        uint256 amt = bound(uint256(amount), 1, type(uint128).max);
        _mintObs(ADMIN, amt);
        vm.startPrank(ADMIN);
        MockERC20(OBS).approve(address(dao), amt);
        dao.depositOBS(amt);
        vm.stopPrank();

        assertEq(dao.templePool() + dao.communityPool(), amt, "split must be lossless");
        assertEq(dao.totalDeposited(), amt);
        assertLe(dao.communityPool() - dao.templePool(), 1, "halves differ by at most the odd wei");
        assertTrue(dao.accountingHolds());
    }

    function testFuzz_ProjectPaysExactlyTheApprovedTotal(uint8 rawMilestones, uint96 rawAmount) public {
        uint16 milestones = uint16(bound(uint256(rawMilestones), 3, 12));
        uint256 amount = bound(uint256(rawAmount), 1e18, 30_000e18);

        _bootstrapFunded();
        HempOffGridDAO.ProposalInput memory i = _supplyInput();
        i.amount = amount;
        i.milestoneCount = milestones;
        _passProposal(i);

        uint256 pid = dao.projectCount();
        _unlockCurve();

        uint256 t = block.timestamp;
        for (uint256 k = 0; k < milestones; k++) {
            t += 61 days;
            vm.warp(t);
            bytes32 ev = keccak256(abi.encode(k));
            (bytes memory e, bytes memory p) = _sign(pid, ev);
            dao.authorizeMilestoneAndRelease(pid, ev, e, p);
        }

        assertEq(MockERC20(OBS).balanceOf(VILLAGE), amount, "exact total, no dust lost or created");
        assertTrue(dao.getProject(pid).complete);
        assertEq(dao.totalCommitted(), 0);
        assertTrue(dao.accountingHolds());
    }

    function testFuzz_OnlyTheRegisteredMcuKeyCanEverReleaseFunds(uint256 wrongPk) public {
        uint256 pk = bound(wrongPk, 1, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140 - 1);
        vm.assume(pk != ROBOT_PK);

        (uint256 pid,) = _openFundedProject();
        _unlockCurve();
        vm.warp(block.timestamp + 61 days);

        bytes32 ev = keccak256("m");
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", dao.authorizationDigest(pid, ev)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, eth);

        vm.expectRevert(HempOffGridDAO.BadMcuSignature.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, abi.encodePacked(r, s, v), hex"aa");
    }

    /*//////////////////////////////////////////////////////////////
                     FULL REAL-WORLD LIFECYCLE
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact sequence the operator will actually perform:
    ///         deploy -> lock a placeholder robot -> fund the vault -> real hardware
    ///         arrives -> revoke into immutability -> curve hits 5B -> a community
    ///         project runs to completion under MCU authorisation, with no admin
    ///         involvement of any kind after revocation.
    function test_FullLifecycleFromDeployToCompletedProjectAfterImmutability() public {
        // 1. Immediately after deploy: lock in a placeholder robot.
        address accept = address(new AcceptAllPQC());
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(address(0xDEAD), hex"01", accept, CURVE);
        dao.admitFoundingMember(member2);
        dao.admitFoundingMember(member3);
        dao.registerFoundingTemple(TEMPLE);
        vm.stopPrank();
        assertTrue(dao.robotConfigured());

        // 2. Fund the vault. 50/50 split is enforced on the way in.
        _mintObs(ADMIN, 1_000_000e18);
        vm.startPrank(ADMIN);
        MockERC20(OBS).approve(address(dao), 1_000_000e18);
        dao.depositOBS(1_000_000e18);
        vm.stopPrank();
        assertEq(dao.templePool(), 500_000e18);
        assertEq(dao.communityPool(), 500_000e18);

        // 3. Real Roomie hardware arrives: swap in the true MCU key, then revoke.
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), accept, CURVE);
        dao.revokeAndFinalize();
        vm.stopPrank();
        assertTrue(dao.registryFinalized());

        // 4. From here the admin wallet is powerless. Governance must stand alone.
        vm.prank(ADMIN);
        vm.expectRevert(HempOffGridDAO.RegistryIsFinalized.selector);
        dao.admitFoundingMember(member4);

        _claimAll();
        uint256 admitId = _passProposal(_memberInput(member4));
        assertTrue(dao.isMember(member4), "DAO must still admit members with no admin");
        assertTrue(dao.getProposal(admitId).passed);

        // 5. Bonding curve reaches 5B DAI. Anyone may latch the unlock.
        _setReserve(5_000_000_000e18);
        vm.prank(member4);
        dao.latchBondingCurveUnlock();
        assertTrue(dao.bondingCurveUnlocked());

        // 6. A community supply project passes and runs to completion.
        vm.warp(block.timestamp + 32 days); // next calendar month, fresh LP
        _claimAll();
        uint256 pid = dao.projectCount();
        _passProposal(_supplyInput());
        pid = dao.projectCount();
        assertEq(pid, 1);

        uint256 t = block.timestamp;
        for (uint256 i = 0; i < 3; i++) {
            t += 61 days;
            vm.warp(t);
            bytes32 ev = keccak256(abi.encode("milestone", i));
            (bytes memory e, bytes memory p) = _sign(pid, ev);
            dao.authorizeMilestoneAndRelease(pid, ev, e, p);
        }

        assertTrue(dao.getProject(pid).complete);
        assertEq(MockERC20(OBS).balanceOf(VILLAGE), 30_000e18);
        // The community pool paid; the temple pool is untouched. 50/50 holds.
        assertEq(dao.templePool(), 500_000e18);
        assertEq(dao.communityPool(), 470_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev 3309 bytes, the exact ML-DSA-65 signature size the DAO now requires.
    function _pqcBlob(bytes32 seed) internal pure returns (bytes memory b) {
        b = new bytes(3309);
        for (uint256 i = 0; i < 3309; i += 32) {
            bytes32 w = keccak256(abi.encode(seed, i));
            for (uint256 j = 0; j < 32 && i + j < 3309; j++) b[i + j] = w[j];
        }
    }

    function _pqcKey(uint256 len) internal pure returns (bytes memory k) {
        k = new bytes(len);
        for (uint256 i = 0; i < len; i++) k[i] = bytes1(uint8(i % 251));
    }

    function _mintObs(address to, uint256 a) internal { MockERC20(OBS).mint(to, a); }
    function _setReserve(uint256 a) internal {
        vm.store(DAI_A, keccak256(abi.encode(CURVE, uint256(0))), bytes32(a));
    }

    function _bootstrapMembers() internal {
        address accept = address(new AcceptAllPQC());
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, _pqcKey(1952), accept, CURVE);
        dao.admitFoundingMember(member2);
        dao.admitFoundingMember(member3);
        dao.registerFoundingTemple(TEMPLE);
        vm.stopPrank();
    }

    function _claimAll() internal {
        vm.prank(ADMIN);   dao.claimMonthlyLP();
        vm.prank(member2); dao.claimMonthlyLP();
        vm.prank(member3); dao.claimMonthlyLP();
    }

    function _bootstrapFunded() internal {
        _bootstrapMembers();
        _claimAll();
        _mintObs(ADMIN, 1_000_000e18);
        vm.startPrank(ADMIN);
        MockERC20(OBS).approve(address(dao), 1_000_000e18);
        dao.depositOBS(1_000_000e18);
        vm.stopPrank();
    }

    function _unlockCurve() internal {
        _setReserve(5_000_000_000e18);
        dao.latchBondingCurveUnlock();
    }

    function _memberInput(address who) internal pure returns (HempOffGridDAO.ProposalInput memory i) {
        i.kind = HempOffGridDAO.ProposalKind.AdmitMember;
        i.target = who;
        i.description = "admit";
    }

    function _supplyInput() internal pure returns (HempOffGridDAO.ProposalInput memory i) {
        i.kind = HempOffGridDAO.ProposalKind.CommunitySupply;
        i.category = HempOffGridDAO.ProductCategory.Socks;
        i.siteType = HempOffGridDAO.SiteType.CommunityDistribution;
        i.target = VILLAGE;
        i.amount = 30_000e18;
        i.milestoneCount = 3;
        i.naturalColorOnly = true;
        i.offGridPoweredOnly = true;
        i.humanSafetyCovenant = true;
        i.description = "Off-grid hemp socks for a community in need";
    }

    function _passProposal(HempOffGridDAO.ProposalInput memory i) internal returns (uint256 id) {
        vm.prank(ADMIN);
        id = dao.createProposal(i);
        vm.prank(ADMIN);   dao.vote(id, true, 50e18);
        vm.prank(member2); dao.vote(id, true, 100e18);
        vm.warp(block.timestamp + 15 days);
        dao.finalizeProposal(id);
    }

    /// @return pid the opened project id
    function _openFundedProject() internal returns (uint256 pid, uint256 proposalId) {
        _bootstrapFunded();
        proposalId = _passProposal(_supplyInput());
        pid = dao.projectCount();
        assertEq(pid, 1, "project must open on a passed funding proposal");
    }

    function _sign(uint256 pid, bytes32 ev) internal view returns (bytes memory ecdsa, bytes memory pqc) {
        bytes32 digest = dao.authorizationDigest(pid, ev);
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ROBOT_PK, eth);
        ecdsa = abi.encodePacked(r, s, v);
        pqc = _pqcBlob(digest);
    }
}
