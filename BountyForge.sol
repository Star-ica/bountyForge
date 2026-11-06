// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title BountyForge
 * @notice Decentralized Developer Bounty Marketplace on BOT Chain (chain ID 677)
 * @dev    Escrow for native BOT and USDT bounties with pull-based withdrawals.
 *
 *  Stack-depth fix
 *  ───────────────
 *  The original single Bounty struct (17 fields) caused "stack too deep" in
 *  createBounty even with the CreateBountyParams helper, because the compiler
 *  still needs to push every field onto the stack when it writes the struct
 *  into storage.
 *
 *  Solution: split into
 *    BountyCore   – 9 numeric/address fields (hot path: deposit, approve, pay)
 *    BountyMeta   – 8 string/status fields  (cold path: display, edit)
 *
 *  createBounty now writes them in two separate internal calls, each well
 *  within the 16-slot EVM stack limit.  All external view functions
 *  reconstruct the logical "full bounty" via BountyView (a memory-only
 *  convenience type returned only from view functions – costs nothing on-chain).
 */

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

contract BountyForge {

    /* ─────────────────────────────────────────────
       CONSTANTS
    ───────────────────────────────────────────── */

    uint256 public constant PLATFORM_FEE_BPS = 250;
    uint256 public constant BPS_DENOMINATOR  = 10_000;
    uint256 public constant DISPUTE_WINDOW   = 3 days;
    uint256 public constant MAX_WINNERS      = 50;

    /* ─────────────────────────────────────────────
       ADMIN STATE
    ───────────────────────────────────────────── */

    address public admin;
    address public feeRecipient;
    address public usdtToken;
    bool    public paused;

    uint256 private _bountyIdCounter;
    uint256 private _locked;

    /* ─────────────────────────────────────────────
       ENUMS
    ───────────────────────────────────────────── */

    enum Currency     { BOT, USDT }
    enum BountyStatus { Draft, Open, InReview, Completed, Cancelled, Disputed }
    enum SubStatus    { Pending, Approved, Rejected, Disputed }

    /* ─────────────────────────────────────────────
       STRUCTS – storage (split to avoid stack depth)
    ───────────────────────────────────────────── */

    /// @dev Hot path: financials + control flow.  Max 9 fields → safe on stack.
    struct BountyCore {
        address      org;
        uint256      rewardPerWinner;
        uint256      totalReward;
        uint256      depositedAmount;
        uint256      deadline;
        uint256      maxWinners;
        uint256      approvedCount;
        Currency     currency;
        BountyStatus status;
    }

    /// @dev Cold path: strings + display.  Written/read independently.
    struct BountyMeta {
        string title;
        string description;
        string requirements;
        string skills;
        string language;
        string ecosystem;
        string submissionInstructions;
    }

    /// @dev Memory-only view type – reconstructed in view functions only.
    struct BountyView {
        uint256      id;
        address      org;
        string       title;
        string       description;
        string       requirements;
        string       skills;
        string       language;
        string       ecosystem;
        uint256      rewardPerWinner;
        uint256      totalReward;
        uint256      depositedAmount;
        Currency     currency;
        uint256      deadline;
        uint256      maxWinners;
        uint256      approvedCount;
        BountyStatus status;
        string       submissionInstructions;
    }

    struct Submission {
        uint256   bountyId;
        address   developer;
        string    repoUrl;
        string    prUrl;
        string    notes;
        uint256   submittedAt;
        SubStatus status;
        string    feedback;
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

    /// @dev Input parameter bag for createBounty (avoids extra stack slots at call site).
    struct CreateBountyParams {
        string   title;
        string   description;
        string   requirements;
        string   skills;
        string   language;
        string   ecosystem;
        string   submissionInstructions;
        uint256  rewardPerWinner;
        Currency currency;
        uint256  deadline;
        uint256  maxWinners;
    }

    /* ─────────────────────────────────────────────
       STORAGE
    ───────────────────────────────────────────── */

    mapping(uint256 => BountyCore) public bountyCore;
    mapping(uint256 => BountyMeta) internal _bountyMeta;

    mapping(uint256 => Submission[])                    public submissions;
    mapping(uint256 => mapping(address => bool))        public hasSubmitted;
    mapping(address => OrgProfile)                      public orgProfiles;
    mapping(address => DevProfile)                      public devProfiles;
    mapping(address => uint256[])                       public orgBounties;
    mapping(address => uint256[])                       public devSubmittedBounties;
    mapping(uint256 => mapping(uint256 => uint256))     public disputeRaisedAt;

    mapping(address => uint256) public pendingBOT;
    mapping(address => uint256) public pendingUSDT;

    uint256 public accumulatedBOTFees;
    uint256 public accumulatedUSDTFees;

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
        require(msg.sender == admin, "BF: not admin");
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "BF: reentrant");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        require(!paused, "BF: paused");
        _;
    }

    modifier bountyExists(uint256 id) {
        require(id > 0 && id <= _bountyIdCounter, "BF: not found");
        _;
    }

    modifier onlyOrg(uint256 id) {
        require(bountyCore[id].org == msg.sender, "BF: not org");
        _;
    }

    /* ─────────────────────────────────────────────
       CONSTRUCTOR
    ───────────────────────────────────────────── */

    constructor(address _usdtToken, address _feeRecipient) {
        require(_usdtToken    != address(0), "BF: zero usdt");
        require(_feeRecipient != address(0), "BF: zero fee recipient");
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
        require(bytes(name).length > 0, "BF: empty name");
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
        require(bytes(username).length > 0, "BF: empty username");
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

    /**
     * @notice Create a new bounty.
     * @dev    Uses CreateBountyParams to keep the call-site stack shallow, then
     *         writes Core and Meta in two separate internal helpers – each
     *         touches at most 9 storage fields, staying well below the 16-slot
     *         EVM stack limit without needing --via-ir.
     */
    function createBounty(CreateBountyParams calldata p)
        external
        whenNotPaused
        returns (uint256 id)
    {
        require(bytes(p.title).length > 0,                       "BF: empty title");
        require(p.rewardPerWinner > 0,                           "BF: zero reward");
        require(p.deadline > block.timestamp,                    "BF: past deadline");
        require(p.maxWinners > 0 && p.maxWinners <= MAX_WINNERS, "BF: invalid winners");

        _bountyIdCounter++;
        id = _bountyIdCounter;

        _writeCore(id, p);
        _writeMeta(id, p);

        orgBounties[msg.sender].push(id);
        _allBountyIds.push(id);
        orgProfiles[msg.sender].totalPosted++;

        emit BountyCreated(id, msg.sender, p.title, p.currency, p.rewardPerWinner);
    }

    /// @dev Writes only the numeric/address fields (9 fields, stack-safe).
    function _writeCore(uint256 id, CreateBountyParams calldata p) internal {
        BountyCore storage c = bountyCore[id];
        c.org            = msg.sender;
        c.rewardPerWinner = p.rewardPerWinner;
        c.totalReward    = p.rewardPerWinner * p.maxWinners;
        c.depositedAmount = 0;
        c.deadline       = p.deadline;
        c.maxWinners     = p.maxWinners;
        c.approvedCount  = 0;
        c.currency       = p.currency;
        c.status         = BountyStatus.Draft;
    }

    /// @dev Writes only the string fields (7 strings, stack-safe).
    function _writeMeta(uint256 id, CreateBountyParams calldata p) internal {
        BountyMeta storage m = _bountyMeta[id];
        m.title                  = p.title;
        m.description            = p.description;
        m.requirements           = p.requirements;
        m.skills                 = p.skills;
        m.language               = p.language;
        m.ecosystem              = p.ecosystem;
        m.submissionInstructions = p.submissionInstructions;
    }

    /* ── Deposit ─────────────────────────────────────────────── */

    function depositBOT(uint256 id)
        external
        payable
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        BountyCore storage c = bountyCore[id];
        require(c.currency == Currency.BOT,         "BF: not BOT bounty");
        require(c.status   == BountyStatus.Draft,   "BF: not draft");
        require(msg.value  > 0,                     "BF: zero deposit");

        c.depositedAmount += msg.value;
        emit BountyFunded(id, msg.value, Currency.BOT);

        if (c.depositedAmount >= c.totalReward) {
            c.status = BountyStatus.Open;
            emit BountyOpen(id);
        }
    }

    function depositUSDT(uint256 id, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        BountyCore storage c = bountyCore[id];
        require(c.currency == Currency.USDT,        "BF: not USDT bounty");
        require(c.status   == BountyStatus.Draft,   "BF: not draft");
        require(amount     > 0,                     "BF: zero deposit");

        bool ok = IERC20(usdtToken).transferFrom(msg.sender, address(this), amount);
        require(ok, "BF: USDT transfer failed");

        c.depositedAmount += amount;
        emit BountyFunded(id, amount, Currency.USDT);

        if (c.depositedAmount >= c.totalReward) {
            c.status = BountyStatus.Open;
            emit BountyOpen(id);
        }
    }

    /* ── Edit ────────────────────────────────────────────────── */

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
        BountyCore storage c = bountyCore[id];
        require(c.status == BountyStatus.Open, "BF: not editable");
        require(submissions[id].length == 0,   "BF: has submissions");
        require(deadline > block.timestamp,    "BF: past deadline");

        c.deadline = deadline;

        BountyMeta storage m = _bountyMeta[id];
        m.title                  = title;
        m.description            = description;
        m.requirements           = requirements;
        m.skills                 = skills;
        m.language               = language;
        m.ecosystem              = ecosystem;
        m.submissionInstructions = submissionInstructions;
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
        BountyCore storage c = bountyCore[id];
        require(c.status == BountyStatus.Open,      "BF: not open");
        require(block.timestamp <= c.deadline,       "BF: deadline passed");
        require(!hasSubmitted[id][msg.sender],        "BF: already submitted");
        require(bytes(repoUrl).length > 0,           "BF: empty repo");
        require(devProfiles[msg.sender].registered,  "BF: register first");

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

        c.status = BountyStatus.InReview;
        emit SubmissionMade(id, subIndex, msg.sender, repoUrl);
    }

    /* ─────────────────────────────────────────────
       REVIEW
    ───────────────────────────────────────────── */

    function approveSubmission(uint256 id, uint256 subIndex)
        external
        nonReentrant
        whenNotPaused
        bountyExists(id)
        onlyOrg(id)
    {
        BountyCore storage c = bountyCore[id];
        require(
            c.status == BountyStatus.InReview || c.status == BountyStatus.Open,
            "BF: wrong status"
        );
        require(c.approvedCount < c.maxWinners, "BF: max winners reached");

        Submission storage sub = submissions[id][subIndex];
        require(sub.status == SubStatus.Pending, "BF: not pending");

        uint256 fee    = (c.rewardPerWinner * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
        uint256 payout = c.rewardPerWinner - fee;

        sub.status = SubStatus.Approved;
        c.approvedCount++;
        c.depositedAmount -= c.rewardPerWinner;

        if (c.currency == Currency.BOT) {
            pendingBOT[sub.developer]  += payout;
            accumulatedBOTFees         += fee;
        } else {
            pendingUSDT[sub.developer] += payout;
            accumulatedUSDTFees        += fee;
        }

        devProfiles[sub.developer].totalEarned       += payout;
        devProfiles[sub.developer].completedBounties += 1;
        orgProfiles[c.org].totalPaid                 += c.rewardPerWinner;

        if (c.approvedCount >= c.maxWinners) {
            c.status = BountyStatus.Completed;
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
        require(sub.status == SubStatus.Pending, "BF: not pending");

        sub.status   = SubStatus.Rejected;
        sub.feedback = feedback;

        BountyCore storage c = bountyCore[id];
        if (c.status == BountyStatus.InReview && _pendingSubCount(id) == 0) {
            c.status = BountyStatus.Open;
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
        require(sub.developer == msg.sender,                          "BF: not your sub");
        require(sub.status    == SubStatus.Rejected,                  "BF: not rejected");
        require(block.timestamp <= sub.submittedAt + DISPUTE_WINDOW,  "BF: window closed");

        sub.status                      = SubStatus.Disputed;
        bountyCore[id].status           = BountyStatus.Disputed;
        disputeRaisedAt[id][subIndex]   = block.timestamp;

        emit DisputeRaised(id, subIndex, msg.sender);
    }

    function resolveDispute(uint256 id, uint256 subIndex, bool approve, string calldata resolution)
        external
        nonReentrant
        onlyAdmin
        bountyExists(id)
    {
        Submission storage sub = submissions[id][subIndex];
        require(sub.status == SubStatus.Disputed, "BF: not disputed");

        BountyCore storage c = bountyCore[id];

        if (approve) {
            require(c.approvedCount < c.maxWinners, "BF: max winners reached");

            uint256 fee    = (c.rewardPerWinner * PLATFORM_FEE_BPS) / BPS_DENOMINATOR;
            uint256 payout = c.rewardPerWinner - fee;

            sub.status   = SubStatus.Approved;
            sub.feedback = resolution;
            c.approvedCount++;
            c.depositedAmount -= c.rewardPerWinner;

            if (c.currency == Currency.BOT) {
                pendingBOT[sub.developer]  += payout;
                accumulatedBOTFees         += fee;
            } else {
                pendingUSDT[sub.developer] += payout;
                accumulatedUSDTFees        += fee;
            }

            devProfiles[sub.developer].totalEarned       += payout;
            devProfiles[sub.developer].completedBounties += 1;
            orgProfiles[c.org].totalPaid                 += c.rewardPerWinner;

            emit SubmissionApproved(id, subIndex, sub.developer, payout);
        } else {
            sub.status   = SubStatus.Rejected;
            sub.feedback = resolution;
            emit SubmissionRejected(id, subIndex, sub.developer, resolution);
        }

        c.status = c.approvedCount >= c.maxWinners
            ? BountyStatus.Completed
            : BountyStatus.Open;

        emit DisputeResolved(id, subIndex, approve);
    }

    /* ─────────────────────────────────────────────
       WITHDRAWALS (pull pattern)
    ───────────────────────────────────────────── */

    function withdrawBOT() external nonReentrant {
        uint256 amount = pendingBOT[msg.sender];
        require(amount > 0, "BF: nothing to withdraw");
        pendingBOT[msg.sender] = 0;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "BF: transfer failed");

        emit RewardWithdrawn(msg.sender, amount, Currency.BOT);
    }

    function withdrawUSDT() external nonReentrant {
        uint256 amount = pendingUSDT[msg.sender];
        require(amount > 0, "BF: nothing to withdraw");
        pendingUSDT[msg.sender] = 0;

        bool ok = IERC20(usdtToken).transfer(msg.sender, amount);
        require(ok, "BF: USDT transfer failed");

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
        BountyCore storage c = bountyCore[id];
        require(
            c.status == BountyStatus.Draft || c.status == BountyStatus.Open,
            "BF: cannot cancel"
        );
        require(submissions[id].length == 0 || c.status == BountyStatus.Draft,
            "BF: has submissions");

        c.status = BountyStatus.Cancelled;
        uint256 refund    = c.depositedAmount;
        c.depositedAmount = 0;

        if (refund > 0) {
            _refund(c.currency, msg.sender, refund, id);
        }

        emit BountyCancelled(id);
    }

    function reclaimUnused(uint256 id)
        external
        nonReentrant
        bountyExists(id)
        onlyOrg(id)
    {
        BountyCore storage c = bountyCore[id];
        require(block.timestamp > c.deadline,            "BF: not expired");
        require(c.status != BountyStatus.Cancelled,      "BF: cancelled");
        require(c.depositedAmount > 0,                   "BF: nothing to reclaim");

        uint256 refund    = c.depositedAmount;
        c.depositedAmount = 0;
        c.status = c.approvedCount >= c.maxWinners
            ? BountyStatus.Completed
            : BountyStatus.Cancelled;

        _refund(c.currency, msg.sender, refund, id);
    }

    /// @dev Shared refund logic (keeps cancelBounty + reclaimUnused stack-safe).
    function _refund(Currency currency, address to, uint256 amount, uint256 id) internal {
        if (currency == Currency.BOT) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "BF: refund failed");
            emit RefundIssued(to, amount, Currency.BOT);
        } else {
            bool ok = IERC20(usdtToken).transfer(to, amount);
            require(ok, "BF: USDT refund failed");
            emit RefundIssued(to, amount, Currency.USDT);
        }
    }

    /* ─────────────────────────────────────────────
       ADMIN
    ───────────────────────────────────────────── */

    /// @notice Withdraw ONLY accumulated platform fees — never touches escrow deposits.
    function withdrawFees() external onlyAdmin nonReentrant {
        uint256 botFees  = accumulatedBOTFees;
        uint256 usdtFees = accumulatedUSDTFees;
        accumulatedBOTFees  = 0;
        accumulatedUSDTFees = 0;

        if (botFees > 0) {
            (bool ok, ) = feeRecipient.call{value: botFees}("");
            require(ok, "BF: BOT fee withdrawal failed");
        }
        if (usdtFees > 0) {
            bool ok = IERC20(usdtToken).transfer(feeRecipient, usdtFees);
            require(ok, "BF: USDT fee withdrawal failed");
        }

        emit FeesWithdrawn(feeRecipient, botFees, usdtFees);
    }

    function verifyOrg(address org) external onlyAdmin {
        orgProfiles[org].verified = true;
    }

    function setFeeRecipient(address newRecipient) external onlyAdmin {
        require(newRecipient != address(0), "BF: zero address");
        feeRecipient = newRecipient;
    }

    function transferAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "BF: zero address");
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

    /// @notice Returns the full logical bounty (core + meta merged) as a memory value.
    function getBounty(uint256 id) external view returns (BountyView memory v) {
        BountyCore storage c = bountyCore[id];
        BountyMeta storage m = _bountyMeta[id];
        v.id                     = id;
        v.org                    = c.org;
        v.rewardPerWinner        = c.rewardPerWinner;
        v.totalReward            = c.totalReward;
        v.depositedAmount        = c.depositedAmount;
        v.currency               = c.currency;
        v.deadline               = c.deadline;
        v.maxWinners             = c.maxWinners;
        v.approvedCount          = c.approvedCount;
        v.status                 = c.status;
        v.title                  = m.title;
        v.description            = m.description;
        v.requirements           = m.requirements;
        v.skills                 = m.skills;
        v.language               = m.language;
        v.ecosystem              = m.ecosystem;
        v.submissionInstructions = m.submissionInstructions;
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
