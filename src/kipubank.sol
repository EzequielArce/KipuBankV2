// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

// Imports from OpenZeppelin and Chainlink
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @author Ezequiel Arce
/// @notice Allows users to deposit and withdraw ETH or ERC20 tokens.
/// @dev Internally tracks all balances in USD value using Chainlink price feeds.
contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint16 constant ORACLE_HEARTBEAT = 3600; // 1 hour price feed validity window

    /*//////////////////////////////////////////////////////////////
                               STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice User vaults - tracks USD-equivalent balances per user and token
    mapping(address user => mapping(address token => uint256)) private s_vaults;

    /// @notice Global bank capacity (in USD-equivalent units)
    uint256 public s_bankCap;

    /// @notice Maximum amount (in USD) a user can withdraw in one transaction
    uint256 public s_withdrawalThreshold;

    /// @notice Total USD-equivalent deposited in the bank
    uint256 public s_depositTotal;

    /// @notice Number of deposits and withdrawals (for tracking statistics)
    uint256 private s_depositCount;
    uint256 private s_withdrawCount;

    /// @notice Mapping between tokens and their corresponding Chainlink price feeds
    mapping(address => AggregatorV3Interface) public s_priceFeeds;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event KipuBank_DepositAccepted(address indexed user, address indexed token, uint256 amount);
    event KipuBank_WithdrawalAccepted(address indexed user, address indexed token, uint256 amount);
    event KipuBank_ChainlinkFeedUpdated(address token,address indexed feed);
    event KipuBank_BankCapacityUpdated(uint256 newCapacity);
    event KipuBank_WithdrawalThresholdUpdated(uint256 newThreshold);
    event KipuBank_AdminRoleGranted(address newAdmin);
    event KipuBank_AdminRoleRevoked(address removedAdmin);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error KipuBank_InvalidAmount(address user, uint256 amount);
    error KipuBank_DepositRejected(address user, uint256 amount);
    error KipuBank_WithdrawalRejected(address user, address token, uint256 amount);
    error KipuBank_TransferFailed(bytes data);
    error KipuBank_InitializationFailed(uint256 bankCap, uint256 withdrawalThreshold);
    error KipuBank_InvalidBankCapacity(address admin, uint256 newCapacity);
    error KipuBank_ETHAmountMismatch(address user, uint256 amount);
    error KipuBank_OracleCompromised();
    error KipuBank_StalePrice();

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Ensures the provided amount is greater than zero
    modifier onlyAmountsGreaterThanZero(uint256 amount) {
        if (amount == 0) revert KipuBank_InvalidAmount(msg.sender, amount);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _bankCap The global maximum USD-equivalent the contract can hold
    /// @param _withdrawalThreshold The per-transaction USD withdrawal limit
    constructor(uint256 _bankCap, uint256 _withdrawalThreshold) {
        if (_bankCap == 0 || _withdrawalThreshold == 0 || _bankCap < _withdrawalThreshold)
            revert KipuBank_InitializationFailed(_bankCap, _withdrawalThreshold);

        s_bankCap = _bankCap;
        s_withdrawalThreshold = _withdrawalThreshold;

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Accepts direct ETH deposits
    receive() external payable onlyAmountsGreaterThanZero(msg.value) {
        _deposit(address(0), msg.sender, msg.value);
    }

    /// @notice Fallback to accept ETH as deposit
    fallback() external payable onlyAmountsGreaterThanZero(msg.value) {
        _deposit(address(0), msg.sender, msg.value);
    }

    /// @notice Deposit ETH or ERC20 tokens
    /// @param token Address of the token (use address(0) for ETH)
    /// @param amount Amount to deposit
    function deposit(address token, uint256 amount)
        external
        payable
        nonReentrant
        onlyAmountsGreaterThanZero(amount)
    {
        if (token == address(0) && msg.value != amount)
            revert KipuBank_ETHAmountMismatch(msg.sender, msg.value);

        _deposit(token, msg.sender, amount);
    }

    /// @notice Withdraws up to the user's USD-equivalent balance
    /// @param token The token to withdraw (use address(0) for ETH)
    /// @param _amount Amount of the token to withdraw
    function withdraw(address token, uint256 _amount)
        external
        nonReentrant
        onlyAmountsGreaterThanZero(_amount)
    {
        uint256 usdEquivalent = _toUSDValue(token, _amount);

        // Ensure withdrawal does not exceed limits
        if (
            usdEquivalent > s_withdrawalThreshold ||
            usdEquivalent > s_vaults[msg.sender][token]
        ) {
            revert KipuBank_WithdrawalRejected(msg.sender, token, _amount);
        }

        // Update balances
        s_vaults[msg.sender][token] -= usdEquivalent;
        s_withdrawCount += 1;
        s_depositTotal -= usdEquivalent;

        // Transfer tokens or ETH
        if (token == address(0)) {
            _transferEth(_amount);
        } else {
            IERC20(token).safeTransfer(msg.sender, _amount);
        }

        emit KipuBank_WithdrawalAccepted(msg.sender, token, _amount);
    }

    /// @notice Adds a new Chainlink price feed
    function addFeed(address token, address feed) external onlyRole(ADMIN_ROLE) {
        s_priceFeeds[token] = AggregatorV3Interface(feed);
        emit KipuBank_ChainlinkFeedUpdated(token,feed);
    }

    /// @notice Updates the bank's total USD capacity
    function setBankCapacity(uint256 newCapacity) external onlyRole(ADMIN_ROLE) {
        if (newCapacity <= s_depositTotal)
            revert KipuBank_InvalidBankCapacity(msg.sender, newCapacity);
        s_bankCap = newCapacity;
        emit KipuBank_BankCapacityUpdated(newCapacity);
    }

    /// @notice Updates the maximum USD withdrawal limit
    function setWithdrawalThreshold(uint256 newThreshold)
        external
        onlyRole(ADMIN_ROLE)
        onlyAmountsGreaterThanZero(newThreshold)
    {
        s_withdrawalThreshold = newThreshold;
        emit KipuBank_WithdrawalThresholdUpdated(newThreshold);
    }

    /// @notice Grants the ADMIN role
    function grantAdminRole(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ADMIN_ROLE, newAdmin);
        emit KipuBank_AdminRoleGranted(newAdmin);
    }

    /// @notice Revokes the ADMIN role
    function revokeAdminRole(address removeThisAdmin)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        _revokeRole(ADMIN_ROLE, removeThisAdmin);
        emit KipuBank_AdminRoleRevoked(removeThisAdmin);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the user's USD-equivalent vault balance for a token
    function viewBalanceSpecificToken(address token) external view returns (uint256) {
        return s_vaults[msg.sender][token];
    }

    function viewDepositCount() external view returns (uint256) {
        return s_depositCount;
    }

    function viewWithdrawCount() external view returns (uint256) {
        return s_withdrawCount;
    }

    function viewWithdrawalThreshold() external view returns (uint256) {
        return s_withdrawalThreshold;
    }

    function viewBankCapacity() external view returns (uint256) {
        return s_bankCap;
    }

    /*//////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal function to deposit ETH or tokens and record USD-equivalent value
    function _deposit(address token, address user, uint256 amount) private {
        uint256 usdEquivalent = _toUSDValue(token, amount);

        if (s_depositTotal + usdEquivalent > s_bankCap)
            revert KipuBank_DepositRejected(user, amount);

        if (token != address(0)) {
            IERC20(token).safeTransferFrom(user, address(this), amount);
        }

        s_vaults[user][token] += usdEquivalent;
        s_depositTotal += usdEquivalent;
        s_depositCount += 1;

        emit KipuBank_DepositAccepted(user, token, amount);
    }

    /// @dev Retrieves the USD price of a token using Chainlink
    function _getUSDPrice(address token)
        internal
        view
        returns (uint256 price, uint8 decimals)
    {
        AggregatorV3Interface feed = s_priceFeeds[token];
        if (address(feed) == address(0)) revert KipuBank_OracleCompromised();

        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        if (answer <= 0 || updatedAt == 0) revert KipuBank_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT)
            revert KipuBank_StalePrice();

        price = uint256(answer);
        decimals = feed.decimals();
    }

    /// @dev Converts a token amount to its USD-equivalent using Chainlink
    function _toUSDValue(address token, uint256 amount)
        internal
        view
        returns (uint256 usdValue)
    {
        (uint256 price, uint8 priceDecimals) = _getUSDPrice(token);
        uint8 tokenDecimals = token == address(0)
            ? 18
            : IERC20Metadata(token).decimals();

        // USD value = amount * price / 10^(priceDecimals + tokenDecimals - 18)
        usdValue = (amount * price) / (10 ** (priceDecimals + tokenDecimals - 18));
    }

    /// @dev Secure ETH transfer helper
    function _transferEth(uint256 _amount) private {
        (bool success, bytes memory data) = msg.sender.call{value: _amount}("");
        if (!success) revert KipuBank_TransferFailed(data);
    }
}
