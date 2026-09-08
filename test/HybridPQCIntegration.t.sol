// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../src/HempOffGridDAO.sol";
import "../src/crypto/MLDSA65Verifier.sol";

contract MockOBS {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        require(balanceOf[msg.sender] >= a, "bal");
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "bal");
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

/// @notice End-to-end proof that BOTH halves of the hybrid signature are enforced
///         on-chain: secp256k1 by ecrecover, ML-DSA-65 by the registered verifier.
contract HybridPQCIntegrationTest is Test {
    HempOffGridDAO dao;
    MLDSA65Verifier verifier;

    address constant OBS   = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;
    address constant DAI_A = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
    address constant ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;
    address constant CURVE = address(0xC0FFEE);
    address constant VILLAGE = address(0x711A6E);

    address member2 = address(0xA2);
    address member3 = address(0xA3);

    uint256 constant ROBOT_PK = 0xB0B;
    address robotSigner;

    bytes mcuPk;
    bytes ahat;

    function setUp() public {
        vm.warp(1767225600);
        MockOBS impl = new MockOBS();
        vm.etch(OBS, address(impl).code);
        vm.etch(DAI_A, address(impl).code);

        robotSigner = vm.addr(ROBOT_PK);
        mcuPk = vm.readFileBinary("test/vectors/mcu_pk.bin");
        ahat = vm.readFileBinary("test/vectors/mcu_ahat.bin");

        dao = new HempOffGridDAO();
        verifier = new MLDSA65Verifier(mcuPk, ADMIN);
    }

    function _sealVerifier() internal {
        vm.startPrank(ADMIN);
        verifier.commitTr();
        for (uint256 i = 0; i < 3; i++) {
            bytes memory c = new bytes(10240);
            for (uint256 j = 0; j < 10240; j++) c[j] = ahat[i * 10240 + j];
            verifier.commitMatrixChunk(i, c);
        }
        verifier.seal();
        vm.stopPrank();
    }

    /// @dev Asks the stand-in MCU to produce a real ML-DSA-65 signature over `digest`.
    function _mcuPqcSign(bytes32 digest) internal returns (bytes memory) {
        string[] memory cmd = new string[](4);
        cmd[0] = "python3";
        cmd[1] = "tools/mcu_sign.py";
        cmd[2] = "sign";
        cmd[3] = vm.toString(digest);
        return vm.ffi(cmd);
    }

    function _ecdsa(bytes32 digest) internal pure returns (bytes memory) {
        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ROBOT_PK, eth);
        return abi.encodePacked(r, s, v);
    }

    function _openProjectAndUnlock() internal returns (uint256 pid) {
        _sealVerifier();

        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, mcuPk, address(verifier), CURVE);
        dao.admitFoundingMember(member2);
        dao.admitFoundingMember(member3);
        vm.stopPrank();

        MockOBS(OBS).mint(ADMIN, 1_000_000e18);
        vm.startPrank(ADMIN);
        MockOBS(OBS).approve(address(dao), 1_000_000e18);
        dao.depositOBS(1_000_000e18);
        vm.stopPrank();

        vm.prank(ADMIN);   dao.claimMonthlyLP();
        vm.prank(member2); dao.claimMonthlyLP();
        vm.prank(member3); dao.claimMonthlyLP();

        HempOffGridDAO.ProposalInput memory i;
        i.kind = HempOffGridDAO.ProposalKind.CommunitySupply;
        i.category = HempOffGridDAO.ProductCategory.Socks;
        i.siteType = HempOffGridDAO.SiteType.CommunityDistribution;
        i.target = VILLAGE;
        i.amount = 30_000e18;
        i.milestoneCount = 3;
        i.naturalColorOnly = true;
        i.offGridPoweredOnly = true;
        i.humanSafetyCovenant = true;
        i.description = "Off-grid hemp socks";

        vm.prank(ADMIN);
        uint256 id = dao.createProposal(i);
        vm.prank(ADMIN);   dao.vote(id, true, 50e18);
        vm.prank(member2); dao.vote(id, true, 100e18);
        vm.warp(block.timestamp + 15 days);
        dao.finalizeProposal(id);

        vm.store(DAI_A, keccak256(abi.encode(CURVE, uint256(0))), bytes32(uint256(5_000_000_000e18)));
        dao.latchBondingCurveUnlock();

        pid = dao.projectCount();
        vm.warp(block.timestamp + 61 days);
    }

    /*//////////////////////////////////////////////////////////////*/

    function test_RealHybridSignatureReleasesFunds() public {
        uint256 pid = _openProjectAndUnlock();
        bytes32 ev = keccak256("milestone-evidence-1");
        bytes32 digest = dao.authorizationDigest(pid, ev);

        bytes memory pqc = _mcuPqcSign(digest);
        assertEq(pqc.length, 3309, "must be a real ML-DSA-65 signature");

        uint256 g = gasleft();
        dao.authorizeMilestoneAndRelease(pid, ev, _ecdsa(digest), pqc);
        console.log("authorizeMilestoneAndRelease gas (full hybrid):", g - gasleft());

        assertEq(MockOBS(OBS).balanceOf(VILLAGE), 10_000e18, "tranche must be released");
    }

    function test_ForgedPqcSignatureBlocksReleaseEvenWithAValidEcdsa() public {
        uint256 pid = _openProjectAndUnlock();
        bytes32 ev = keccak256("milestone-evidence-1");
        bytes32 digest = dao.authorizationDigest(pid, ev);

        bytes memory pqc = _mcuPqcSign(digest);
        pqc[200] = bytes1(uint8(pqc[200]) ^ 0x01); // flip one bit

        vm.expectRevert(HempOffGridDAO.PqcSignatureRejected.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, _ecdsa(digest), pqc);
        assertEq(MockOBS(OBS).balanceOf(VILLAGE), 0, "no funds may move");
    }

    /// @notice A PQC signature over a DIFFERENT digest must not release this tranche,
    ///         even though it is a perfectly valid ML-DSA-65 signature.
    function test_PqcSignatureForAnotherDigestIsRejected() public {
        uint256 pid = _openProjectAndUnlock();
        bytes32 ev = keccak256("milestone-evidence-1");
        bytes32 digest = dao.authorizationDigest(pid, ev);

        bytes memory wrongPqc = _mcuPqcSign(keccak256("some other authorisation"));

        vm.expectRevert(HempOffGridDAO.PqcSignatureRejected.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, _ecdsa(digest), wrongPqc);
    }

    function test_ValidPqcCannotSubstituteForAMissingEcdsa() public {
        uint256 pid = _openProjectAndUnlock();
        bytes32 ev = keccak256("milestone-evidence-1");
        bytes32 digest = dao.authorizationDigest(pid, ev);
        bytes memory pqc = _mcuPqcSign(digest);

        bytes32 eth = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEADBEEF, eth); // wrong classical key

        vm.expectRevert(HempOffGridDAO.BadMcuSignature.selector);
        dao.authorizeMilestoneAndRelease(pid, ev, abi.encodePacked(r, s, v), pqc);
    }

    /// @notice The DAO must refuse to become immutable while PQC is only anchored.
    function test_CannotSealTheDaoWithoutAPqcVerifier() public {
        vm.startPrank(ADMIN);
        dao.setupRoomieRobotAndLock(robotSigner, mcuPk, address(0), CURVE);
        vm.expectRevert(HempOffGridDAO.PqcVerifierRequired.selector);
        dao.revokeAndFinalize();

        dao.setupRoomieRobotAndLock(robotSigner, mcuPk, address(verifier), CURVE);
        dao.revokeAndFinalize();
        vm.stopPrank();
        assertTrue(dao.registryFinalized(), "seals once full hybrid PQC is in force");
    }
}
