// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  FreelanceEscrow - Freelance Escrow & Smart Payment Platform
 * @notice DigitalWork Solutions: ถือเงินค่าจ้างไว้ใน Smart Contract (Escrow)
 *         และปล่อยเงินให้ฟรีแลนซ์อัตโนมัติเมื่อผู้ว่าจ้างอนุมัติงาน
 *
 * Functional Requirements
 *  1. createJob        – ผู้ว่าจ้างสร้างข้อตกลง (ชื่อโครงการ, รายละเอียด, ค่าจ้าง, กำหนดส่ง, wallet ฟรีแลนซ์)
 *  2. depositPayment   – ผู้ว่าจ้างฝาก ETH เข้าสัญญาตามค่าจ้างที่ตกลง
 *  3. submitWork       – ฟรีแลนซ์บันทึกหลักฐานการส่งงาน (URL / Hash ไฟล์)
 *  4. approveAndRelease– ผู้ว่าจ้างอนุมัติ ระบบโอน ETH ให้ฟรีแลนซ์อัตโนมัติ
 *  5. raiseDispute / resolveDispute – แจ้งข้อพิพาท และผู้ดูแล (Arbiter) ตัดสินคืนเงิน/จ่ายเงิน/แบ่งจ่าย
 *  6. Tracking         – getJob / getJobsOf + Events ทุกขั้นตอน (ดู Transaction Hash ผ่านหน้าเว็บ)
 *
 * Business Rules
 *  - ห้ามจ่ายเงินซ้ำ: ใช้ State Machine + ล้างยอด escrow เป็น 0 ก่อนโอน + ป้องกัน Reentrancy
 *  - เบิกเงินออกจาก Escrow ได้เฉพาะเมื่อ (ก) ผู้ว่าจ้างอนุมัติ (ข) Arbiter ระงับข้อพิพาท
 *    หรือ (ค) เลยกำหนดส่งแล้วฟรีแลนซ์ยังไม่ส่งงาน (คืนเงินผู้ว่าจ้าง)
 */
contract FreelanceEscrow {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------
    enum Status {
        Created,    // 0 สร้างข้อตกลงแล้ว รอฝากเงิน
        Funded,     // 1 ฝากเงินแล้ว รอส่งงาน
        Submitted,  // 2 ส่งงานแล้ว รอตรวจรับ
        Released,   // 3 อนุมัติและจ่ายเงินให้ฟรีแลนซ์แล้ว (ปิดงาน)
        Disputed,   // 4 อยู่ระหว่างข้อพิพาท
        Resolved,   // 5 ผู้ดูแลตัดสินข้อพิพาทแล้ว (ปิดงาน)
        Refunded,   // 6 คืนเงินผู้ว่าจ้างแล้ว (ปิดงาน)
        Cancelled   // 7 ยกเลิกก่อนฝากเงิน (ปิดงาน)
    }

    struct Job {
        uint256 id;
        address client;          // ผู้ว่าจ้าง
        address freelancer;      // ฟรีแลนซ์
        string  title;           // ชื่อโครงการ
        string  description;     // รายละเอียดงาน
        uint256 amount;          // ค่าจ้าง (wei)
        uint256 escrowBalance;   // ยอดเงินที่ถูกล็อกอยู่ในสัญญาตอนนี้
        uint256 deadline;        // กำหนดส่ง (unix timestamp)
        string  workEvidence;    // URL หรือ Hash ของไฟล์งาน
        Status  status;
        address disputeRaisedBy;
        string  disputeReason;
        uint256 createdAt;
        uint256 updatedAt;
    }

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------
    address public owner;                         // ผู้ดูแลแพลตฟอร์ม
    mapping(address => bool) public isArbiter;    // ผู้ดูแลที่ได้รับสิทธิ์ตัดสินข้อพิพาท
    uint256 public jobCount;
    mapping(uint256 => Job) private jobs;
    mapping(address => uint256[]) private clientJobs;
    mapping(address => uint256[]) private freelancerJobs;
    uint256 private locked = 1;                   // reentrancy guard

    // ------------------------------------------------------------------
    // Events (ใช้สำหรับ Transaction Tracking บนหน้าเว็บ / Etherscan)
    // ------------------------------------------------------------------
    event JobCreated(uint256 indexed jobId, address indexed client, address indexed freelancer, string title, uint256 amount, uint256 deadline);
    event PaymentDeposited(uint256 indexed jobId, address indexed client, uint256 amount);
    event WorkSubmitted(uint256 indexed jobId, address indexed freelancer, string evidence);
    event PaymentReleased(uint256 indexed jobId, address indexed freelancer, uint256 amount);
    event DisputeRaised(uint256 indexed jobId, address indexed raisedBy, string reason);
    event DisputeResolved(uint256 indexed jobId, address indexed arbiter, uint256 toFreelancer, uint256 toClient);
    event Refunded(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobCancelled(uint256 indexed jobId);
    event ArbiterUpdated(address indexed account, bool allowed);

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyArbiter() {
        require(isArbiter[msg.sender], "Only arbiter");
        _;
    }

    modifier jobExists(uint256 _jobId) {
        require(_jobId > 0 && _jobId <= jobCount, "Job not found");
        _;
    }

    modifier nonReentrant() {
        require(locked == 1, "Reentrant call");
        locked = 2;
        _;
        locked = 1;
    }

    constructor() {
        owner = msg.sender;
        isArbiter[msg.sender] = true;
        emit ArbiterUpdated(msg.sender, true);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------
    function setArbiter(address _account, bool _allowed) external onlyOwner {
        require(_account != address(0), "Invalid address");
        isArbiter[_account] = _allowed;
        emit ArbiterUpdated(_account, _allowed);
    }

    // ------------------------------------------------------------------
    // 1. Create Contract
    // ------------------------------------------------------------------
    function createJob(
        string calldata _title,
        string calldata _description,
        uint256 _amount,
        uint256 _deadline,
        address _freelancer
    ) external returns (uint256) {
        require(bytes(_title).length > 0, "Title required");
        require(_amount > 0, "Amount must be > 0");
        require(_deadline > block.timestamp, "Deadline must be in the future");
        require(_freelancer != address(0), "Invalid freelancer");
        require(_freelancer != msg.sender, "Client cannot be freelancer");

        jobCount++;
        Job storage j = jobs[jobCount];
        j.id = jobCount;
        j.client = msg.sender;
        j.freelancer = _freelancer;
        j.title = _title;
        j.description = _description;
        j.amount = _amount;
        j.deadline = _deadline;
        j.status = Status.Created;
        j.createdAt = block.timestamp;
        j.updatedAt = block.timestamp;

        clientJobs[msg.sender].push(jobCount);
        freelancerJobs[_freelancer].push(jobCount);

        emit JobCreated(jobCount, msg.sender, _freelancer, _title, _amount, _deadline);
        return jobCount;
    }

    /// @notice ผู้ว่าจ้างยกเลิกข้อตกลงได้ก่อนฝากเงินเท่านั้น
    function cancelJob(uint256 _jobId) external jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.status == Status.Created, "Can cancel only before deposit");
        j.status = Status.Cancelled;
        j.updatedAt = block.timestamp;
        emit JobCancelled(_jobId);
    }

    // ------------------------------------------------------------------
    // 2. Deposit Payment
    // ------------------------------------------------------------------
    function depositPayment(uint256 _jobId) external payable jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.status == Status.Created, "Already funded or closed");
        require(msg.value == j.amount, "Must deposit exact amount");

        j.escrowBalance = msg.value;
        j.status = Status.Funded;
        j.updatedAt = block.timestamp;

        emit PaymentDeposited(_jobId, msg.sender, msg.value);
    }

    // ------------------------------------------------------------------
    // 3. Submit Work
    // ------------------------------------------------------------------
    function submitWork(uint256 _jobId, string calldata _evidence) external jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.freelancer, "Only freelancer");
        // ส่งครั้งแรก (Funded) หรือส่งแก้ไขใหม่ (Submitted) ได้
        require(j.status == Status.Funded || j.status == Status.Submitted, "Not ready for submission");
        require(block.timestamp <= j.deadline, "Deadline passed");
        require(bytes(_evidence).length > 0, "Evidence required");

        j.workEvidence = _evidence;
        j.status = Status.Submitted;
        j.updatedAt = block.timestamp;

        emit WorkSubmitted(_jobId, msg.sender, _evidence);
    }

    // ------------------------------------------------------------------
    // 4. Approve & Release Payment
    // ------------------------------------------------------------------
    function approveAndRelease(uint256 _jobId) external nonReentrant jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.status == Status.Submitted, "Work not submitted / already paid");
        require(j.escrowBalance > 0, "No funds in escrow");

        // Effects ก่อน Interactions -> ป้องกันจ่ายซ้ำ
        uint256 payout = j.escrowBalance;
        j.escrowBalance = 0;
        j.status = Status.Released;
        j.updatedAt = block.timestamp;

        _send(j.freelancer, payout);
        emit PaymentReleased(_jobId, j.freelancer, payout);
    }

    // ------------------------------------------------------------------
    // 5. Dispute Management
    // ------------------------------------------------------------------
    function raiseDispute(uint256 _jobId, string calldata _reason) external jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client || msg.sender == j.freelancer, "Only parties");
        require(j.status == Status.Funded || j.status == Status.Submitted, "Cannot dispute in this status");
        require(bytes(_reason).length > 0, "Reason required");

        j.status = Status.Disputed;
        j.disputeRaisedBy = msg.sender;
        j.disputeReason = _reason;
        j.updatedAt = block.timestamp;

        emit DisputeRaised(_jobId, msg.sender, _reason);
    }

    /**
     * @notice ผู้ดูแลตัดสินข้อพิพาท
     * @param _toFreelancer จำนวน wei ที่จ่ายให้ฟรีแลนซ์ ส่วนที่เหลือคืนผู้ว่าจ้าง
     *        = 0            -> คืนเงินผู้ว่าจ้างทั้งหมด
     *        = escrow ทั้งหมด -> จ่ายฟรีแลนซ์ทั้งหมด
     *        ค่าอื่น          -> แบ่งจ่ายตามเงื่อนไข
     */
    function resolveDispute(uint256 _jobId, uint256 _toFreelancer)
        external
        nonReentrant
        onlyArbiter
        jobExists(_jobId)
    {
        Job storage j = jobs[_jobId];
        require(j.status == Status.Disputed, "No active dispute");
        require(msg.sender != j.client && msg.sender != j.freelancer, "Arbiter cannot be a party");
        uint256 total = j.escrowBalance;
        require(_toFreelancer <= total, "Exceeds escrow");

        uint256 toClient = total - _toFreelancer;
        j.escrowBalance = 0;
        j.status = Status.Resolved;
        j.updatedAt = block.timestamp;

        if (_toFreelancer > 0) _send(j.freelancer, _toFreelancer);
        if (toClient > 0) _send(j.client, toClient);

        emit DisputeResolved(_jobId, msg.sender, _toFreelancer, toClient);
    }

    /// @notice เลยกำหนดส่งแล้วฟรีแลนซ์ยังไม่ส่งงาน -> ผู้ว่าจ้างขอคืนเงินได้
    function refundAfterDeadline(uint256 _jobId) external nonReentrant jobExists(_jobId) {
        Job storage j = jobs[_jobId];
        require(msg.sender == j.client, "Only client");
        require(j.status == Status.Funded, "Refund not allowed in this status");
        require(block.timestamp > j.deadline, "Deadline not passed");

        uint256 refund = j.escrowBalance;
        j.escrowBalance = 0;
        j.status = Status.Refunded;
        j.updatedAt = block.timestamp;

        _send(j.client, refund);
        emit Refunded(_jobId, j.client, refund);
    }

    // ------------------------------------------------------------------
    // 6. Transaction Tracking (view)
    // ------------------------------------------------------------------
    function getJob(uint256 _jobId) external view jobExists(_jobId) returns (Job memory) {
        return jobs[_jobId];
    }

    function getJobsByClient(address _client) external view returns (uint256[] memory) {
        return clientJobs[_client];
    }

    function getJobsByFreelancer(address _freelancer) external view returns (uint256[] memory) {
        return freelancerJobs[_freelancer];
    }

    function contractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------
    function _send(address _to, uint256 _amount) private {
        (bool ok, ) = payable(_to).call{value: _amount}("");
        require(ok, "ETH transfer failed");
    }

    /// @dev ไม่รับ ETH ที่โอนเข้ามาตรง ๆ (ต้องผ่าน depositPayment เท่านั้น)
    receive() external payable {
        revert("Use depositPayment");
    }
}
