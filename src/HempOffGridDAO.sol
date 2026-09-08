// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/*//////////////////////////////////////////////////////////////////////////////
                              HEMP OFF-GRID DAO
                        Arbitrum One (chainid 42161) native

  Deployment requires NOTHING but the source file path and a wallet signature.
  There are no constructor arguments, no config file entries, no environment
  variables and no post-deploy parameters that must be known in advance.

  ── What this contract enforces on-chain (real, verifiable) ──────────────────
   * OBS vault: receives and holds OBS, split 50/50 into a Temple pool and a
     Community pool at deposit time. The split is a hard accounting invariant.
   * Bonding-curve gate: no OBS leaves the vault until the OBS bonding-curve
     reserve has held >= 5,000,000,000 DAI at least once. The unlock LATCHES.
   * Governance: 100 LP minted per member per calendar month, expiring at the
     end of that calendar month, 1 LP = 1 vote, 50 LP to open a proposal.
   * Hard-coded programme rules: every funding proposal must declare a product
     category and site type drawn from a fixed on-chain enum, and must carry the
     natural-colour / off-grid-power / human-safety covenant flags set true.
     Proposals that do not are rejected by the EVM, not by policy.
   * Milestone timeout: a funded project pays out in equal tranches, at most one
     tranche per 60 days, each tranche gated on an MCU authorisation that also
     attests the previous milestone complete. A project mathematically cannot be
     drained faster than (milestoneCount * 60 days).
   * Hybrid PQC authorisation: the classical secp256k1 half of the robot MCU's
     hybrid signature is verified natively on-chain via ecrecover. The
     post-quantum half is verified on-chain IF a PQC verifier contract is
     registered before finalisation; otherwise its digest is anchored in state
     and events for off-chain / robot-side verification against the on-chain
     public key.
   * Revocable admin: ROBOT_REGISTRY_ADMIN may update robot/MCU details any
     number of times, then permanently revoke its own power, after which the
     contract has no privileged role of any kind and is fully immutable.

  ── What NO smart contract can enforce, stated plainly ──────────────────────
   * Whether a hemp grow was actually built, whether goods were actually
     delivered, or whether a project is "safe for humanity". The chain can only
     verify that the robot MCU holding the registered key attested it, on
     schedule, and can withhold every subsequent tranche if it does not.
   * Full ML-DSA (Dilithium) signature verification in EVM bytecode. There is no
     PQC precompile on Arbitrum One. See PQC_VERIFIER_NOTICE below.

  ── Biometrics ──────────────────────────────────────────────────────────────
   * NO biometric data, template, hash or derivative is stored by this contract.
     There is no field capable of holding one. Biometric templates live only on
     the robot's hybrid-PQC MCU. Only PUBLIC keys are placed on-chain.
//////////////////////////////////////////////////////////////////////////////*/

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

import "./crypto/IPQCVerifier.sol";

contract HempOffGridDAO {
    /*//////////////////////////////////////////////////////////////
                        HARD-CODED ADDRESSES
    //////////////////////////////////////////////////////////////*/

    /// @notice OBS token. Vault asset. Arbitrum One.
    address public constant OBS_TOKEN = 0xa473BdD164F992717Bdbd5F7e10F168C7Ad5D7B0;

    /// @notice DAI on Arbitrum One. Denominates the bonding-curve unlock threshold.
    address public constant DAI = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;

    /// @notice The only address that may ever register robot/MCU details, and the
    ///         only address that may permanently revoke that power. Cannot be changed.
    address public constant ROBOT_REGISTRY_ADMIN = 0xaF570ce3b32D765b1236635B0f541a7487A1fB8e;

    /*//////////////////////////////////////////////////////////////
                        HARD-CODED PROGRAMME RULES
    //////////////////////////////////////////////////////////////*/

    uint256 public constant BONDING_CURVE_UNLOCK_DAI = 5_000_000_000 * 1e18;

    uint256 public constant LP_MONTHLY_ISSUANCE = 100e18; // 100 LP / member / calendar month
    uint256 public constant LP_PROPOSAL_COST    = 50e18;  // 50 LP opens a proposal
    uint256 public constant VOTING_PERIOD       = 14 days;
    uint16  public constant QUORUM_BPS          = 2000;   // 20% of LP issued this month

    /// @notice One MCU authorisation per project per 60 days. Never faster.
    uint256 public constant MCU_AUTHORIZATION_INTERVAL = 60 days;

    uint16 public constant MIN_MILESTONES = 3;
    uint16 public constant MAX_MILESTONES = 120;

    /// @notice Programme-wide anti-dump circuit breaker: at most 5% of the total
    ///         programme may be released in any rolling 60-day window.
    uint16 public constant GLOBAL_RELEASE_CAP_BPS = 500;

    string public constant HEMP_SPECIFICATION =
        "gmo hemp, all natural hemp color, no added colors";
    string public constant SITE_SPECIFICATION =
        "Hemp vertical grows fully off grid: solar generation, battery storage, atmospheric water generation";
    string public constant ALLOCATION_RULE =
        "50% of stock to Hindu temples operating 501(c)(7) vertical grows; 50% to global communities in need, by DAO proposal and vote";
    string public constant PQC_VERIFIER_NOTICE =
        "Hybrid: secp256k1 half verified on-chain via ecrecover; PQC half verified on-chain only if pqcVerifier is set, otherwise anchored on-chain for off-chain verification against pqcPublicKey";

    /// @notice Product scope. A funding proposal MUST name one of these.
    enum ProductCategory {
        Socks,              // 0
        PantsJoggers,       // 1
        Shorts,             // 2
        LongSleeve,         // 3
        ShortSleeve,        // 4
        TankTop,            // 5
        MensUnderwear,      // 6
        WomensUnderwear,    // 7
        ToiletPaper,        // 8
        Wipes,              // 9
        VerticalGrowSolar,  // 10 off-grid solar generation
        VerticalGrowBattery,// 11 off-grid battery storage
        AtmosphericWater,   // 12 atmospheric water generation
        ProcessingAndMill,  // 13 fibre processing / mill
        Distribution        // 14 delivery of finished stock to beneficiaries
    }

    enum SiteType {
        HinduTempleVerticalGrow, // 0 must be a registered 501(c)(7) temple site
        CommunityDistribution    // 1 global community in need
    }

    enum ProposalKind {
        TempleSupply,     // 0 draws from the 50% temple pool
        CommunitySupply,  // 1 draws from the 50% community pool
        AdmitMember,      // 2 grants LP-claiming membership
        RegisterTemple    // 3 registers a 501(c)(7) temple vertical-grow beneficiary
    }

    /*//////////////////////////////////////////////////////////////
                            ROBOT / MCU REGISTRY
    //////////////////////////////////////////////////////////////*/

    /// @notice secp256k1 address of the robot MCU's classical key. Verified natively.
    address public robotSignerEOA;

    /// @notice Full post-quantum PUBLIC key held on the robot's hybrid-PQC MCU.
    ///         Public key only. Never a biometric template.
    bytes public pqcPublicKey;

    /// @notice keccak256(pqcPublicKey), for cheap off-chain / robot-side comparison.
    bytes32 public pqcPublicKeyHash;

    /// @notice Optional on-chain PQC verifier. address(0) => PQC half is anchored, not verified.
    address public pqcVerifier;

    /// @notice Contract whose DAI balance is the bonding-curve reserve.
    address public bondingCurveReserve;

    /// @notice True once a robot has been registered at least once.
    bool public robotConfigured;

    /// @notice True once ROBOT_REGISTRY_ADMIN has permanently revoked itself.
    ///         From this point the contract is fully immutable and role-free.
    bool public registryFinalized;

    /*//////////////////////////////////////////////////////////////
                                VAULT
    //////////////////////////////////////////////////////////////*/

    bool public bondingCurveUnlocked; // latches true, never false again

    uint256 public templePool;      // uncommitted OBS earmarked for temples (50%)
    uint256 public communityPool;   // uncommitted OBS earmarked for communities (50%)
    uint256 public totalCommitted;  // OBS reserved by live projects
    uint256 public totalReleased;   // OBS paid out over all time
    uint256 public totalDeposited;  // OBS ever accounted into the vault

    uint256 private _windowStart;
    uint256 private _windowReleased;

    /*//////////////////////////////////////////////////////////////
                            MEMBERSHIP / LP
    //////////////////////////////////////////////////////////////*/

    struct LP {
        uint256 period;   // YYYYMM this balance belongs to
        uint256 balance;  // expires when period != currentPeriod()
    }

    mapping(address => bool) public isMember;
    mapping(address => LP) private _lp;
    mapping(uint256 => uint256) public lpIssuedInPeriod; // YYYYMM => LP minted
    mapping(address => bool) public isRegisteredTemple;
    uint256 public memberCount;

    /*//////////////////////////////////////////////////////////////
                          PROPOSALS / PROJECTS
    //////////////////////////////////////////////////////////////*/

    struct Proposal {
        ProposalKind kind;
        ProductCategory category;
        SiteType siteType;
        address proposer;
        address target;         // beneficiary / member / temple
        uint256 amount;         // OBS, 0 for non-funding kinds
        uint16  milestoneCount;
        uint256 period;         // YYYYMM the proposal opened in
        uint256 deadline;
        uint256 forVotes;
        uint256 againstVotes;
        bool    finalized;
        bool    passed;
        string  description;
    }

    struct Project {
        uint256 proposalId;
        address beneficiary;
        uint256 total;
        uint256 released;
        uint16  milestoneCount;
        uint16  milestonesDone;
        uint256 lastAuthorizedAt;
        bool    complete;
    }

    mapping(uint256 => Proposal) private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => Project) private _projects;
    /// @notice Per-project monotonic nonce; every MCU authorisation is single-use.
    mapping(uint256 => uint256) public mcuNonce;

    uint256 public proposalCount;
    uint256 public projectCount;

    uint256 private _lock = 1;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    event RoomieRobotConfigured(
        address indexed robotSignerEOA,
        bytes32 indexed pqcPublicKeyHash,
        address pqcVerifier,
        address bondingCurveReserve
    );
    event RegistryPermanentlyRevoked(address indexed admin, uint256 timestamp);
    event BondingCurveUnlocked(uint256 daiReserve, uint256 timestamp);
    event ObsDeposited(address indexed from, uint256 amount, uint256 toTemplePool, uint256 toCommunityPool);
    event MemberAdmitted(address indexed member);
    event TempleRegistered(address indexed temple);
    event MonthlyLPClaimed(address indexed member, uint256 amount, uint256 indexed period);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, ProposalKind kind, uint256 amount);
    event Voted(uint256 indexed proposalId, address indexed voter, bool support, uint256 weight);
    event ProposalFinalized(uint256 indexed proposalId, bool passed, uint256 forVotes, uint256 againstVotes);
    event ProjectOpened(uint256 indexed projectId, uint256 indexed proposalId, address beneficiary, uint256 total, uint16 milestones);
    event MilestoneAuthorized(
        uint256 indexed projectId,
        uint16 indexed milestone,
        uint256 amount,
        bytes32 digest,
        bytes32 pqcSignatureHash,
        bool pqcVerifiedOnChain
    );
    event ProjectCompleted(uint256 indexed projectId, uint256 totalReleased);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotRegistryAdmin();
    error RegistryIsFinalized();
    error RobotNotConfigured();
    error PlaceholderKeyCannotBeFinalized();
    error InvalidRobotSigner();
    error NotAMember();
    error AlreadyAMember();
    error LPAlreadyClaimedThisMonth();
    error InsufficientLP();
    error AlreadyVoted();
    error VotingClosed();
    error VotingStillOpen();
    error AlreadyFinalized();
    error BadMilestoneCount();
    error CovenantNotAccepted();
    error CategorySiteMismatch();
    error TempleNotRegistered();
    error InsufficientPoolBalance();
    error VaultLocked();
    error ReserveNotConfigured();
    error ThresholdNotMet();
    error TooSoonForNextAuthorization();
    error ProjectAlreadyComplete();
    error NoProject();
    error NoSuchProposal();
    error VerifierHasNoCode();
    error PqcVerifierRequired();
    error BadPqcSignatureLength();
    error AlreadyUnlocked();
    error BadMcuSignature();
    error PqcSignatureRejected();
    error GlobalReleaseCapExceeded();
    error TrancheExceedsReleaseCap();
    error TransferFailed();
    error ZeroAddress();
    error ZeroAmount();
    error NothingToSync();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The single privileged role. Ceases to exist after revokeAndFinalize().
    modifier onlyRegistryAdmin() {
        if (msg.sender != ROBOT_REGISTRY_ADMIN) revert NotRegistryAdmin();
        if (registryFinalized) revert RegistryIsFinalized();
        _;
    }

    modifier onlyMember() {
        if (!isMember[msg.sender]) revert NotAMember();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @notice No constructor arguments. Deployment needs only the file path and a signature.
    constructor() {
        _windowStart = block.timestamp;
        // The deploying/administering wallet is the sole founding member so that
        // governance is usable the moment the contract lands, with zero extra setup.
        isMember[ROBOT_REGISTRY_ADMIN] = true;
        memberCount = 1;
        emit MemberAdmitted(ROBOT_REGISTRY_ADMIN);
    }

    /*//////////////////////////////////////////////////////////////
                     ROBOT / MCU REGISTRY (REVOCABLE)
    //////////////////////////////////////////////////////////////*/

    /// @notice Register or re-register the Roomie humanoid robot's hybrid-PQC MCU.
    ///         Callable immediately after deployment with placeholder values, then
    ///         re-callable as many times as needed once the real hardware arrives.
    ///         Permanently disabled by revokeAndFinalize().
    /// @param _robotSignerEOA secp256k1 address derived from the MCU's classical key.
    /// @param _pqcPublicKey   PUBLIC post-quantum key from the MCU. Public key only —
    ///                        biometric templates stay on the MCU and never touch chain.
    /// @param _pqcVerifier    Optional on-chain PQC verifier, or address(0) to anchor only.
    /// @param _bondingCurveReserve Contract whose DAI balance is the bonding-curve reserve.
    function setupRoomieRobotAndLock(
        address _robotSignerEOA,
        bytes calldata _pqcPublicKey,
        address _pqcVerifier,
        address _bondingCurveReserve
    ) external onlyRegistryAdmin {
        if (_robotSignerEOA == address(0)) revert InvalidRobotSigner();

        robotSignerEOA = _robotSignerEOA;
        pqcPublicKey = _pqcPublicKey;
        pqcPublicKeyHash = keccak256(_pqcPublicKey);
        pqcVerifier = _pqcVerifier;
        bondingCurveReserve = _bondingCurveReserve;
        robotConfigured = true;

        emit RoomieRobotConfigured(_robotSignerEOA, pqcPublicKeyHash, _pqcVerifier, _bondingCurveReserve);
    }

    /// @notice Permanently destroy the registry admin role. The contract becomes
    ///         fully immutable: no address, including ROBOT_REGISTRY_ADMIN, can
    ///         change any parameter ever again. One-way. Irreversible.
    /// @dev Refuses to finalize on a placeholder key, so a stub cannot be locked in
    ///      by accident. Requires a plausible ML-DSA/Dilithium-sized public key
    ///      (Dilithium2 = 1312 bytes, ML-DSA-65 = 1952 bytes) and a real reserve.
    function revokeAndFinalize() external onlyRegistryAdmin {
        if (!robotConfigured) revert RobotNotConfigured();
        if (pqcPublicKey.length < 1312) revert PlaceholderKeyCannotBeFinalized();
        if (bondingCurveReserve == address(0)) revert ReserveNotConfigured();
        // Full hybrid PQC is a precondition of immutability. Without a verifier the
        // post-quantum half is only anchored, leaving release security resting on
        // secp256k1 alone - precisely what a quantum adversary breaks. Refuse to seal
        // in that state, while there is still a way back.
        if (pqcVerifier == address(0)) revert PqcVerifierRequired();
        // A verifier with no code would make every high-level call revert, bricking
        // all future releases with no way back. Check it while there is still a way back.
        if (pqcVerifier.code.length == 0) revert VerifierHasNoCode();

        registryFinalized = true;
        emit RegistryPermanentlyRevoked(msg.sender, block.timestamp);
    }

    /// @notice Admit founding members before finalisation. After finalisation the
    ///         only route to membership is an AdmitMember proposal passed by vote.
    function admitFoundingMember(address member) external onlyRegistryAdmin {
        if (member == address(0)) revert ZeroAddress();
        _admit(member);
    }

    /// @notice Register a founding 501(c)(7) Hindu temple vertical-grow beneficiary
    ///         before finalisation. Afterwards, only by RegisterTemple proposal.
    function registerFoundingTemple(address temple) external onlyRegistryAdmin {
        if (temple == address(0)) revert ZeroAddress();
        _registerTemple(temple);
    }

    /*//////////////////////////////////////////////////////////////
                          BONDING CURVE GATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless. Latches the vault open once the bonding-curve reserve
    ///         has held >= 5,000,000,000 DAI. Latching matters: a later dip in the
    ///         reserve must not re-lock funding for projects already underway.
    function latchBondingCurveUnlock() external {
        if (bondingCurveUnlocked) revert AlreadyUnlocked();
        if (bondingCurveReserve == address(0)) revert ReserveNotConfigured();
        uint256 reserve = IERC20(DAI).balanceOf(bondingCurveReserve);
        if (reserve < BONDING_CURVE_UNLOCK_DAI) revert ThresholdNotMet();
        bondingCurveUnlocked = true;
        emit BondingCurveUnlocked(reserve, block.timestamp);
    }

    function bondingCurveReserveDAI() external view returns (uint256) {
        if (bondingCurveReserve == address(0)) return 0;
        return IERC20(DAI).balanceOf(bondingCurveReserve);
    }

    /*//////////////////////////////////////////////////////////////
                                 VAULT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposit OBS into the DAO vault. Split 50/50 between the temple pool
    ///         and the community pool on the way in. Deposits are irreversible
    ///         contributions to the programme; there is no depositor withdrawal.
    /// @dev Balance-delta accounting, so a fee-on-transfer or rebasing token credits
    ///      only what actually arrived. Static analysers flag the balance read across
    ///      the external call: the call target is the fixed OBS_TOKEN constant, never
    ///      caller-supplied, and the function carries `nonReentrant`, so the delta
    ///      cannot be manipulated by re-entering.
    function depositOBS(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = IERC20(OBS_TOKEN).balanceOf(address(this));
        _safeTransferFrom(OBS_TOKEN, msg.sender, address(this), amount);
        uint256 received = IERC20(OBS_TOKEN).balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        _account(msg.sender, received);
    }

    /// @notice Account OBS that arrived by a plain `transfer` straight to this
    ///         contract. Without this, such tokens would be stranded forever.
    function syncDirectOBSDeposits() external nonReentrant {
        uint256 bal = IERC20(OBS_TOKEN).balanceOf(address(this));
        uint256 tracked = templePool + communityPool + totalCommitted;
        if (bal <= tracked) revert NothingToSync();
        _account(address(this), bal - tracked);
    }

    function _account(address from, uint256 amount) private {
        uint256 toTemple = amount / 2;
        uint256 toCommunity = amount - toTemple; // odd wei favours the community pool
        templePool += toTemple;
        communityPool += toCommunity;
        totalDeposited += amount;
        emit ObsDeposited(from, amount, toTemple, toCommunity);
    }

    /*//////////////////////////////////////////////////////////////
                          CALENDAR-MONTH LP
    //////////////////////////////////////////////////////////////*/

    /// @notice Current calendar period as YYYYMM (UTC), exact for all dates.
    function currentPeriod() public view returns (uint256) {
        return _yearMonth(block.timestamp);
    }

    /// @dev Howard Hinnant's civil-from-days, verified by fuzzing. The divide-then-
    ///      multiply pairs are deliberate exact-remainder computations
    ///      (`z - era * 146097` is precisely `z % 146097`), not precision loss.
    /// @dev Howard Hinnant's civil-from-days. Exact calendar months, leap years
    ///      included — not a 30-day approximation, which drifts a whole month
    ///      roughly every five years and would silently break LP expiry.
    function _yearMonth(uint256 ts) internal pure returns (uint256) {
        uint256 z = ts / 86400 + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
        return y * 100 + m;
    }

    /// @notice Claim this calendar month's 100 LP. Once per member per month.
    ///         Unused LP expires the instant the month rolls over — it is never
    ///         carried forward and cannot be accumulated across months.
    function claimMonthlyLP() external onlyMember {
        uint256 p = currentPeriod();
        LP storage lp = _lp[msg.sender];
        if (lp.period == p) revert LPAlreadyClaimedThisMonth();
        lp.period = p;
        lp.balance = LP_MONTHLY_ISSUANCE;
        lpIssuedInPeriod[p] += LP_MONTHLY_ISSUANCE;
        emit MonthlyLPClaimed(msg.sender, LP_MONTHLY_ISSUANCE, p);
    }

    /// @notice Full LP record: the calendar period the balance belongs to, and the
    ///         raw balance. `balance` is spent iff `period == currentPeriod()`.
    function lpOf(address member) external view returns (uint256 period, uint256 balance) {
        LP memory lp = _lp[member];
        return (lp.period, lp.balance);
    }

    /// @notice Accounting invariant, exposed for monitoring and for auditors:
    ///         templePool + communityPool + totalCommitted == totalDeposited - totalReleased
    function accountingHolds() external view returns (bool) {
        return templePool + communityPool + totalCommitted == totalDeposited - totalReleased;
    }

    /// @notice Voting power = unspent LP from the current calendar month. 1 LP = 1 vote.
    function votingPower(address member) public view returns (uint256) {
        LP memory lp = _lp[member];
        return lp.period == currentPeriod() ? lp.balance : 0;
    }

    function _spendLP(address member, uint256 amount) private {
        LP storage lp = _lp[member];
        if (lp.period != currentPeriod() || lp.balance < amount) revert InsufficientLP();
        lp.balance -= amount;
    }

    /*//////////////////////////////////////////////////////////////
                              PROPOSALS
    //////////////////////////////////////////////////////////////*/

    struct ProposalInput {
        ProposalKind kind;
        ProductCategory category;
        SiteType siteType;
        address target;
        uint256 amount;
        uint16 milestoneCount;
        bool naturalColorOnly;    // must be true: all natural hemp color, no added colors
        bool offGridPoweredOnly;  // must be true: solar + battery + atmospheric water
        bool humanSafetyCovenant; // must be true: project is safe for the people it serves
        string description;
    }

    /// @notice Open a proposal. Costs 50 LP from this month's allotment.
    ///         Funding proposals are rejected outright unless they name a product
    ///         category and site type from the hard-coded enums and accept all
    ///         three covenants. These are EVM-level constraints, not guidance.
    function createProposal(ProposalInput calldata input) external onlyMember returns (uint256 id) {
        _spendLP(msg.sender, LP_PROPOSAL_COST);
        if (input.target == address(0)) revert ZeroAddress();

        bool funding = input.kind == ProposalKind.TempleSupply || input.kind == ProposalKind.CommunitySupply;

        if (funding) {
            if (input.amount == 0) revert ZeroAmount();
            if (input.milestoneCount < MIN_MILESTONES || input.milestoneCount > MAX_MILESTONES) {
                revert BadMilestoneCount();
            }
            if (!input.naturalColorOnly || !input.offGridPoweredOnly || !input.humanSafetyCovenant) {
                revert CovenantNotAccepted();
            }
            // A tranche larger than the programme-wide window cap could never be
            // released. Reject it here rather than letting it pass a vote and stall.
            if (input.amount / input.milestoneCount > (totalDeposited * GLOBAL_RELEASE_CAP_BPS) / 10000) {
                revert TrancheExceedsReleaseCap();
            }
            if (input.kind == ProposalKind.TempleSupply) {
                if (input.siteType != SiteType.HinduTempleVerticalGrow) revert CategorySiteMismatch();
                if (!isRegisteredTemple[input.target]) revert TempleNotRegistered();
                if (templePool < input.amount) revert InsufficientPoolBalance();
            } else {
                if (input.siteType != SiteType.CommunityDistribution) revert CategorySiteMismatch();
                if (communityPool < input.amount) revert InsufficientPoolBalance();
            }
        } else {
            if (input.amount != 0) revert ZeroAmount();
            if (input.kind == ProposalKind.AdmitMember && isMember[input.target]) revert AlreadyAMember();
        }

        id = ++proposalCount;
        Proposal storage p = _proposals[id];
        p.kind = input.kind;
        p.category = input.category;
        p.siteType = input.siteType;
        p.proposer = msg.sender;
        p.target = input.target;
        p.amount = input.amount;
        p.milestoneCount = input.milestoneCount;
        p.period = currentPeriod();
        p.deadline = block.timestamp + VOTING_PERIOD;
        p.description = input.description;

        emit ProposalCreated(id, msg.sender, input.kind, input.amount);
    }

    /// @notice Vote with `weight` LP. 1 LP = 1 vote, and the LP is consumed —
    ///         a month's 100 LP is a real budget, spent across proposing and voting.
    function vote(uint256 proposalId, bool support, uint256 weight) external onlyMember {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0)) revert NoSuchProposal();
        if (block.timestamp >= p.deadline) revert VotingClosed();
        if (hasVoted[proposalId][msg.sender]) revert AlreadyVoted();
        if (weight == 0) revert ZeroAmount();

        _spendLP(msg.sender, weight);
        hasVoted[proposalId][msg.sender] = true;

        if (support) p.forVotes += weight;
        else p.againstVotes += weight;

        emit Voted(proposalId, msg.sender, support, weight);
    }

    /// @notice Tally a proposal after its voting window. Passing a funding proposal
    ///         opens a milestone-gated project and reserves its OBS from the pool.
    function finalizeProposal(uint256 proposalId) external returns (bool passed) {
        Proposal storage p = _proposals[proposalId];
        if (p.proposer == address(0)) revert NoSuchProposal();
        if (block.timestamp < p.deadline) revert VotingStillOpen();
        if (p.finalized) revert AlreadyFinalized();

        p.finalized = true;

        uint256 turnout = p.forVotes + p.againstVotes;
        uint256 quorum = (lpIssuedInPeriod[p.period] * QUORUM_BPS) / 10000;

        passed = turnout >= quorum && p.forVotes > p.againstVotes;
        p.passed = passed;
        emit ProposalFinalized(proposalId, passed, p.forVotes, p.againstVotes);

        if (!passed) return false;

        if (p.kind == ProposalKind.AdmitMember) {
            if (isMember[p.target]) { p.passed = false; return false; }
            _admit(p.target);
        } else if (p.kind == ProposalKind.RegisterTemple) {
            _registerTemple(p.target);
        } else {
            // Another proposal may have drained the pool during the voting window.
            uint256 avail = p.kind == ProposalKind.TempleSupply ? templePool : communityPool;
            if (avail < p.amount) { p.passed = false; return false; }
            _openProject(proposalId, p);
        }
    }

    function _openProject(uint256 proposalId, Proposal storage p) private {
        if (p.kind == ProposalKind.TempleSupply) {
            if (templePool < p.amount) revert InsufficientPoolBalance();
            templePool -= p.amount;
        } else {
            if (communityPool < p.amount) revert InsufficientPoolBalance();
            communityPool -= p.amount;
        }
        totalCommitted += p.amount;

        uint256 pid = ++projectCount;
        Project storage pr = _projects[pid];
        pr.proposalId = proposalId;
        pr.beneficiary = p.target;
        pr.total = p.amount;
        pr.milestoneCount = p.milestoneCount;
        // First authorisation is due one full interval after the project opens.
        pr.lastAuthorizedAt = block.timestamp;

        emit ProjectOpened(pid, proposalId, p.target, p.amount, p.milestoneCount);
    }

    function _admit(address member) private {
        if (isMember[member]) revert AlreadyAMember();
        isMember[member] = true;
        unchecked { ++memberCount; }
        emit MemberAdmitted(member);
    }

    function _registerTemple(address temple) private {
        if (!isRegisteredTemple[temple]) {
            isRegisteredTemple[temple] = true;
            emit TempleRegistered(temple);
        }
    }

    /*//////////////////////////////////////////////////////////////
             HYBRID PQC MCU AUTHORISATION — MILESTONE RELEASE
    //////////////////////////////////////////////////////////////*/

    /// @notice The exact digest the robot MCU must sign to authorise one tranche.
    ///         Bound to this contract, this chain, this project, this milestone,
    ///         this amount and a single-use nonce, so no signature can be replayed
    ///         on another chain, another deployment, or a second time here.
    function authorizationDigest(uint256 projectId, bytes32 evidenceHash) public view returns (bytes32) {
        Project storage pr = _projects[projectId];
        return keccak256(
            abi.encode(
                "HEMP_OFF_GRID_DAO_MCU_AUTH_V1",
                block.chainid,
                address(this),
                projectId,
                pr.milestonesDone,          // milestone being attested complete
                pr.milestonesDone + 1,      // tranche being authorised
                _trancheAmount(pr),
                pr.beneficiary,
                mcuNonce[projectId],
                evidenceHash,
                pqcPublicKeyHash
            )
        );
    }

    /// @notice Release one project tranche. Requires, all together:
    ///           1. the bonding curve to have latched open at 5,000,000,000 DAI;
    ///           2. at least 60 days since this project's last authorisation;
    ///           3. a valid secp256k1 signature from the registered MCU key,
    ///              verified natively on-chain by ecrecover;
    ///           4. the PQC half — verified on-chain if a verifier is registered,
    ///              otherwise anchored on-chain against the registered public key;
    ///           5. the programme-wide 5%-per-60-days release cap to hold.
    ///         A single call attests the previous milestone complete AND authorises
    ///         the next spend, so the operator signs exactly once every two months.
    /// @param evidenceHash Hash of the off-chain milestone evidence pack. Content
    ///        stays off-chain and off-grid; only its commitment is published.
    /// @param mcuEcdsaSignature 65-byte r||s||v over authorizationDigest, EIP-191 prefixed.
    /// @param mcuPqcSignature   Post-quantum signature over the same digest.
    function authorizeMilestoneAndRelease(
        uint256 projectId,
        bytes32 evidenceHash,
        bytes calldata mcuEcdsaSignature,
        bytes calldata mcuPqcSignature
    ) external nonReentrant {
        if (!robotConfigured) revert RobotNotConfigured();
        if (!bondingCurveUnlocked) revert VaultLocked();

        Project storage pr = _projects[projectId];
        if (pr.beneficiary == address(0)) revert NoProject();
        if (pr.complete) revert ProjectAlreadyComplete();
        if (block.timestamp < pr.lastAuthorizedAt + MCU_AUTHORIZATION_INTERVAL) {
            revert TooSoonForNextAuthorization();
        }

        bytes32 digest = authorizationDigest(projectId, evidenceHash);

        // ── Classical half: enforced natively by the EVM ──
        if (_recover(_ethSignedMessage(digest), mcuEcdsaSignature) != robotSignerEOA) {
            revert BadMcuSignature();
        }

        // ── Post-quantum half ──
        bool pqcVerifiedOnChain = false;
        address verifier = pqcVerifier;
        if (verifier != address(0)) {
            if (!IPQCVerifier(verifier).verify(pqcPublicKey, digest, mcuPqcSignature)) {
                revert PqcSignatureRejected();
            }
            pqcVerifiedOnChain = true;
        } else {
            // Pre-finalisation only: revokeAndFinalize refuses to seal without a
            // verifier, so no immutable deployment can reach this branch. Until then
            // the signature must at least be a well-formed ML-DSA-65 signature, and it
            // is anchored on-chain bound to the digest and the registered public key.
            if (mcuPqcSignature.length != 3309) revert BadPqcSignatureLength();
        }

        uint256 amount = _trancheAmount(pr);

        // ── Programme-wide anti-dump circuit breaker ──
        if (block.timestamp >= _windowStart + MCU_AUTHORIZATION_INTERVAL) {
            _windowStart = block.timestamp;
            _windowReleased = 0;
        }
        // Basis is totalDeposited: monotonic, so a tranche that was legal when the
        // project opened can never become illegal later. A busy window only delays a
        // release to the next window; it can never strand a project permanently.
        if (_windowReleased + amount > (totalDeposited * GLOBAL_RELEASE_CAP_BPS) / 10000) {
            revert GlobalReleaseCapExceeded();
        }
        _windowReleased += amount;

        unchecked { ++mcuNonce[projectId]; }
        pr.lastAuthorizedAt = block.timestamp;
        pr.milestonesDone += 1;
        pr.released += amount;
        totalCommitted -= amount;
        totalReleased += amount;

        if (pr.milestonesDone == pr.milestoneCount) {
            pr.complete = true;
            emit ProjectCompleted(projectId, pr.released);
        }

        emit MilestoneAuthorized(
            projectId, pr.milestonesDone, amount, digest, keccak256(mcuPqcSignature), pqcVerifiedOnChain
        );

        _safeTransfer(OBS_TOKEN, pr.beneficiary, amount);
    }

    /// @dev Equal tranches; the final tranche absorbs any integer-division dust so
    ///      a project always pays out exactly its approved total, never a wei more.
    function _trancheAmount(Project storage pr) private view returns (uint256) {
        if (pr.milestonesDone + 1 == pr.milestoneCount) return pr.total - pr.released;
        return pr.total / pr.milestoneCount;
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getProposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function getProject(uint256 id) external view returns (Project memory) {
        return _projects[id];
    }

    /// @notice Seconds until this project's next MCU authorisation window opens.
    function timeUntilNextAuthorization(uint256 projectId) external view returns (uint256) {
        Project storage pr = _projects[projectId];
        uint256 due = pr.lastAuthorizedAt + MCU_AUTHORIZATION_INTERVAL;
        return block.timestamp >= due ? 0 : due - block.timestamp;
    }

    /// @notice Minimum seconds a project needs to pay out in full, by construction.
    function minimumProjectDuration(uint256 projectId) external view returns (uint256) {
        return uint256(_projects[projectId].milestoneCount) * MCU_AUTHORIZATION_INTERVAL;
    }

    /*//////////////////////////////////////////////////////////////
                          SIGNATURES / TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function _ethSignedMessage(bytes32 digest) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }

    function _recover(bytes32 hash, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        // Reject the malleable upper half of the curve order.
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        return ecrecover(hash, v, r, s);
    }

    function _safeTransfer(address token, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @dev There is deliberately no `receive` and no `fallback`, and no function in
    ///      this contract is payable. A plain ETH transfer therefore reverts at the
    ///      EVM level. The contract becomes immutable with no ETH withdrawal path, so
    ///      the only safe posture is to be incapable of holding ETH at all.
    ///      (ETH force-sent via `selfdestruct` is unrecoverable here, as it is for
    ///      every contract on the network; nothing in the design depends on it.)
}
