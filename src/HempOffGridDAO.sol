// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

contract HempOffGridDAO {
    uint256 public constant THRESHOLD_DAI = 5_000_000_000 * 1e18;
    address public constant OBS_TOKEN_ADDRESS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    address public constant DESIGNATED_UPDATE_WALLET = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    IERC20 public immutable arbitrumDAI;
    address public updateWallet;
    address public adminAddress;
    address public roomieBot;
    
    string public constant HEMP_SPECIFICATION = "GMO hemp, all natural hemp color, no added colors";
    string public constant PRODUCT_SCOPE = "Clothing, hemp toilet paper and wipes";
    string public constant NONPROFIT_MISSION = "Strictly for free public giveaway and nonprofit use only";
    
    string public pqcAlgorithmSuite = "Hybrid Falcon-512 / Dilithium3 + ECDSA secp256k1";
    mapping(bytes32 => bool) public verifiedPQCAuthorizations;
    mapping(address => bytes32) public roomieBotQuantumKeyHashes;

    bool public isImmutable = false;

    struct MemberLPInfo {
        uint256 balance;
        uint256 lastIssuanceMonth;
    }

    mapping(address => MemberLPInfo) public memberLP;
    
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
    mapping(address => bool) public verifiedManufacturingSitePresence;
    uint256 public proposalCount;

    event RoomieBotUpdated(address indexed newRoomieBot);
    event RoomieBotSiteVerified(address indexed workerOrBot, bool verified);
    event PQCSuiteUpdated(string newSuite);
    event QuantumKeyRegistered(address indexed botOrNode, bytes32 keyHash);
    event ProposalCreated(uint256 indexed proposalId, string description, address recipient, uint256 amount);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalExecuted(uint256 indexed proposalId);
    event PermissionsRevoked(address indexed updateWallet);
    event MonthlyLPIssued(address indexed member, uint256 amount, uint256 monthIdentifier);

    modifier onlyUpdateWallet() {
        require(msg.sender == updateWallet && msg.sender == DESIGNATED_UPDATE_WALLET, "Unauthorized: Only designated update wallet");
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
        require(arbitrumDAI.balanceOf(OBS_TOKEN_ADDRESS) >= THRESHOLD_DAI, "Treasury locked: 5B DAI bonding curve threshold not met");
        _;
    }

    constructor(
        address _arbitrumDAI,
        address _adminAddress,
        address _roomieBot
    ) {
        arbitrumDAI = IERC20(_arbitrumDAI);
        updateWallet = DESIGNATED_UPDATE_WALLET;
        adminAddress = _adminAddress;
        roomieBot = _roomieBot;
    }

    function getCurrentMonthIdentifier() public view returns (uint256) {
        uint256 year = (block.timestamp / 31536000) + 1970;
        uint256 month = ((block.timestamp % 31536000) / 2628000) + 1;
        return (year * 100) + month;
    }

    function getEffectiveLPBalance(address member) public view returns (uint256) {
        MemberLPInfo memory info = memberLP[member];
        if (info.lastIssuanceMonth < getCurrentMonthIdentifier()) {
            return 0; 
        }
        return info.balance;
    }

    function claimMonthlyLP() external {
        uint256 currentMonth = getCurrentMonthIdentifier();
        MemberLPInfo storage info = memberLP[msg.sender];
        require(info.lastIssuanceMonth < currentMonth, "Monthly LP already claimed or active");
        info.balance = 100 * 1e18; 
        info.lastIssuanceMonth = currentMonth;
        emit MonthlyLPIssued(msg.sender, 100 * 1e18, currentMonth);
    }

    function createProposal(
        string memory description, 
        address payable recipient, 
        uint256 amount, 
        uint256 durationDays
    ) external returns (uint256) {
        uint256 lpBal = getEffectiveLPBalance(msg.sender);
        require(lpBal >= 50 * 1e18, "Insufficient active LP tokens: 50 LP required for proposal");
        
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
        
        uint256 weight = getEffectiveLPBalance(msg.sender);
        require(weight > 0, "No active voting weight or tokens expired");

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

    function registerRoomieBotQuantumKey(address botOrNode, bytes32 pqcKeyHash) external onlyUpdateWallet {
        roomieBotQuantumKeyHashes[botOrNode] = pqcKeyHash;
        emit QuantumKeyRegistered(botOrNode, pqcKeyHash);
    }

    function verifyManufacturingPresenceWithPQC(
        address workerOrBot, 
        bool status, 
        bytes32 pqcSignatureHash
    ) external onlyRoomieBot {
        require(roomieBotQuantumKeyHashes[msg.sender] != bytes32(0), "Roomie bot PQC key not registered");
        verifiedPQCAuthorizations[pqcSignatureHash] = true;
        verifiedManufacturingSitePresence[workerOrBot] = status;
        emit RoomieBotSiteVerified(workerOrBot, status);
    }

    function setRoomieBotDirect(address _roomieBot) external onlyUpdateWallet {
        roomieBot = _roomieBot;
        emit RoomieBotUpdated(_roomieBot);
    }

    function revokeAndUpdatePermissions() external onlyUpdateWallet {
        isImmutable = true;
        updateWallet = address(0);
        emit PermissionsRevoked(msg.sender);
    }

    receive() external payable {}
}
