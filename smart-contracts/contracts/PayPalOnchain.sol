// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract PayPalOnchain is ReentrancyGuard, Ownable {
    string public constant VERSION = "1.0.0";
    uint256 public constant PLATFORM_FEE = 25;
    uint256 public constant FEE_DENOMINATOR = 10000;
    
    address public feeCollector;
    uint256 public transactionCounter;
    
    mapping(address => mapping(address => uint256)) public balances;
    mapping(address => string) public addressToUsername;
    mapping(string => address) public usernameToAddress;
    mapping(address => Merchant) public merchants;
    mapping(uint256 => Invoice) public invoices;
    mapping(uint256 => Subscription) public subscriptions;
    mapping(uint256 => Dispute) public disputes;
    mapping(uint256 => Transaction) public transactions;
    
    uint256 public invoiceCounter;
    uint256 public subscriptionCounter;
    uint256 public disputeCounter;
    
    struct Merchant {
        bool registered;
        string name;
        string description;
        uint256 totalVolume;
        uint256 transactionCount;
    }
    
    struct Invoice {
        address merchant;
        address customer;
        address token;
        uint256 amount;
        uint256 dueDate;
        bool paid;
        string description;
    }
    
    struct Subscription {
        address merchant;
        address subscriber;
        address token;
        uint256 amount;
        uint256 interval;
        uint256 nextCharge;
        bool active;
    }
    
    struct Dispute {
        uint256 transactionId;
        address plaintiff;
        address defendant;
        string reason;
        bool resolved;
        bool refunded;
    }
    
    struct Transaction {
        address from;
        address to;
        address token;
        uint256 amount;
        uint256 timestamp;
        string txType;
    }
    
    event PaymentSent(address indexed from, address indexed to, address token, uint256 amount);
    event UsernameRegistered(address indexed user, string username);
    event Deposited(address indexed user, address token, uint256 amount);
    event Withdrawn(address indexed user, address token, uint256 amount);
    event MerchantRegistered(address indexed merchant, string name);
    event InvoiceCreated(uint256 indexed invoiceId, address merchant, address customer);
    event InvoicePaid(uint256 indexed invoiceId);
    event SubscriptionCreated(uint256 indexed subscriptionId, address merchant, address subscriber);
    event SubscriptionCharged(uint256 indexed subscriptionId, uint256 amount);
    event SubscriptionCanceled(uint256 indexed subscriptionId);
    event DisputeRaised(uint256 indexed disputeId, uint256 transactionId);
    event DisputeResolved(uint256 indexed disputeId, bool refunded);
    
    constructor(address _feeCollector) Ownable(msg.sender) {
        feeCollector = _feeCollector;
    }

    // 1. Username Functions
    function registerUsername(string memory username) external {
        require(bytes(username).length > 0, "Username cannot be empty");
        require(usernameToAddress[username] == address(0), "Username taken");
        require(bytes(addressToUsername[msg.sender]).length == 0, "User already has username");
        
        addressToUsername[msg.sender] = username;
        usernameToAddress[username] = msg.sender;
        
        emit UsernameRegistered(msg.sender, username);
    }

    // 2. Balance Functions
    function deposit(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender][token] += amount;
        
        emit Deposited(msg.sender, token, amount);
    }

    function withdraw(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender][token] >= amount, "Insufficient balance");
        
        balances[msg.sender][token] -= amount;
        IERC20(token).transfer(msg.sender, amount);
        
        emit Withdrawn(msg.sender, token, amount);
    }

    function getBalance(address user, address token) external view returns (uint256) {
        return balances[user][token];
    }

    // 3. P2P Payment Functions
    function sendPayment(address to, address token, uint256 amount) external nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender][token] >= amount, "Insufficient balance");
        
        balances[msg.sender][token] -= amount;
        balances[to][token] += amount;
        
        _recordTransaction(msg.sender, to, token, amount, "P2P");
        emit PaymentSent(msg.sender, to, token, amount);
    }

    function sendPaymentByUsername(string memory username, address token, uint256 amount) external nonReentrant {
        address to = usernameToAddress[username];
        require(to != address(0), "Username not found");
        require(amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender][token] >= amount, "Insufficient balance");
        
        balances[msg.sender][token] -= amount;
        balances[to][token] += amount;
        
        _recordTransaction(msg.sender, to, token, amount, "P2P_USERNAME");
        emit PaymentSent(msg.sender, to, token, amount);
    }

    // 4. Merchant Functions
    function registerMerchant(string memory name, string memory description) external {
        require(!merchants[msg.sender].registered, "Already registered as merchant");
        require(bytes(name).length > 0, "Name cannot be empty");
        
        merchants[msg.sender] = Merchant(true, name, description, 0, 0);
        emit MerchantRegistered(msg.sender, name);
    }

    function processPayment(address customer, address token, uint256 amount) external nonReentrant {
        require(merchants[msg.sender].registered, "Not a registered merchant");
        require(balances[customer][token] >= amount, "Customer insufficient balance");
        
        uint256 fee = (amount * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 merchantAmount = amount - fee;
        
        balances[customer][token] -= amount;
        balances[msg.sender][token] += merchantAmount;
        balances[feeCollector][token] += fee;
        
        merchants[msg.sender].totalVolume += amount;
        merchants[msg.sender].transactionCount++;
        
        _recordTransaction(customer, msg.sender, token, amount, "MERCHANT");
        emit PaymentSent(customer, msg.sender, token, amount);
    }

    function getMerchant(address merchant) external view returns (Merchant memory) {
        return merchants[merchant];
    }

    // 5. Invoice Functions
    function createInvoice(address customer, address token, uint256 amount, uint256 dueDate, string memory description) external {
        require(merchants[msg.sender].registered, "Only merchants can create invoices");
        require(customer != address(0), "Invalid customer");
        require(amount > 0, "Amount must be greater than 0");
        
        invoiceCounter++;
        invoices[invoiceCounter] = Invoice(msg.sender, customer, token, amount, dueDate, false, description);
        
        emit InvoiceCreated(invoiceCounter, msg.sender, customer);
    }

    function payInvoice(uint256 invoiceId) external nonReentrant {
        Invoice storage invoice = invoices[invoiceId];
        require(invoice.customer == msg.sender, "Not your invoice");
        require(!invoice.paid, "Invoice already paid");
        require(balances[msg.sender][invoice.token] >= invoice.amount, "Insufficient balance");
        
        uint256 fee = (invoice.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 merchantAmount = invoice.amount - fee;
        
        balances[msg.sender][invoice.token] -= invoice.amount;
        balances[invoice.merchant][invoice.token] += merchantAmount;
        balances[feeCollector][invoice.token] += fee;
        invoice.paid = true;
        
        _recordTransaction(msg.sender, invoice.merchant, invoice.token, invoice.amount, "INVOICE");
        emit InvoicePaid(invoiceId);
        emit PaymentSent(msg.sender, invoice.merchant, invoice.token, invoice.amount);
    }

    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        return invoices[invoiceId];
    }

    // 6. Subscription Functions
    function createSubscription(address subscriber, address token, uint256 amount, uint256 interval) external {
        require(merchants[msg.sender].registered, "Only merchants can create subscriptions");
        require(subscriber != address(0), "Invalid subscriber");
        require(amount > 0, "Amount must be greater than 0");
        
        subscriptionCounter++;
        subscriptions[subscriptionCounter] = Subscription(
            msg.sender, subscriber, token, amount, interval, block.timestamp + interval, true
        );
        
        emit SubscriptionCreated(subscriptionCounter, msg.sender, subscriber);
    }

    function chargeSubscription(uint256 subscriptionId) external nonReentrant {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.merchant == msg.sender, "Not your subscription");
        require(sub.active, "Subscription not active");
        require(block.timestamp >= sub.nextCharge, "Not time to charge yet");
        require(balances[sub.subscriber][sub.token] >= sub.amount, "Subscriber insufficient balance");
        
        uint256 fee = (sub.amount * PLATFORM_FEE) / FEE_DENOMINATOR;
        uint256 merchantAmount = sub.amount - fee;
        
        balances[sub.subscriber][sub.token] -= sub.amount;
        balances[sub.merchant][sub.token] += merchantAmount;
        balances[feeCollector][sub.token] += fee;
        sub.nextCharge = block.timestamp + sub.interval;
        
        _recordTransaction(sub.subscriber, sub.merchant, sub.token, sub.amount, "SUBSCRIPTION");
        emit SubscriptionCharged(subscriptionId, sub.amount);
        emit PaymentSent(sub.subscriber, sub.merchant, sub.token, sub.amount);
    }

    function cancelSubscription(uint256 subscriptionId) external {
        Subscription storage sub = subscriptions[subscriptionId];
        require(sub.subscriber == msg.sender || sub.merchant == msg.sender, "Not authorized");
        require(sub.active, "Subscription already canceled");
        
        sub.active = false;
        emit SubscriptionCanceled(subscriptionId);
    }

    function getSubscription(uint256 subscriptionId) external view returns (Subscription memory) {
        return subscriptions[subscriptionId];
    }

    // 7. Dispute Functions
    function raiseDispute(uint256 transactionId, string memory reason) external {
        Transaction memory txn = transactions[transactionId];
        require(txn.from == msg.sender || txn.to == msg.sender, "Not involved in transaction");
        require(bytes(reason).length > 0, "Reason cannot be empty");
        
        disputeCounter++;
        disputes[disputeCounter] = Dispute(transactionId, msg.sender, 
            txn.from == msg.sender ? txn.to : txn.from, reason, false, false);
        
        emit DisputeRaised(disputeCounter, transactionId);
    }

    function resolveDispute(uint256 disputeId, bool refund) external onlyOwner {
        Dispute storage dispute = disputes[disputeId];
        require(!dispute.resolved, "Dispute already resolved");
        
        dispute.resolved = true;
        dispute.refunded = refund;
        
        emit DisputeResolved(disputeId, refund);
    }

    // 8. Admin Functions
    function setFeeCollector(address _feeCollector) external onlyOwner {
        require(_feeCollector != address(0), "Invalid fee collector");
        feeCollector = _feeCollector;
    }

    function transferOwnership(address newOwner) public override onlyOwner {
        require(newOwner != address(0), "Invalid new owner");
        super.transferOwnership(newOwner);
    }

    // 9. View Functions
    function getTransaction(uint256 transactionId) external view returns (Transaction memory) {
        return transactions[transactionId];
    }

    // Internal helper function
    function _recordTransaction(address from, address to, address token, uint256 amount, string memory txType) internal {
        transactionCounter++;
        transactions[transactionCounter] = Transaction(from, to, token, amount, block.timestamp, txType);
    }
}
