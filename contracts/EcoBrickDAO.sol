// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EcoBrickDAO
 * @notice Arbitrum One DAO governing off-grid eco-brick and recycled glass tile manufacturing.
 *         Operations run indefinitely until all waste on earth is recycled.
 *         Includes Roomie Bot manufacturing site presence verification and admin patent-linked selection.
 *         Locked until the OBS bonding curve reaches 5 billion DAI.
 */
interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract EcoBrickDAO {
    // --- Constants & Thresholds ---
    uint256 public constant THRESHOLD_DAI = 5_000_000_000 * 1e18; // 5 billion DAI
    address public immutable obsBondingCurve;
    IERC20 public immutable arbitrumDAI;

    // --- State Variables ---
    address public updateWallet;
    address public adminAddress;
    address public roomieBot;
    string public patentedEcoBrickModel;
    bool public isImmutable = false;

    struct Proposal {
        string description;
        address payable recipient;
        uint256 amount;
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

    // --- Events ---
    event PatentedEcoBrickUpdated(string newModel);
    event RoomieBotSiteVerified(address indexed workerOrBot, bool verified);
    event ProposalCreated(uint256 indexed proposalId, string description, address recipient, uint256 amount);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event PermissionsRevoked(address indexed updateWallet);

    // --- Modifiers ---
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
        address[] memory initialMembers,
        uint256[] memory weights
    ) {
        require(initialMembers.length == weights.length, "Mismatched member and weight lengths");
        obsBondingCurve = _obsBondingCurve;
        arbitrumDAI = IERC20(_arbitrumDAI);
        updateWallet = _updateWallet;
        adminAddress = _adminAddress;
        roomieBot = _roomieBot;
        patentedEcoBrickModel = "Pending Patent Issuance";

        for (uint256 i = 0; i < initialMembers.length; i++) {
            memberWeights[initialMembers[i]] = weights[i];
            totalVotingWeight += weights[i];
        }
    }

    // --- Admin & Patent Configuration ---
    function setPatentedEcoBrick(string memory _model) external onlyAdmin {
        patentedEcoBrickModel = _model;
        emit PatentedEcoBrickUpdated(_model);
    }

    function setRoomieBot(address _roomieBot) external onlyUpdateWallet {
        roomieBot = _roomieBot;
    }

    // Roomie Bot verifies physical presence at the off-grid manufacturing/recycling site
    function verifyManufacturingPresence(address workerOrBot, bool status) external onlyRoomieBot {
        verifiedManufacturingSitePresence[workerOrBot] = status;
        emit RoomieBotSiteVerified(workerOrBot, status);
    }

    // --- DAO Proposal & Voting Logic ---
    function createProposal(string memory description, address payable recipient, uint256 amount, uint256 durationDays) external returns (uint256) {
        require(memberWeights[msg.sender] > 0, "Only weighted DAO members can propose");
        
        uint256 proposalId = proposalCount++;
        proposals[proposalId] = Proposal({
            description: description,
            recipient: recipient,
            amount: amount,
            yesVotes: 0,
            noVotes: 0,
            executed: false,
            deadline: block.timestamp + (durationDays * 1 days)
        });

        emit ProposalCreated(proposalId, description, recipient, amount);
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

    // --- Execution & Off-Grid Recycling Facility Funding ---
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

    // --- Immutability & Access Control ---
    function revokeAndUpdatePermissions() external onlyUpdateWallet {
        isImmutable = true;
        updateWallet = address(0);
        emit PermissionsRevoked(msg.sender);
    }

    receive() external payable {}
}
