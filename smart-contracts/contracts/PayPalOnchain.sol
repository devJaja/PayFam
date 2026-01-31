// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract PayPalOnchain is ReentrancyGuard {
    mapping(address => mapping(address => uint256)) public balances;
    mapping(address => string) public addressToUsername;
    mapping(string => address) public usernameToAddress;
    
    event PaymentSent(address indexed from, address indexed to, address token, uint256 amount);
    event UsernameRegistered(address indexed user, string username);
    event Deposited(address indexed user, address token, uint256 amount);

    function registerUsername(string memory username) external {
        require(bytes(username).length > 0, "Username cannot be empty");
        require(usernameToAddress[username] == address(0), "Username taken");
        require(bytes(addressToUsername[msg.sender]).length == 0, "User already has username");
        
        addressToUsername[msg.sender] = username;
        usernameToAddress[username] = msg.sender;
        
        emit UsernameRegistered(msg.sender, username);
    }

    function deposit(address token, uint256 amount) external nonReentrant {
        require(amount > 0, "Amount must be greater than 0");
        
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender][token] += amount;
        
        emit Deposited(msg.sender, token, amount);
    }

    function sendPayment(address to, address token, uint256 amount) external nonReentrant {
        require(to != address(0), "Invalid recipient");
        require(amount > 0, "Amount must be greater than 0");
        require(balances[msg.sender][token] >= amount, "Insufficient balance");
        
        balances[msg.sender][token] -= amount;
        balances[to][token] += amount;
        
        emit PaymentSent(msg.sender, to, token, amount);
    }
}
