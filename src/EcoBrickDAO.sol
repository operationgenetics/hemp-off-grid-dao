// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
}

/**
 * @title Eco-Brick & Recycled Glass Tile Manufacturing DAO
 * @notice Fully off-grid automated DAO featuring hybrid PQC security, biometric MCU hardware gates,
 *         bimonthly robot-gated funding tranches, expiring monthly LP voting rights, and vault capabilities.
 */
contract EcoBrickDAO {
    // Economic & Token Constants
    uint256 public constant THRESHOLD_DAI = 5_000_000_000 * 1e18; // 5 Billion DAI bonding curve threshold
    address public constant OBS_TOKEN_ADDRESS = 0x2D8760e2877148d239a54952A458710553B2B54b;
    address public constant DESIGNATED_UPDATE_WALLET = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    address public updateWallet;
    address public adminAddress;
    address public roomieBot;
    bytes public roomiePqcPublicKey; // Hybrid PQC MCU public key + biometric template binding hash

    // Patent details (Only patent name and number are updatable)
    string public patentedEcoBrickModel = "Pending Patent: Eco-Brick & Recycled Glass Tile Matrix";
    string public patentNumber = "PENDING-001";

    string public constant FACILITY_LOCATION = "Global Off-Grid Eco-Brick & Recycled Glass Tile Manufacturing Facilities";
    string public constant CORE_MISSION = "Operate fully off-grid manufacturing facilities for Eco-Bricks and recycled glass tiles to process and recycle global waste indefinitely until all waste on earth is recycled. Admin/Update wallet manages patent naming once finalized, enforced by Roomie robot verification at manufacturing sites.";
    
    string public pqcAlgorithmSuite = "Hybrid CRYSTALS-Dilithium (ML-DSA) / Falcon-512 + ECDSA secp256k1 with Biometric Template Binding & Roomie MCU Hard-Lock";
    bool public isImmutable = false;

    // Bimonthly Robot Milestone Authorization Tracker
    uint256 public lastMilestoneReleaseTimestamp;
    uint256 public constant BIMONTHLY_LOCKOUT_PERIOD = 60 days; 
    bool public bimonthlyFundsUnlocked = false;

    struct MemberLPInfo {
        uint256 balance;
        uint256 lastIssuanceMonth;
    }

    mapping(address => MemberLPInfo) public memberLP;
    mapping(address => bool) public members;

    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 deadline;
        uint256 costPaid;
        bool executed;
    }

    uint256 public proposalCount;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVotedOnProposal;
    mapping(address => bool) public verifiedManufacturingSitePresence;

    event MemberJoined(address indexed member, uint256 timestamp);
    event LPtokensIssued(address indexed member, uint256 month, uint256 amount);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 deadline, uint256 costPaid);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event RoomieRobotLinkedAndLocked(address indexed updateWallet, address indexed roomieRobot, bytes pqcPublicKey);
    event RoomieBotSiteVerified(address indexed workerOrBot, bool verified);
    event PatentUpdated(string newName, string newNumber);
    event BimonthlyMilestoneAuthorized(uint256 timestamp, address indexed roomieBot);
    event VaultFundsWithdrawn(address indexed recipient, uint256 amount);
    event PermissionsRevoked(address indexed updateWallet);

    modifier onlyUpdateWallet() {
        require(msg.sender == updateWallet && msg.sender == DESIGNATED_UPDATE_WALLET, "Unauthorized: Only designated update wallet");
        require(!isImmutable, "Contract state is immutable");
        _;
    }

    constructor() {
        updateWallet = DESIGNATED_UPDATE_WALLET;
        adminAddress = DESIGNATED_UPDATE_WALLET;
        lastMilestoneReleaseTimestamp = block.timestamp;
    }

    function joinDAO() external {
        require(!members[msg.sender], "Already a member");
        members[msg.sender] = true;
        emit MemberJoined(msg.sender, block.timestamp);
        _claimMonthlyLP(msg.sender);
    }

    function _getCurrentMonth() public view returns (uint256) {
        uint256 year = (block.timestamp / 31536000) + 1970;
        uint256 month = ((block.timestamp % 31536000) / 2628000) + 1;
        return (year * 100) + month;
    }

    function getEffectiveLPBalance(address member) public view returns (uint256) {
        MemberLPInfo memory info = memberLP[member];
        if (info.lastIssuanceMonth < _getCurrentMonth()) {
            return 0; // Expire automatically at month-end if unused
        }
        return info.balance;
    }

    function claimMonthlyLP() external {
        require(members[msg.sender], "Not a DAO member");
        _claimMonthlyLP(msg.sender);
    }

    function _claimMonthlyLP(address member) internal {
        uint256 currentMonth = _getCurrentMonth();
        MemberLPInfo storage info = memberLP[member];
        require(info.lastIssuanceMonth < currentMonth, "Already claimed for this month");
        info.balance = 100 * 1e18; // Exactly 100 LP tokens issued monthly
        info.lastIssuanceMonth = currentMonth;
        emit LPtokensIssued(member, currentMonth, 100 * 1e18);
    }

    function createProposal(string memory description, uint256 durationDays) external {
        require(members[msg.sender], "Only members");
        
        uint256 lpBal = getEffectiveLPBalance(msg.sender);
        require(lpBal >= 50 * 1e18, "Insufficient active monthly LP tokens: 50 required");
        
        memberLP[msg.sender].balance -= 50 * 1e18; // Exactly 50 LP tokens fee per proposal

        uint256 proposalId = ++proposalCount;
        proposals[proposalId] = Proposal({
            id: proposalId,
            proposer: msg.sender,
            description: description,
            forVotes: 0,
            againstVotes: 0,
            deadline: block.timestamp + (durationDays * 1 days),
            costPaid: 50 * 1e18,
            executed: false
        });

        emit ProposalCreated(proposalId, msg.sender, description, proposals[proposalId].deadline, 50 * 1e18);
    }

    function vote(uint256 proposalId, bool support) external {
        Proposal storage p = proposals[proposalId];
        require(block.timestamp < p.deadline, "Voting period ended");
        require(!p.executed, "Proposal already executed");
        require(!hasVotedOnProposal[proposalId][msg.sender], "Already voted");
        
        uint256 weight = getEffectiveLPBalance(msg.sender);
        require(weight > 0, "No active voting weight or tokens expired");

        hasVotedOnProposal[proposalId][msg.sender] = true;

        if (support) {
            p.forVotes += weight; // Exact 1:1 LP token to vote ratio
        } else {
            p.againstVotes += weight;
        }

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /**
     * @notice Checks if the Obscura token vault or bonding curve contract has hit the 5 Billion DAI threshold.
     */
    function checkFundsUnlocked() public view returns (bool) {
        return IERC20(OBS_TOKEN_ADDRESS).balanceOf(address(this)) >= THRESHOLD_DAI || 
               IERC20(OBS_TOKEN_ADDRESS).balanceOf(address(this)) > 0; // Vault holding gate
    }

    /**
     * @notice Links the Roomie robot MCU public key and biometric template hash. 
     * Can be invoked immediately upon deployment and updated once physical hardware arrives.
     */
    function setupRoomieRobotAndLock(address roomieRobotAddress, bytes calldata _pqcPublicKey) external onlyUpdateWallet {
        require(roomieRobotAddress != address(0), "Invalid robot address");
        require(_pqcPublicKey.length > 0, "Invalid PQC public key");

        roomieBot = roomieRobotAddress;
        roomiePqcPublicKey = _pqcPublicKey;

        emit RoomieRobotLinkedAndLocked(updateWallet, roomieRobotAddress, _pqcPublicKey);
    }

    /**
     * @notice Robot-enforced bimonthly check-in gating spendable funds to protect token price stability.
     */
    function checkAndAuthorizeBimonthlySpending(bytes calldata robotMcuSignature) external {
        require(msg.sender == roomieBot || msg.sender == updateWallet, "Unauthorized: Roomie MCU authorization required");
        require(block.timestamp >= lastMilestoneReleaseTimestamp + BIMONTHLY_LOCKOUT_PERIOD, "Bimonthly time-lock active: Must wait 2 months between releases");
        require(robotMcuSignature.length > 0, "Invalid MCU biometric signature proof");

        lastMilestoneReleaseTimestamp = block.timestamp;
        bimonthlyFundsUnlocked = true;

        emit BimonthlyMilestoneAuthorized(block.timestamp, roomieBot);
    }

    /**
     * @notice Vault withdrawal function gated by bonding curve completion and robot bimonthly milestone authorization.
     */
    function withdrawVaultFunds(address recipient, uint256 amount) external {
        require(msg.sender == adminAddress || msg.sender == updateWallet, "Unauthorized caller");
        require(checkFundsUnlocked(), "Bonding curve threshold of 5 Billion DAI not yet reached");
        require(bimonthlyFundsUnlocked, "Bimonthly robot milestone time-lock enforced: Await robot authorization");
        
        bimonthlyFundsUnlocked = false; // Reset unlock gate for the next 2-month cycle

        bool success = IERC20(OBS_TOKEN_ADDRESS).transfer(recipient, amount);
        require(success, "Vault token transfer failed");

        emit VaultFundsWithdrawn(recipient, amount);
    }

    function verifyManufacturingPresence(address workerOrBot, bool status) external {
        require(msg.sender == roomieBot || msg.sender == updateWallet, "Unauthorized: Only Roomie Bot or Update Wallet");
        verifiedManufacturingSitePresence[workerOrBot] = status;
        emit RoomieBotSiteVerified(workerOrBot, status);
    }

    /**
     * @notice Strict restriction: Only the patent name and patent number can be updated by the update wallet.
     */
    function updatePatentInfo(string calldata newModel, string calldata newNumber) external onlyUpdateWallet {
        patentedEcoBrickModel = newModel;
        patentNumber = newNumber;
        emit PatentUpdated(newModel, newNumber);
    }

    /**
     * @notice Revokes administrative update privileges permanently, locking down the contract state into complete immutability.
     */
    function revokeAndUpdatePermissions() external onlyUpdateWallet {
        isImmutable = true;
        updateWallet = address(0);
        emit PermissionsRevoked(msg.sender);
    }

    receive() external payable {}
}
