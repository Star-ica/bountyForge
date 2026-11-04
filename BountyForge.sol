// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BountyForge
 * @notice Decentralized Developer Bounty Marketplace on BOT Chain (chain ID 677)
 * @dev Escrow system for native BOT and USDT bounties with pull-based withdrawals
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract BountyForge {
    /* ─────────────────────────────────────────────
       CONSTANTS & STATE
    ───────────────────────────────────────────── */

    uint256 public constant PLATFORM_FEE_BPS = 250;      // 2.5%
    uint256 public constant BPS_DENOMINATOR   = 10_000;
    uint256 public constant DISPUTE_WINDOW    = 3 days;
    uint256 public constant MAX_WINNERS       = 50;

    address public admin;
    address public feeRecipient;
    address public usdtToken;          // USDT contract on BOT Chain
    bool    public paused;

    uint256 private _bountyIdCounter;
    uint256 private _locked; // reentrancy guard

    /* ─────────────────────────────────────────────
       ENUMS
    ───────────────────────────────────────────── */

    enum Currency     { BOT, USDT }
    enum BountyStatus { Draft, Open, InReview, Completed, Cancelled, Disputed }
    enum SubStatus    { Pending, Approved, Rejected, Disputed }

    /* ─────────────────────────────────────────────
       STRUCTS
    ───────────────────────────────────────────── */

    struct Bounty {
        uint256  id;
        address  org;
        string   title;
        string   description;
        string   requirements;       // IPFS hash or JSON
        string   skills;
        string   language;
        string   ecosystem;
        uint256  rewardPerWinner;
        uint256  totalReward;
        uint256  depositedAmount;
        Currency currency;
        uint256  deadline;
        uint256  maxWinners;
        uint256  approvedCount;
        BountyStatus status;
        string   submissionInstructions;
    }

    struct Submission {
        uint256  bountyId;
        address  developer;
        string   repoUrl;
        string   prUrl;
        string   notes;
        uint256  submittedAt;
        SubStatus status;
        string   feedback;
    }

    struct OrgProfile {
        string  name;
        string  website;
        string  description;
        string  logoIpfs;
        bool    verified;
        uint256 totalPosted;
        uint256 totalPaid;
    }

    struct DevProfile {
        string  username;
        string  skills;
        string  githubUrl;
        string  bio;
        uint256 totalEarned;
        uint256 completedBounties;
        bool    registered;
    }

    /* ─────────────────────────────────────────────
       STORAGE
    ───────────────────────────────────────────── */

    mapping(uint256 => Bounty)        public bounties;
    mapping(uint256 => Submission[])  public submissions;         // bountyId → submissions
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;
    mapping(address => OrgProfile)    public orgProfiles;
    mapping(address => DevProfile)    public devProfiles;
    mapping(address => uint256[])     public orgBounties;
    mapping(address => uint256[])     public devSubmittedBounties;

    // Pull-based withdrawal balances
    mapping(address => uint256) public pendingBOT;
    mapping(address => uint256) public pendingUSDT;

    // Fee accumulation
    uint256 public accumulatedBOTFees;
    uint256 public accumulatedUSDTFees;

    // Dispute: bountyId => submissionIndex => disputeTimestamp
    mapping(uint256 => mapping(uint256 => uint256)) public disputeRaisedAt;

    uint256[] private _allBountyIds;

    /* ─────────────────────────────────────────────
       EVENTS
    ───────────────────────────────────────────── */

    event OrgRegistered(address indexed org, string name);
    event DevRegistered(address indexed dev, string username);
    event BountyCreated(uint256 indexed id, address indexed org, string title, Currency currency, uint256 rewardPerWinner);
    event BountyFunded(uint256 indexed id, uint256 amount, Currency currency);
    event BountyOpen(uint256 indexed id);
    event SubmissionMade(uint256 indexed bountyId, uint256 subIndex, address indexed dev, string repoUrl);
    event SubmissionApproved(uint256 indexed bountyId, uint256 subIndex, address indexed dev, uint256 reward);
    event SubmissionRejected(uint256 indexed bountyId, uint256 subIndex, address indexed dev, string feedback);
    event DisputeRaised(uint256 indexed bountyId, uint256 subIndex, address indexed dev);
    event DisputeResolved(uint256 indexed bountyId, uint256 subIndex, bool approvedByAdmin);
    event RewardWithdrawn(address indexed dev, uint256 amount, Currency currency);
    event BountyCancelled(uint256 indexed id);
    event RefundIssued(address indexed org, uint256 amount, Currency currency);
    event FeesWithdrawn(address indexed recipient, uint256 botAmount, uint256 usdtAmount);
    event AdminChanged(address indexed newAdmin);
    event Paused(bool state);

    /* ─────────────────────────────────────────────
       MODIFIERS
    ───────────────────────────────────────────── */

    modifier onlyAdmin() {
        require(msg.sender == admin, "BountyForge: not admin");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "BountyForge: reentrant call");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "BountyForge: paused");
        _;
    }

    modifier bountyExists(uint256 id) {
        require(id > 0 && id <= _bountyIdCounter, "BountyForge: bounty not found");
        _;
    }

    modifier onlyOrg(uint256 id) {
        require(bounties[id].org == msg.sender, "BountyForge: not bounty org");
        _;
    }

    /* ─────────────────────────────────────────────
       CONSTRUCTOR
    ───────────────────────────────────────────── */

    constructor(address _usdtToken, address _feeRecipient) {
        require(_usdtToken != address(0), "BountyForge: zero usdt");
        require(_feeRecipient != address(0), "BountyForge: zero fee recipient");
        admin        = msg.sender;
        feeRecipient = _feeRecipient;
        usdtToken    = _usdtToken;
        _locked      = 1;
    }

    /* ─────────────────────────────────────────────
       PROFILE MANAGEMENT
    ───────────────────────────────────────────── */

    function registerOrg(
        string calldata name,
        string calldata website,
        string calldata description,
        string calldata logoIpfs
    ) external whenNotPaused {
        require(bytes(name).length > 0, "BountyForge: empty name");
        OrgProfile storage p = orgProfiles[msg.sender];
        p.name        = name;
        p.website     = website;
        p.description = description;
        p.logoIpfs    = logoIpfs;
        emit OrgRegistered(msg.sender, name);
    }

    function registerDev(
        string calldata username,
        string calldata skills,
        string calldata githubUrl,
        string calldata bio
    ) external whenNotPaused {
        require(bytes(username).length > 0, "BountyForge: empty username");
        DevProfile storage p = devProfiles[msg.sender];
        p.username   = username;
        p.skills     = skills;
        p.githubUrl  = githubUrl;
        p.bio        = bio;
        p.registered = true;
        emit DevRegistered(msg.sender, username);
    }

    /* ─────────────────────────────────────────────
       BOUNTY LIFECYCLE
    ───────────────────────────────────────────── */

    function createBounty(
        string calldata title,
        string calldata description,
        string calldata requirements,
        string calldata skills,
        string calldata language,
        string calldata ecosystem,
        uint256         rewardPerWinner,
        Currency        currency,
        uint256         deadline,
        uint256         maxWinners,
        string calldata submissionInstructions
    ) external whenNotPaused returns (uint256 id) {
        require(bytes(title).length > 0,       "BountyForge: empty title");
        require(rewardPerWinner > 0,            "BountyForge: zero reward");
        require(deadline > block.timestamp,     "BountyForge: past deadline");
        require(maxWinners > 0 && maxWinners <= MAX_WINNERS, "BountyForge: invalid winners");

        _bountyIdCounter++;
        id = _bountyIdCounter;

        uint256 totalReward = rewardPerWinner * maxWinners;

        bounties[id] = Bounty({
            id:                     id,
            org:                    msg.sender,
            title:                  title,
            description:            description,
            requirements:           requirements,
            skills:                 skills,
            language:               language,
            ecosystem:              ecosystem,
            rewardPerWinner:        rewardPerWinner,
            totalReward:            totalReward,
            depositedAmount:        0,
            currency:               currency,
            deadline:               deadline,
            maxWinners:             maxWinners,
            approvedCount:          0,
            status:                 BountyStatus.Draft,
            submissionInstructions: submissionInstructions
        });

        orgBounties[msg.sender].push(id);
        _allBountyIds.push(id);
        orgProfiles[msg.sender].totalPosted++;

        emit BountyCreated(id, msg.sender, title, currency, rewardPerWinner);
    }

    /// @notice Deposit BOT (native) to fund a bounty
    function depositBOT(uint256 id)
        external
        payable
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        Bounty storage b = bounties[id];
        require(b.currency == Currency.BOT,                "BountyForge: not BOT bounty");
        require(b.status == BountyStatus.Draft,            "BountyForge: not draft");
        require(msg.value > 0,                             "BountyForge: zero deposit");

        b.depositedAmount += msg.value;

        emit BountyFunded(id, msg.value, Currency.BOT);

        if (b.depositedAmount >= b.totalReward) {
            b.status = BountyStatus.Open;
            emit BountyOpen(id);
        }
    }

    /// @notice Deposit USDT to fund a bounty
    function depositUSDT(uint256 id, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        Bounty storage b = bounties[id];
        require(b.currency == Currency.USDT,               "BountyForge: not USDT bounty");
        require(b.status == BountyStatus.Draft,            "BountyForge: not draft");
        require(amount > 0,                                "BountyForge: zero deposit");

        bool ok = IERC20(usdtToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "BountyForge: USDT transfer failed");

        b.depositedAmount += amount;

        emit BountyFunded(id, amount, Currency.USDT);

        if (b.depositedAmount >= b.totalReward) {
            b.status = BountyStatus.Open;
            emit BountyOpen(id);
        }
    }

    /// @notice Update eligible bounty details (only while Open and before any submissions)
    function editBounty(
        uint256 id,
        string calldata title,
        string calldata description,
        string calldata requirements,
        string calldata skills,
        string calldata language,
        string calldata ecosystem,
        uint256         deadline,
        string calldata submissionInstructions
    ) external bountyExists(id) onlyOrg(id) {
        Bounty storage b = bounties[id];
        require(b.status == BountyStatus.Open,         "BountyForge: not editable");
        require(submissions[id].length == 0,           "BountyForge: has submissions");
        require(deadline > block.timestamp,            "BountyForge: past deadline");

        b.title                  = title;
        b.description            = description;
        b.requirements           = requirements;
        b.skills                 = skills;
        b.language               = language;
        b.ecosystem              = ecosystem;
        b.deadline               = deadline;
        b.submissionInstructions = submissionInstructions;
    }

    /* ─────────────────────────────────────────────
       SUBMISSION
    ───────────────────────────────────────────── */

    function submitWork(
        uint256 id,
        string calldata repoUrl,
        string calldata prUrl,
        string calldata notes
    ) external whenNotPaused bountyExists(id) {
        Bounty storage b = bounties[id];
        require(b.status == BountyStatus.Open,         "BountyForge: not open");
        require(block.timestamp <= b.deadline,         "BountyForge: deadline passed");
        require(!hasSubmitted[id][msg.sender],         "BountyForge: already submitted");
        require(bytes(repoUrl).length > 0,             "BountyForge: empty repo");
        require(devProfiles[msg.sender].registered,    "BountyForge: register first");

        hasSubmitted[id][msg.sender] = true;
        devSubmittedBounties[msg.sender].push(id);

        uint256 subIndex = submissions[id].length;
        submissions[id].push(Submission({
            bountyId:    id,
            developer:   msg.sender,
            repoUrl:     repoUrl,
            prUrl:       prUrl,
            notes:       notes,
            submittedAt: block.timestamp,
            status:      SubStatus.Pending,
            feedback:    ""
        }));

        if (b.status == BountyStatus.Open) {
            b.status = BountyStatus.InReview;
        }

        emit SubmissionMade(id, subIndex, msg.sender, repoUrl);
    }

    /* ─────────────────────────────────────────────
       REVIEW: APPROVE / REJECT
    ───────────────────────────────────────────── */

    function approveSubmission(uint256 id, uint256 subIndex)
        external
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        Bounty storage b = bounties[id];
        require(
            b.status == BountyStatus.InReview || b.status == BountyStatus.Open,
            "BountyForge: wrong status"
        );
        require(b.approvedCount < b.maxWinners,            "BountyForge: max winners reached");

        Submission storage sub = submissions[id][subIndex];
        require(sub.status == SubStatus.Pending,           "BountyForge: not pending");

        uint256 fee    = (b.rewardPerWinner * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 payout = b.rewardPerWinner - fee;

        sub.status = SubStatus.Approved;
        b.approvedCount++;
        b.depositedAmount -= b.rewardPerWinner;

        if (b.currency == Currency.BOT) {
            pendingBOT[sub.developer] += payout;
            accumulatedBOTFees        += fee;
        } else {
            pendingUSDT[sub.developer] += payout;
            accumulatedUSDTFees        += fee;
        }

        devProfiles[sub.developer].totalEarned           += payout;
        devProfiles[sub.developer].completedBounties     += 1;
        orgProfiles[b.org].totalPaid                     += b.rewardPerWinner;

        if (b.approvedCount >= b.maxWinners) {
            b.status = BountyStatus.Completed;
        }

        emit SubmissionApproved(id, subIndex, sub.developer, payout);
    }

    function rejectSubmission(uint256 id, uint256 subIndex, string calldata feedback)
        external
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        Submission storage sub = submissions[id][subIndex];
        require(sub.status == SubStatus.Pending, "BountyForge: not pending");

        sub.status   = SubStatus.Rejected;
        sub.feedback = feedback;

        // Re-open if no more pending subs
        Bounty storage b = bounties[id];
        if (b.status == BountyStatus.InReview && _pendingSubCount(id) == 0) {
            b.status = BountyStatus.Open;
        }

        emit SubmissionRejected(id, subIndex, sub.developer, feedback);
    }

    /* ─────────────────────────────────────────────
       DISPUTE
    ───────────────────────────────────────────── */

    function raiseDispute(uint256 id, uint256 subIndex)
        external
        whenNotPaused
        bountyExists(id)
    {
        Submission storage sub = submissions[id][subIndex];
        require(sub.developer == msg.sender,                   "BountyForge: not your sub");
        require(sub.status == SubStatus.Rejected,              "BountyForge: not rejected");
        require(block.timestamp <= sub.submittedAt + DISPUTE_WINDOW, "BountyForge: dispute window closed");

        sub.status                          = SubStatus.Disputed;
        bounties[id].status                 = BountyStatus.Disputed;
        disputeRaisedAt[id][subIndex]       = block.timestamp;

        emit DisputeRaised(id, subIndex, msg.sender);
    }

    /// @notice Admin resolves disputes — can approve or confirm rejection, cannot seize deposited funds
    function resolveDispute(uint256 id, uint256 subIndex, bool approve, string calldata resolution)
        external
        nonReentrant
        onlyAdmin
        bountyExists(id)
    {
        Submission storage sub = submissions[id][subIndex];
        require(sub.status == SubStatus.Disputed, "BountyForge: not disputed");

        Bounty storage b = bounties[id];

        if (approve) {
            require(b.approvedCount < b.maxWinners, "BountyForge: max winners reached");

            uint256 fee    = (b.rewardPerWinner * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
            uint256 payout = b.rewardPerWinner - fee;

            sub.status     = SubStatus.Approved;
            sub.feedback   = resolution;
            b.approvedCount++;
            b.depositedAmount -= b.rewardPerWinner;

            if (b.currency == Currency.BOT) {
                pendingBOT[sub.developer] += payout;
                accumulatedBOTFees        += fee;
            } else {
                pendingUSDT[sub.developer] += payout;
                accumulatedUSDTFees        += fee;
            }

            devProfiles[sub.developer].totalEarned       += payout;
            devProfiles[sub.developer].completedBounties += 1;
            orgProfiles[b.org].totalPaid                 += b.rewardPerWinner;

            emit SubmissionApproved(id, subIndex, sub.developer, payout);
        } else {
            sub.status   = SubStatus.Rejected;
            sub.feedback = resolution;
            emit SubmissionRejected(id, subIndex, sub.developer, resolution);
        }

        // Restore bounty status
        if (b.approvedCount >= b.maxWinners) {
            b.status = BountyStatus.Completed;
        } else {
            b.status = BountyStatus.Open;
        }

        emit DisputeResolved(id, subIndex, approve);
    }

    /* ─────────────────────────────────────────────
       WITHDRAWALS (pull pattern)
    ───────────────────────────────────────────── */

    function withdrawBOT() external nonReentrant {
        uint256 amount = pendingBOT[msg.sender];
        require(amount > 0, "BountyForge: nothing to withdraw");
        pendingBOT[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "BountyForge: transfer failed");

        emit RewardWithdrawn(msg.sender, amount, Currency.BOT);
    }

    function withdrawUSDT() external nonReentrant {
        uint256 amount = pendingUSDT[msg.sender];
        require(amount > 0, "BountyForge: nothing to withdraw");
        pendingUSDT[msg.sender] = 0;

        bool ok = IERC20(usdtToken).transfer(msg.sender, amount);
        require(ok, "BountyForge: USDT transfer failed");

        emit RewardWithdrawn(msg.sender, amount, Currency.USDT);
    }

    /* ─────────────────────────────────────────────
       CANCEL & REFUND
    ───────────────────────────────────────────── */

    function cancelBounty(uint256 id)
        external
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        Bounty storage b = bounties[id];
        require(
            b.status == BountyStatus.Draft || b.status == BountyStatus.Open,
            "BountyForge: cannot cancel"
        );
        require(submissions[id].length == 0 || b.status == BountyStatus.Draft,
            "BountyForge: has submissions");

        b.status = BountyStatus.Cancelled;
        uint256 refund = b.depositedAmount;
        b.depositedAmount = 0;

        if (refund > 0) {
            if (b.currency == Currency.BOT) {
                (bool ok, ) = msg.sender.call{value: refund}("");
                require(ok, "BountyForge: refund failed");
                emit RefundIssued(msg.sender, refund, Currency.BOT);
            } else {
                bool ok = IERC20(usdtToken).transfer(msg.sender, refund);
                require(ok, "BountyForge: USDT refund failed");
                emit RefundIssued(msg.sender, refund, Currency.USDT);
            }
        }

        emit BountyCancelled(id);
    }

    /// @notice After deadline, org can reclaim un-disbursed deposited funds
    function reclaimUnused(uint256 id)
        external
        nonReentrant
        bountyExists(id)
        onlyOrg(id)
    {
        Bounty storage b = bounties[id];
        require(block.timestamp > b.deadline,              "BountyForge: not expired");
        require(b.status != BountyStatus.Cancelled,       "BountyForge: cancelled");
        require(b.depositedAmount > 0,                    "BountyForge: nothing to reclaim");

        // Only reclaim the portion not yet allocated to approved subs
        uint256 refund    = b.depositedAmount;
        b.depositedAmount = 0;

        if (b.approvedCount >= b.maxWinners) {
            b.status = BountyStatus.Completed;
        } else {
            b.status = BountyStatus.Cancelled;
        }

        if (b.currency == Currency.BOT) {
            (bool ok, ) = msg.sender.call{value: refund}("");
            require(ok, "BountyForge: refund failed");
            emit RefundIssued(msg.sender, refund, Currency.BOT);
        } else {
            bool ok = IERC20(usdtToken).transfer(msg.sender, refund);
            require(ok, "BountyForge: USDT refund failed");
            emit RefundIssued(msg.sender, refund, Currency.USDT);
        }
    }

    /* ─────────────────────────────────────────────
       ADMIN
    ───────────────────────────────────────────── */

    /// @notice Withdraw ONLY accumulated platform fees — never touches deposited escrow funds
    function withdrawFees() external onlyAdmin nonReentrant {
        uint256 botFees  = accumulatedBOTFees;
        uint256 usdtFees = accumulatedUSDTFees;
        accumulatedBOTFees  = 0;
        accumulatedUSDTFees = 0;

        if (botFees > 0) {
            (bool ok, ) = feeRecipient.call{value: botFees}("");
            require(ok, "BountyForge: BOT fee withdrawal failed");
        }
        if (usdtFees > 0) {
            bool ok = IERC20(usdtToken).transfer(feeRecipient, usdtFees);
            require(ok, "BountyForge: USDT fee withdrawal failed");
        }

        emit FeesWithdrawn(feeRecipient, botFees, usdtFees);
    }

    function verifyOrg(address org) external onlyAdmin {
        orgProfiles[org].verified = true;
    }

    function setFeeRecipient(address newRecipient) external onlyAdmin {
        require(newRecipient != address(0), "BountyForge: zero address");
        feeRecipient = newRecipient;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "BountyForge: zero address");
        admin = newAdmin;
        emit AdminChanged(newAdmin);
    }

    function setPaused(bool state) external onlyAdmin {
        paused = state;
        emit Paused(state);
    }

    /* ─────────────────────────────────────────────
       VIEW FUNCTIONS
    ───────────────────────────────────────────── */

    function getBounty(uint256 id) external view returns (Bounty memory) {
        return bounties[id];
    }

    function getSubmissions(uint256 id) external view returns (Submission[] memory) {
        return submissions[id];
    }

    function getSubmission(uint256 id, uint256 subIndex) external view returns (Submission memory) {
        return submissions[id][subIndex];
    }

    function getAllBountyIds() external view returns (uint256[] memory) {
        return _allBountyIds;
    }

    function getOrgBounties(address org) external view returns (uint256[] memory) {
        return orgBounties[org];
    }

    function getDevSubmittedBounties(address dev) external view returns (uint256[] memory) {
        return devSubmittedBounties[dev];
    }

    function bountyCount() external view returns (uint256) {
        return _bountyIdCounter;
    }

    function getPendingBalance(address user)
        external view returns (uint256 botBalance, uint256 usdtBalance)
    {
        return (pendingBOT[user], pendingUSDT[user]);
    }

    /* ─────────────────────────────────────────────
       INTERNAL HELPERS
    ───────────────────────────────────────────── */

    function _pendingSubCount(uint256 id) internal view returns (uint256 count) {
        Submission[] storage subs = submissions[id];
        for (uint256 i = 0; i < subs.length; i++) {
            if (subs[i].status == SubStatus.Pending) count++;
        }
    }

    receive() external payable {}
}
