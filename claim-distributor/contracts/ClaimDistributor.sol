// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Distributes one ERC20 token through independently funded Merkle distributions.
/// @dev Leaves use OpenZeppelin StandardMerkleTree's double hash of (index, account, amount).
contract ClaimDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Distribution {
        bytes32 merkleRoot;
        uint256 remainingAmount;
        uint256 claimedCount;
    }

    struct ClaimRequest {
        bytes32 distributionId;
        uint256 index;
        uint256 amount;
        bytes32[] merkleProof;
    }

    error InvalidToken();
    error OnlyPublisher();
    error OnlyPendingPublisher();
    error InvalidPublisher();
    error OnlyAdmin();
    error InvalidAdmin();
    error EmergencyStopped();
    error InvalidDistributionId();
    error InvalidMerkleRoot();
    error DistributionExists();
    error DistributionNotFound();
    error DistributionCancelled();
    error AlreadyClaimed();
    error InvalidProof();
    error InvalidRecipient();
    error InvalidAmount();
    error EmptyBatch();
    error InsufficientDistributionBalance();
    error NoRemainingBalance();
    error OutstandingBalance();
    error UnsupportedTokenBehavior();

    event DistributionCreated(bytes32 indexed distributionId, bytes32 indexed merkleRoot, uint256 fundingAmount);
    event PublisherTransferStarted(address indexed previousPublisher, address indexed newPublisher);
    event PublisherTransferCancelled(address indexed publisher, address indexed cancelledPublisher);
    event PublisherTransferred(address indexed previousPublisher, address indexed newPublisher);
    event EmergencyStopActivated(address indexed admin);
    event EmergencyWithdrawn(address indexed admin, address indexed recipient, uint256 amount);
    event DistributionCancellation(
        bytes32 indexed distributionId, address indexed admin, address indexed recipient, uint256 amount
    );
    event AdminRenounced(address indexed previousAdmin);
    event Claimed(
        bytes32 indexed distributionId,
        uint256 indexed index,
        address indexed account,
        address recipient,
        uint256 amount,
        address caller
    );

    IERC20 public immutable token;
    address public publisher;
    address public admin;
    bool public emergencyStopped;
    mapping(bytes32 distributionId => Distribution) public distributions;
    mapping(bytes32 distributionId => bool) public cancelledDistributions;
    mapping(bytes32 distributionId => mapping(uint256 wordIndex => uint256 word)) private _claimedBitmap;
    address public pendingPublisher;

    constructor(IERC20 token_, address initialPublisher, address initialAdmin) {
        if (address(token_) == address(0)) revert InvalidToken();
        if (initialPublisher == address(0)) revert InvalidPublisher();
        if (initialAdmin == address(0)) revert InvalidAdmin();

        token = token_;
        publisher = initialPublisher;
        admin = initialAdmin;
    }

    /// @notice Fund a new distribution and make its Merkle root immutable.
    function createDistribution(bytes32 distributionId, bytes32 merkleRoot, uint256 fundingAmount)
        external
        nonReentrant
    {
        if (msg.sender != publisher) revert OnlyPublisher();
        if (emergencyStopped) revert EmergencyStopped();
        if (distributionId == bytes32(0)) revert InvalidDistributionId();
        if (merkleRoot == bytes32(0)) revert InvalidMerkleRoot();
        if (fundingAmount == 0) revert InvalidAmount();
        if (distributions[distributionId].merkleRoot != bytes32(0)) revert DistributionExists();

        distributions[distributionId] =
            Distribution({merkleRoot: merkleRoot, remainingAmount: fundingAmount, claimedCount: 0});
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), fundingAmount);
        uint256 balanceAfter = token.balanceOf(address(this));
        if (balanceAfter < balanceBefore || balanceAfter - balanceBefore != fundingAmount) {
            revert UnsupportedTokenBehavior();
        }

        emit DistributionCreated(distributionId, merkleRoot, fundingAmount);
    }

    /// @notice Nominate a publisher; the current publisher retains authority until acceptance.
    function transferPublisher(address newPublisher) external {
        if (msg.sender != publisher) revert OnlyPublisher();
        if (newPublisher == address(0) || newPublisher == address(this)) revert InvalidPublisher();

        pendingPublisher = newPublisher;
        emit PublisherTransferStarted(msg.sender, newPublisher);
    }

    /// @notice Cancel a pending nomination without changing the current publisher.
    function cancelPublisherTransfer() external {
        if (msg.sender != publisher) revert OnlyPublisher();

        address cancelledPublisher = pendingPublisher;
        pendingPublisher = address(0);
        emit PublisherTransferCancelled(msg.sender, cancelledPublisher);
    }

    /// @notice Accept the publisher role from the nominated address.
    function acceptPublisher() external {
        if (msg.sender != pendingPublisher) revert OnlyPendingPublisher();

        address previousPublisher = publisher;
        publisher = msg.sender;
        pendingPublisher = address(0);
        emit PublisherTransferred(previousPublisher, msg.sender);
    }

    /// @notice Permanently stop creation and claims without relying on a token transfer.
    function emergencyStop() external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (emergencyStopped) revert EmergencyStopped();

        emergencyStopped = true;
        emit EmergencyStopActivated(msg.sender);
    }

    /// @notice Permanently stop creation and claims, then withdraw all currently held tokens.
    /// @dev The current admin may call again to recover tokens sent here after the first withdrawal.
    function emergencyWithdraw(address recipient) external nonReentrant {
        if (msg.sender != admin) revert OnlyAdmin();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();

        emergencyStopped = true;
        uint256 amount = token.balanceOf(address(this));
        if (amount != 0) token.safeTransfer(recipient, amount);
        emit EmergencyWithdrawn(msg.sender, recipient, amount);
    }

    /// @notice Permanently cancel one distribution and withdraw only its unclaimed balance.
    /// @dev Other distributions remain active unless a separate global stop has been triggered.
    function cancelDistribution(bytes32 distributionId, address recipient) external nonReentrant {
        if (msg.sender != admin) revert OnlyAdmin();
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();

        Distribution storage distribution = distributions[distributionId];
        if (distribution.merkleRoot == bytes32(0)) revert DistributionNotFound();
        if (cancelledDistributions[distributionId]) revert DistributionCancelled();

        uint256 amount = distribution.remainingAmount;
        if (amount == 0) revert NoRemainingBalance();
        cancelledDistributions[distributionId] = true;
        distribution.remainingAmount = 0;
        token.safeTransfer(recipient, amount);
        emit DistributionCancellation(distributionId, msg.sender, recipient, amount);
    }

    /// @notice Permanently discard the emergency role without affecting the publisher.
    function renounceAdmin() external {
        if (msg.sender != admin) revert OnlyAdmin();
        if (emergencyStopped && token.balanceOf(address(this)) != 0) {
            revert OutstandingBalance();
        }

        address previousAdmin = admin;
        admin = address(0);
        emit AdminRenounced(previousAdmin);
    }

    /// @notice Claim the caller's allocation to any nonzero recipient.
    function claim(
        bytes32 distributionId,
        uint256 index,
        address recipient,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        _consumeClaim(distributionId, index, msg.sender, recipient, amount, merkleProof);
        token.safeTransfer(recipient, amount);
    }

    /// @notice Claim for another account, sending tokens only to that account.
    function claimFor(
        bytes32 distributionId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external nonReentrant {
        if (account == address(0) || account == address(this)) revert InvalidRecipient();
        _consumeClaim(distributionId, index, account, account, amount, merkleProof);
        token.safeTransfer(account, amount);
    }

    /// @notice Claim the caller's allocations, possibly from several distributions, in one transfer.
    function claimBatch(address recipient, ClaimRequest[] calldata requests) external nonReentrant {
        if (recipient == address(0) || recipient == address(this)) revert InvalidRecipient();
        if (requests.length == 0) revert EmptyBatch();

        uint256 totalAmount;
        for (uint256 i = 0; i < requests.length; ++i) {
            ClaimRequest calldata request = requests[i];
            _consumeClaim(
                request.distributionId, request.index, msg.sender, recipient, request.amount, request.merkleProof
            );
            totalAmount += request.amount;
        }
        token.safeTransfer(recipient, totalAmount);
    }

    /// @notice Claim another account's allocations, sending one transfer to that account.
    function claimForBatch(address account, ClaimRequest[] calldata requests) external nonReentrant {
        if (account == address(0) || account == address(this)) revert InvalidRecipient();
        if (requests.length == 0) revert EmptyBatch();

        uint256 totalAmount;
        for (uint256 i = 0; i < requests.length; ++i) {
            ClaimRequest calldata request = requests[i];
            _consumeClaim(request.distributionId, request.index, account, account, request.amount, request.merkleProof);
            totalAmount += request.amount;
        }
        token.safeTransfer(account, totalAmount);
    }

    function isClaimed(bytes32 distributionId, uint256 index) public view returns (bool) {
        uint256 word = _claimedBitmap[distributionId][index >> 8];
        uint256 mask = uint256(1) << (index & 255);
        return word & mask != 0;
    }

    function _consumeClaim(
        bytes32 distributionId,
        uint256 index,
        address account,
        address recipient,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) private {
        if (emergencyStopped) revert EmergencyStopped();

        Distribution storage distribution = distributions[distributionId];
        if (distribution.merkleRoot == bytes32(0)) revert DistributionNotFound();
        if (cancelledDistributions[distributionId]) revert DistributionCancelled();
        if (isClaimed(distributionId, index)) revert AlreadyClaimed();
        if (amount == 0) revert InvalidAmount();

        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verifyCalldata(merkleProof, distribution.merkleRoot, leaf)) {
            revert InvalidProof();
        }
        if (amount > distribution.remainingAmount) revert InsufficientDistributionBalance();

        _claimedBitmap[distributionId][index >> 8] |= uint256(1) << (index & 255);
        distribution.remainingAmount -= amount;
        distribution.claimedCount += 1;
        emit Claimed(distributionId, index, account, recipient, amount, msg.sender);
    }
}
