#!/usr/bin/env bash
set -e

echo "=== 1. Initializing Foundry Workspace ==="
foundryup || true
rm -rf src test foundry.toml
forge init --no-git --force
rm -f src/Counter.sol test/Counter.t.sol

echo "=== 2. Writing HempOffGridDAO.sol ==="
cat << 'SOL' > src/HempOffGridDAO.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract HempOffGridDAO {
    uint256 public constant THRESHOLD_DAI = 5_000_000_000 * 1e18;
    address public immutable obsBondingCurve;
    IERC20 public immutable arbitrumDAI;

    address public updateWallet;
    address public adminAddress;
    address public roomieBot;
    
    // Patent & Model tracking fields
    string public patentedEcoBrickModel;
    string public patentTitle;
    string public patentApplicationNumber;
    string public patentPublicationNumber;
    string public patentGrantNumber;

    // Hemp Vertical Grow & Product Rules
    string public constant HEMP_SPECIFICATION = "GMO hemp, all natural hemp color, no added colors";
    string public constant PRODUCT_SCOPE = "Clothing (socks, pants/joggers, shorts, long sleeve, short sleeve, tank top, men & women underwear), hemp toilet paper and wipes";
    
    // DAO Allocation Rules (50% Hindu Temples 501(c)(7), 50% Global Communities)
    uint256 public constant TEMPLE_ALLOCATION_PERCENT = 50;
    uint256 public constant COMMUNITY_ALLOCATION_PERCENT = 50;
    
    address public hinduTempleBeneficiary; // 501(c)(7) vertical grow recipient

    bool public isImmutable = false;

    struct Proposal {
        string description;
        address payable recipient;
        uint256 amount;
        bool isTempleAllocation;
        uint256 yesVotes;
        uint256 noVotes;
        bool executed;
        uint256 deadline;
    }

    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(address => uint256) public memberWeights;
    mapping(address => bool) public verifiedManufacturingSitePresence;
    uint256 public proposalCount;
    uint256 public totalVotingWeight;

    event PatentedEcoBrickUpdated(string newModel);
    event PatentDetailsUpdated(string patentTitle, string applicationNumber, string publicationNumber, string grantNumber);
    event RoomieBotUpdated(address indexed newRoomieBot);
    event RoomieBotSiteVerified(address indexed workerOrBot, bool verified);
    event TempleBeneficiaryUpdated(address indexed newTemple);
    event ProposalCreated(uint256 indexed proposalId, string description, address recipient, uint256 amount, bool isTempleAllocation);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event PermissionsRevoked(address indexed updateWallet);

    modifier onlyUpdateWallet() {
        require(msg.sender == updateWallet, "Unauthorized: Only update wallet");
        require(!isImmutable, "Contract state is immutable");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Unauthorized: Only admin address");
        _;
    }

    modifier onlyRoomieBot() {
        require(msg.sender == roomieBot, "Unauthorized: Only Roomie Bot");
        _;
    }

    modifier fundsUnlocked() {
        require(arbitrumDAI.balanceOf(obsBondingCurve) >= THRESHOLD_DAI, "Treasury locked: 5B DAI threshold not met");
        _;
    }

    constructor(
        address _obsBondingCurve,
        address _arbitrumDAI,
        address _updateWallet,
        address _adminAddress,
        address _roomieBot,
        address _hinduTempleBeneficiary,
        address[] memory initialMembers,
        uint256[] memory weights
    ) {
        require(initialMembers.length == weights.length, "Mismatched member and weight lengths");
        obsBondingCurve = _obsBondingCurve;
        arbitrumDAI = IERC20(_arbitrumDAI);
        updateWallet = _updateWallet;
        adminAddress = _adminAddress;
        roomieBot = _roomieBot;
        hinduTempleBeneficiary = _hinduTempleBeneficiary;
        
        patentedEcoBrickModel = "Pending Patent Issuance";
        patentTitle = "Pending";
        patentApplicationNumber = "Pending";
        patentPublicationNumber = "Pending";
        patentGrantNumber = "Pending";

        for (uint256 i = 0; i < initialMembers.length; i++) {
            memberWeights[initialMembers[i]] = weights[i];
            totalVotingWeight += weights[i];
        }
    }

    function setPatentedEcoBrick(string memory _model) external onlyAdmin {
        patentedEcoBrickModel = _model;
        emit PatentedEcoBrickUpdated(_model);
    }

    function setPatentDetails(
        string memory _patentTitle,
        string memory _patentApplicationNumber,
        string memory _patentPublicationNumber,
        string memory _patentGrantNumber
    ) external onlyUpdateWallet {
        patentTitle = _patentTitle;
        patentApplicationNumber = _patentApplicationNumber;
        patentPublicationNumber = _patentPublicationNumber;
        patentGrantNumber = _patentGrantNumber;
        
        emit PatentDetailsUpdated(_patentTitle, _patentApplicationNumber, _patentPublicationNumber, _patentGrantNumber);
    }

    function setRoomieBot(address _roomieBot) external onlyUpdateWallet {
        roomieBot = _roomieBot;
        emit RoomieBotUpdated(_roomieBot);
    }

    function setHinduTempleBeneficiary(address _newTemple) external onlyAdmin {
        hinduTempleBeneficiary = _newTemple;
        emit TempleBeneficiaryUpdated(_newTemple);
    }

    function verifyManufacturingPresence(address workerOrBot, bool status) external onlyRoomieBot {
        verifiedManufacturingSitePresence[workerOrBot] = status;
        emit RoomieBotSiteVerified(workerOrBot, status);
    }

    function createProposal(
        string memory description, 
        address payable recipient, 
        uint256 amount, 
        uint256 durationDays,
        bool isTempleAllocation
    ) external returns (uint256) {
        require(memberWeights[msg.sender] > 0, "Only weighted DAO members can propose");
        
        uint256 proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            description: description,
            recipient: recipient,
            amount: amount,
            isTempleAllocation: isTempleAllocation,
            yesVotes: 0,
            noVotes: 0,
            executed: false,
            deadline: block.timestamp + (durationDays * 1 days)
        });

        emit ProposalCreated(proposalId, description, recipient, amount, isTempleAllocation);
        return proposalId;
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp < proposal.deadline, "Voting period has ended");
        require(!proposal.executed, "Proposal already executed");
        require(!hasVoted[proposalId][msg.sender], "Already voted");
        
        uint256 weight = memberWeights[msg.sender];
        require(weight > 0, "No voting weight");

        hasVoted[proposalId][msg.sender] = true;
        if (support) {
            proposal.yesVotes += weight;
        } else {
            proposal.noVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    function executeProposal(uint256 proposalId) external fundsUnlocked {
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp >= proposal.deadline, "Voting still active");
        require(!proposal.executed, "Proposal already executed");
        require(proposal.yesVotes > proposal.noVotes, "Proposal failed majority vote");

        proposal.executed = true;
        bool success = arbitrumDAI.transfer(proposal.recipient, proposal.amount);
        require(success, "DAI transfer failed");

        emit ProposalExecuted(proposalId);
    }

    function revokeAndUpdatePermissions() external onlyUpdateWallet {
        isImmutable = true;
        updateWallet = address(0);
        emit PermissionsRevoked(msg.sender);
    }

    receive() external payable {}
}
SOL

echo "=== 3. Writing Test Suite (HempOffGridDAO.t.sol) ==="
cat << 'TEST' > test/HempOffGridDAO.t.sol
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

    function testHempSpecifications() public {
        assertEq(hempDAO.HEMP_SPECIFICATION(), "GMO hemp, all natural hemp color, no added colors");
        assertEq(hempDAO.hinduTempleBeneficiary(), hinduTemple);
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
TEST

echo "=== 4. Running Foundry Tests ==="
forge test -vv
