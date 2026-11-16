// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../contracts/ClaimDistributor.sol";

contract ClaimDistributorTestToken is ERC20 {
    constructor() ERC20("Test Token", "TEST") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ClaimDistributorFeeToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        uint256 fee = from != address(0) && to != address(0) ? amount / 100 : 0;
        super._update(from, to, amount - fee);
        if (fee != 0) super._update(from, address(0xfee), fee);
    }
}

contract ClaimDistributorBlockingToken is ERC20 {
    error TransfersBlocked();

    bool public transfersBlocked;

    constructor() ERC20("Blocking Token", "BLOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTransfersBlocked(bool blocked) external {
        transfersBlocked = blocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (transfersBlocked) revert TransfersBlocked();
        return super.transfer(to, amount);
    }
}

contract ClaimDistributorReentrantToken is ERC20 {
    ClaimDistributor public distributor;
    bytes32 public distributionId;
    address public account;
    uint256 public claimAmount;
    bool public attackEnabled;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(ClaimDistributor distributor_, bytes32 distributionId_, address account_, uint256 claimAmount_)
        external
    {
        distributor = distributor_;
        distributionId = distributionId_;
        account = account_;
        claimAmount = claimAmount_;
        attackEnabled = true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attackEnabled && msg.sender == address(distributor)) {
            attackEnabled = false;
            reentryAttempted = true;
            bytes32[] memory proof = new bytes32[](0);
            (reentrySucceeded,) = address(distributor)
                .call(abi.encodeCall(ClaimDistributor.claimFor, (distributionId, 0, account, claimAmount, proof)));
        }
        return super.transfer(to, amount);
    }
}

contract ClaimDistributorPublisherWallet {
    address private immutable controller = msg.sender;

    function accept(ClaimDistributor distributor) external {
        require(msg.sender == controller, "Only controller");
        distributor.acceptPublisher();
    }
}

contract ClaimDistributorTest is Test {
    bytes32 internal constant DISTRIBUTION_A = keccak256("distribution-a");
    bytes32 internal constant DISTRIBUTION_B = keccak256("distribution-b");
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    ClaimDistributorTestToken internal token;
    ClaimDistributor internal distributor;

    address internal publisher;
    address internal admin;
    address internal alice;
    address internal bob;
    address internal recipient;
    address internal outsider;

    function setUp() public {
        publisher = makeAddr("publisher");
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        recipient = makeAddr("recipient");
        outsider = makeAddr("outsider");

        token = new ClaimDistributorTestToken();
        distributor = new ClaimDistributor(IERC20(address(token)), publisher, admin);
        token.mint(publisher, 1_000 ether);
        vm.prank(publisher);
        token.approve(address(distributor), type(uint256).max);
    }

    function testConstructorRejectsZeroTokenPublisherAndAdmin() public {
        vm.expectRevert(ClaimDistributor.InvalidToken.selector);
        new ClaimDistributor(IERC20(address(0)), publisher, admin);

        vm.expectRevert(ClaimDistributor.InvalidPublisher.selector);
        new ClaimDistributor(IERC20(address(token)), address(0), admin);

        vm.expectRevert(ClaimDistributor.InvalidAdmin.selector);
        new ClaimDistributor(IERC20(address(token)), publisher, address(0));
    }

    function testCreateDistributionPullsExactBudgetAndStoresMetadata() public {
        bytes32 root = _root(_leaf(0, alice, 40 ether), _leaf(1, bob, 60 ether));
        uint256 publisherBefore = token.balanceOf(publisher);

        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, root, 100 ether);

        assertEq(token.balanceOf(publisher), publisherBefore - 100 ether);
        assertEq(token.balanceOf(address(distributor)), 100 ether);
        (bytes32 storedRoot, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(storedRoot, root);
        assertEq(remainingAmount, 100 ether);
        assertEq(claimedCount, 0);
    }

    function testCreateDistributionRejectsUnauthorizedAndDuplicateId() public {
        bytes32 root = _leaf(0, alice, 50 ether);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyPublisher.selector);
        distributor.createDistribution(DISTRIBUTION_A, root, 50 ether);

        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, root, 50 ether);
        uint256 balanceBefore = token.balanceOf(address(distributor));

        vm.prank(publisher);
        vm.expectRevert(ClaimDistributor.DistributionExists.selector);
        distributor.createDistribution(DISTRIBUTION_A, root, 50 ether);
        assertEq(token.balanceOf(address(distributor)), balanceBefore);
    }

    function testCreateDistributionRejectsFeeOnTransferFunding() public {
        ClaimDistributorFeeToken feeToken = new ClaimDistributorFeeToken();
        ClaimDistributor feeDistributor = new ClaimDistributor(IERC20(address(feeToken)), publisher, admin);
        feeToken.mint(publisher, 100 ether);
        vm.startPrank(publisher);
        feeToken.approve(address(feeDistributor), 100 ether);
        vm.expectRevert(ClaimDistributor.UnsupportedTokenBehavior.selector);
        feeDistributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 100 ether), 100 ether);
        vm.stopPrank();

        assertEq(feeToken.balanceOf(publisher), 100 ether);
        assertEq(feeToken.balanceOf(address(feeDistributor)), 0);
    }

    function testCreateDistributionRejectsInvalidParameters() public {
        bytes32 root = _leaf(0, alice, 50 ether);

        vm.startPrank(publisher);
        vm.expectRevert(ClaimDistributor.InvalidDistributionId.selector);
        distributor.createDistribution(bytes32(0), root, 50 ether);

        vm.expectRevert(ClaimDistributor.InvalidMerkleRoot.selector);
        distributor.createDistribution(DISTRIBUTION_A, bytes32(0), 50 ether);

        vm.expectRevert(ClaimDistributor.InvalidAmount.selector);
        distributor.createDistribution(DISTRIBUTION_A, root, 0);
        vm.stopPrank();
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function testClaimPaysChosenRecipientAndCannotBeClaimedTwice() public {
        (, bytes32 bobLeaf) = _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, bob, 60 ether);
        bytes32[] memory aliceProof = _proof(bobLeaf);

        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 0, recipient, 40 ether, aliceProof);

        assertEq(token.balanceOf(recipient), 40 ether);
        assertEq(token.balanceOf(alice), 0);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 1));
        (, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 60 ether);
        assertEq(claimedCount, 1);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.AlreadyClaimed.selector);
        distributor.claim(DISTRIBUTION_A, 0, recipient, 40 ether, aliceProof);
        assertEq(token.balanceOf(recipient), 40 ether);
    }

    function testAcceptsProofsGeneratedByOpenZeppelinStandardMerkleTree() public {
        // Generated with @openzeppelin/merkle-tree 1.0.8 using
        // StandardMerkleTree.of(values, ["uint256", "address", "uint256"]).
        bytes32 root = 0x8a4bf6c9acd1f03d46b0af39f714dd9dd9e193c83c5cfdc184b05d6c32f4aabc;
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, root, 60);

        bytes32[] memory firstProof = new bytes32[](1);
        firstProof[0] = 0x3b64f0356b1ab33d7b3dfee54caed9d84fa1283648673d0e99013bdc15e40fd0;
        distributor.claimFor(DISTRIBUTION_A, 0, address(0xa11ce), 10, firstProof);

        bytes32[] memory secondProof = new bytes32[](2);
        secondProof[0] = 0x5dbc7e4d2910c57db319386171b7cca9c60e0520c1c7fea5fccd46c1d171ef9b;
        secondProof[1] = 0xca3ebce216f649e3e48a93e8bb670473f4ce2e46afde1b451082e48155c6f4d6;
        distributor.claimFor(DISTRIBUTION_A, 1, address(0xb0b), 20, secondProof);

        bytes32[] memory thirdProof = new bytes32[](2);
        thirdProof[0] = 0x8c7ecd1dbad2168bb7140c753d25c2f71caec8de60e673950bfd11d8a75c4769;
        thirdProof[1] = 0xca3ebce216f649e3e48a93e8bb670473f4ce2e46afde1b451082e48155c6f4d6;
        distributor.claimFor(DISTRIBUTION_A, 2, address(0xcafe), 30, thirdProof);

        assertEq(token.balanceOf(address(0xa11ce)), 10);
        assertEq(token.balanceOf(address(0xb0b)), 20);
        assertEq(token.balanceOf(address(0xcafe)), 30);
        (, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 0);
        assertEq(claimedCount, 3);
    }

    function testClaimForPaysProvenAccountNotCaller() public {
        (, bytes32 bobLeaf) = _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, bob, 60 ether);

        vm.prank(outsider);
        distributor.claimFor(DISTRIBUTION_A, 0, alice, 40 ether, _proof(bobLeaf));

        assertEq(token.balanceOf(alice), 40 ether);
        assertEq(token.balanceOf(outsider), 0);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claimFor(DISTRIBUTION_A, 1, recipient, 60 ether, _proof(_leaf(0, alice, 40 ether)));
        assertEq(token.balanceOf(recipient), 0);
    }

    function testClaimRejectsWrongAmountIndexAccountAndProof() public {
        (bytes32 aliceLeaf, bytes32 bobLeaf) =
            _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, bob, 60 ether);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claim(DISTRIBUTION_A, 0, alice, 41 ether, _proof(bobLeaf));

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claim(DISTRIBUTION_A, 1, alice, 60 ether, _proof(aliceLeaf));

        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claim(DISTRIBUTION_A, 0, bob, 40 ether, _proof(bobLeaf));

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claim(DISTRIBUTION_A, 0, alice, 40 ether, _proof(bytes32(uint256(123))));

        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 1));
        assertEq(token.balanceOf(address(distributor)), 100 ether);
    }

    function testClaimsRejectZeroRecipientOrAccountWithoutConsumingLeaf() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);
        bytes32[] memory emptyProof = new bytes32[](0);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claim(DISTRIBUTION_A, 0, address(0), 50 ether, emptyProof);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claim(DISTRIBUTION_A, 0, address(distributor), 50 ether, emptyProof);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimFor(DISTRIBUTION_A, 0, address(0), 50 ether, emptyProof);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimFor(DISTRIBUTION_A, 0, address(distributor), 50 ether, emptyProof);

        ClaimDistributor.ClaimRequest[] memory requests = new ClaimDistributor.ClaimRequest[](1);
        requests[0] = _request(DISTRIBUTION_A, 0, 50 ether, emptyProof);
        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimBatch(address(0), requests);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimBatch(address(distributor), requests);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimForBatch(address(0), requests);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimForBatch(address(distributor), requests);

        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertEq(token.balanceOf(address(distributor)), 50 ether);
    }

    function testSameIndexCanBeClaimedInSeparateDistributions() public {
        vm.startPrank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 30 ether), 30 ether);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, alice, 70 ether), 70 ether);
        vm.stopPrank();

        bytes32[] memory emptyProof = new bytes32[](0);
        vm.startPrank(alice);
        distributor.claim(DISTRIBUTION_A, 0, alice, 30 ether, emptyProof);
        distributor.claim(DISTRIBUTION_B, 0, alice, 70 ether, emptyProof);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 100 ether);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertTrue(distributor.isClaimed(DISTRIBUTION_B, 0));
    }

    function testClaimedBitmapHandlesAdjacentWords() public {
        bytes32 firstLeaf = _leaf(255, alice, 30 ether);
        bytes32 secondLeaf = _leaf(256, bob, 70 ether);
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _root(firstLeaf, secondLeaf), 100 ether);

        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 255, alice, 30 ether, _proof(secondLeaf));
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 255));
        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 256));

        vm.prank(bob);
        distributor.claim(DISTRIBUTION_A, 256, bob, 70 ether, _proof(firstLeaf));
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 256));
    }

    function testClaimCannotExceedDistributionFunding() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 80 ether), 50 ether);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InsufficientDistributionBalance.selector);
        distributor.claim(DISTRIBUTION_A, 0, alice, 80 ether, new bytes32[](0));

        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertEq(token.balanceOf(address(distributor)), 50 ether);
    }

    function testClaimBatchMakesOneTransferForTwoLeaves() public {
        (bytes32 firstLeaf, bytes32 secondLeaf) =
            _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, alice, 60 ether);
        ClaimDistributor.ClaimRequest[] memory requests = new ClaimDistributor.ClaimRequest[](2);
        requests[0] = _request(DISTRIBUTION_A, 0, 40 ether, _proof(secondLeaf));
        requests[1] = _request(DISTRIBUTION_A, 1, 60 ether, _proof(firstLeaf));

        vm.recordLogs();
        vm.prank(alice);
        distributor.claimBatch(recipient, requests);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_outgoingTransferCount(logs, address(token), address(distributor)), 1);
        assertEq(token.balanceOf(recipient), 100 ether);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 1));
        (, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 0);
        assertEq(claimedCount, 2);
    }

    function testClaimBatchIsAtomicWhenLaterRequestIsInvalid() public {
        (bytes32 firstLeaf, bytes32 secondLeaf) =
            _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, alice, 60 ether);
        ClaimDistributor.ClaimRequest[] memory requests = new ClaimDistributor.ClaimRequest[](2);
        requests[0] = _request(DISTRIBUTION_A, 0, 40 ether, _proof(secondLeaf));
        requests[1] = _request(DISTRIBUTION_A, 1, 61 ether, _proof(firstLeaf));

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidProof.selector);
        distributor.claimBatch(recipient, requests);

        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 1));
        assertEq(token.balanceOf(recipient), 0);
        (, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 100 ether);
        assertEq(claimedCount, 0);
    }

    function testClaimForBatchCanSpanDistributionsAndPaysOnlyProvenAccount() public {
        vm.startPrank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 30 ether), 30 ether);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, alice, 70 ether), 70 ether);
        vm.stopPrank();
        bytes32[] memory emptyProof = new bytes32[](0);
        ClaimDistributor.ClaimRequest[] memory requests = new ClaimDistributor.ClaimRequest[](2);
        requests[0] = _request(DISTRIBUTION_A, 0, 30 ether, emptyProof);
        requests[1] = _request(DISTRIBUTION_B, 0, 70 ether, emptyProof);

        vm.recordLogs();
        vm.prank(outsider);
        distributor.claimForBatch(alice, requests);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_outgoingTransferCount(logs, address(token), address(distributor)), 1);
        assertEq(token.balanceOf(alice), 100 ether);
        assertEq(token.balanceOf(outsider), 0);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));
        assertTrue(distributor.isClaimed(DISTRIBUTION_B, 0));
    }

    function testBatchRejectsEmptyRequestsAndZeroRecipient() public {
        ClaimDistributor.ClaimRequest[] memory emptyRequests = new ClaimDistributor.ClaimRequest[](0);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.EmptyBatch.selector);
        distributor.claimBatch(alice, emptyRequests);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimBatch(address(0), emptyRequests);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.EmptyBatch.selector);
        distributor.claimForBatch(alice, emptyRequests);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.claimForBatch(address(0), emptyRequests);
    }

    function testPublisherTransferChangesCreationAuthority() public {
        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyPublisher.selector);
        distributor.transferPublisher(bob);

        vm.expectEmit(true, true, false, true, address(distributor));
        emit ClaimDistributor.PublisherTransferStarted(publisher, bob);
        vm.prank(publisher);
        distributor.transferPublisher(bob);
        assertEq(distributor.publisher(), publisher);
        assertEq(distributor.pendingPublisher(), bob);

        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.OnlyPublisher.selector);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);

        // A pending nomination must not interrupt the current publisher's work.
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, alice, 5 ether), 5 ether);

        vm.expectEmit(true, true, false, true, address(distributor));
        emit ClaimDistributor.PublisherTransferred(publisher, bob);
        vm.prank(bob);
        distributor.acceptPublisher();
        assertEq(distributor.publisher(), bob);
        assertEq(distributor.pendingPublisher(), address(0));
        assertEq(distributor.admin(), admin);

        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.OnlyPendingPublisher.selector);
        distributor.acceptPublisher();

        vm.prank(publisher);
        vm.expectRevert(ClaimDistributor.OnlyPublisher.selector);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);

        token.mint(bob, 10 ether);
        vm.startPrank(bob);
        token.approve(address(distributor), 10 ether);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);
        vm.stopPrank();
        assertEq(token.balanceOf(address(distributor)), 15 ether);
    }

    function testPublisherNominationRejectsInvalidTargetsWithoutLosingPendingTransfer() public {
        vm.startPrank(publisher);
        distributor.transferPublisher(bob);
        vm.expectRevert(ClaimDistributor.InvalidPublisher.selector);
        distributor.transferPublisher(address(0));
        vm.expectRevert(ClaimDistributor.InvalidPublisher.selector);
        distributor.transferPublisher(address(distributor));
        vm.stopPrank();
        assertEq(distributor.publisher(), publisher);
        assertEq(distributor.pendingPublisher(), bob);
    }

    function testOnlyPendingPublisherCanAccept() public {
        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyPendingPublisher.selector);
        distributor.acceptPublisher();

        vm.prank(publisher);
        distributor.transferPublisher(bob);
        address[3] memory unauthorized = [publisher, admin, outsider];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(ClaimDistributor.OnlyPendingPublisher.selector);
            distributor.acceptPublisher();
        }
        assertEq(distributor.publisher(), publisher);
        assertEq(distributor.pendingPublisher(), bob);
    }

    function testPublisherCanReplaceNomineeAndOldNomineeCannotAccept() public {
        vm.startPrank(publisher);
        distributor.transferPublisher(bob);
        distributor.transferPublisher(alice);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.OnlyPendingPublisher.selector);
        distributor.acceptPublisher();
        vm.prank(alice);
        distributor.acceptPublisher();
        assertEq(distributor.publisher(), alice);
        assertEq(distributor.pendingPublisher(), address(0));
    }

    function testOnlyCurrentPublisherCanCancelNomination() public {
        vm.prank(publisher);
        distributor.transferPublisher(bob);
        address[3] memory unauthorized = [bob, admin, outsider];
        for (uint256 i; i < unauthorized.length; ++i) {
            vm.prank(unauthorized[i]);
            vm.expectRevert(ClaimDistributor.OnlyPublisher.selector);
            distributor.cancelPublisherTransfer();
        }
        assertEq(distributor.pendingPublisher(), bob);
        vm.expectEmit(true, true, false, true, address(distributor));
        emit ClaimDistributor.PublisherTransferCancelled(publisher, bob);
        vm.prank(publisher);
        distributor.cancelPublisherTransfer();
        assertEq(distributor.pendingPublisher(), address(0));
        assertEq(distributor.publisher(), publisher);
        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.OnlyPendingPublisher.selector);
        distributor.acceptPublisher();
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);
    }

    function testSmartContractPublisherCanAcceptNomination() public {
        ClaimDistributorPublisherWallet wallet = new ClaimDistributorPublisherWallet();
        vm.prank(publisher);
        distributor.transferPublisher(address(wallet));
        wallet.accept(distributor);
        assertEq(distributor.publisher(), address(wallet));
        assertEq(distributor.pendingPublisher(), address(0));
    }

    function testPublisherTransferAfterEmergencyStopDoesNotRestoreCreation() public {
        vm.prank(admin);
        distributor.emergencyStop();
        vm.prank(publisher);
        distributor.transferPublisher(bob);
        vm.prank(bob);
        distributor.acceptPublisher();
        assertTrue(distributor.emergencyStopped());
        assertEq(distributor.admin(), admin);
        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.EmergencyStopped.selector);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);
    }

    function testCancelDistributionOnlyAffectsItsBatchAndReturnsUnclaimedBalance() public {
        (, bytes32 bobLeaf) = _createTwoClaimDistribution(DISTRIBUTION_A, alice, 40 ether, bob, 60 ether);
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, bob, 30 ether), 30 ether);

        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 0, alice, 40 ether, _proof(bobLeaf));

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, recipient);

        vm.recordLogs();
        vm.prank(admin);
        distributor.cancelDistribution(DISTRIBUTION_A, recipient);
        Vm.Log[] memory cancellationLogs = vm.getRecordedLogs();
        Vm.Log memory cancellationLog = cancellationLogs[cancellationLogs.length - 1];
        assertEq(cancellationLog.emitter, address(distributor));
        assertEq(cancellationLog.topics[0], keccak256("DistributionCancellation(bytes32,address,address,uint256)"));
        assertEq(cancellationLog.topics[1], DISTRIBUTION_A);
        assertEq(address(uint160(uint256(cancellationLog.topics[2]))), admin);
        assertEq(address(uint160(uint256(cancellationLog.topics[3]))), recipient);
        assertEq(abi.decode(cancellationLog.data, (uint256)), 60 ether);
        assertFalse(distributor.emergencyStopped());
        assertTrue(distributor.cancelledDistributions(DISTRIBUTION_A));
        assertFalse(distributor.cancelledDistributions(DISTRIBUTION_B));
        assertEq(token.balanceOf(recipient), 60 ether);
        assertEq(token.balanceOf(address(distributor)), 30 ether);
        (bytes32 root, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertTrue(root != bytes32(0));
        assertEq(remainingAmount, 0);
        assertEq(claimedCount, 1);
        assertTrue(distributor.isClaimed(DISTRIBUTION_A, 0));

        vm.prank(bob);
        vm.expectRevert(ClaimDistributor.DistributionCancelled.selector);
        distributor.claim(DISTRIBUTION_A, 1, bob, 60 ether, _proof(_leaf(0, alice, 40 ether)));

        vm.prank(bob);
        distributor.claim(DISTRIBUTION_B, 0, bob, 30 ether, new bytes32[](0));
        assertEq(token.balanceOf(bob), 30 ether);
        assertEq(token.balanceOf(address(distributor)), 0);

        vm.prank(publisher);
        vm.expectRevert(ClaimDistributor.DistributionExists.selector);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 10 ether), 10 ether);

        vm.prank(publisher);
        distributor.createDistribution(keccak256("distribution-c"), _leaf(0, alice, 10 ether), 10 ether);
    }

    function testCancelDistributionRejectsInvalidTargetAndDuplicateCancellation() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);

        vm.startPrank(admin);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, address(0));

        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, address(distributor));

        vm.expectRevert(ClaimDistributor.DistributionNotFound.selector);
        distributor.cancelDistribution(DISTRIBUTION_B, recipient);

        distributor.cancelDistribution(DISTRIBUTION_A, recipient);
        vm.expectRevert(ClaimDistributor.DistributionCancelled.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, recipient);
        vm.stopPrank();
    }

    function testCancelDistributionRejectsExhaustedBatch() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);

        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));

        vm.prank(admin);
        vm.expectRevert(ClaimDistributor.NoRemainingBalance.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, recipient);

        assertFalse(distributor.cancelledDistributions(DISTRIBUTION_A));
        assertFalse(distributor.emergencyStopped());
        assertEq(token.balanceOf(recipient), 0);
    }

    function testEmergencyStopHaltsCreationAndClaimsButAllowsGlobalWithdrawal() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.emergencyStop();

        vm.prank(admin);
        distributor.emergencyStop();
        assertTrue(distributor.emergencyStopped());

        vm.prank(admin);
        vm.expectRevert(ClaimDistributor.EmergencyStopped.selector);
        distributor.emergencyStop();

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.EmergencyStopped.selector);
        distributor.claim(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));

        vm.prank(publisher);
        vm.expectRevert(ClaimDistributor.EmergencyStopped.selector);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, alice, 10 ether), 10 ether);

        vm.prank(admin);
        distributor.emergencyWithdraw(recipient);
        assertFalse(distributor.cancelledDistributions(DISTRIBUTION_A));
        assertEq(token.balanceOf(recipient), 50 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function testEmergencyWithdrawStopsAndSweepsAllIncludingSurplusAndRepeatedDeposits() public {
        vm.startPrank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, bob, 30 ether), 30 ether);
        vm.stopPrank();
        token.mint(address(distributor), 7 ether);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.emergencyWithdraw(recipient);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.emergencyStop();

        vm.startPrank(admin);
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.emergencyWithdraw(address(0));
        vm.expectRevert(ClaimDistributor.InvalidRecipient.selector);
        distributor.emergencyWithdraw(address(distributor));

        distributor.emergencyWithdraw(recipient);
        vm.stopPrank();

        assertTrue(distributor.emergencyStopped());
        assertEq(token.balanceOf(recipient), 87 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
        assertFalse(distributor.cancelledDistributions(DISTRIBUTION_A));
        assertFalse(distributor.cancelledDistributions(DISTRIBUTION_B));
        (, uint256 remainingA,) = distributor.distributions(DISTRIBUTION_A);
        (, uint256 remainingB,) = distributor.distributions(DISTRIBUTION_B);
        assertEq(remainingA, 50 ether);
        assertEq(remainingB, 30 ether);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.EmergencyStopped.selector);
        distributor.claim(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));

        token.mint(address(distributor), 5 ether);
        vm.prank(admin);
        distributor.emergencyWithdraw(recipient);
        assertEq(token.balanceOf(recipient), 92 ether);
        assertEq(token.balanceOf(address(distributor)), 0);
    }

    function testRenounceAfterGlobalStopRequiresNoOutstandingBalance() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);
        token.mint(address(distributor), 7 ether);

        vm.startPrank(admin);
        distributor.emergencyStop();
        vm.expectRevert(ClaimDistributor.OutstandingBalance.selector);
        distributor.renounceAdmin();

        distributor.emergencyWithdraw(recipient);
        distributor.renounceAdmin();
        vm.stopPrank();

        assertEq(distributor.admin(), address(0));
        assertEq(token.balanceOf(address(distributor)), 0);
        assertEq(token.balanceOf(recipient), 57 ether);
    }

    function testRenounceAdminRemovesEmergencyAuthority() public {
        vm.prank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);

        vm.prank(outsider);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.renounceAdmin();

        vm.prank(admin);
        distributor.renounceAdmin();
        assertEq(distributor.admin(), address(0));
        assertFalse(distributor.emergencyStopped());

        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));
        assertEq(token.balanceOf(alice), 50 ether);

        vm.prank(admin);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.emergencyWithdraw(recipient);

        vm.prank(admin);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.cancelDistribution(DISTRIBUTION_A, recipient);

        vm.prank(admin);
        vm.expectRevert(ClaimDistributor.OnlyAdmin.selector);
        distributor.emergencyStop();
    }

    function testBatchClaimWithCancelledDistributionRevertsAtomically() public {
        vm.startPrank(publisher);
        distributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 30 ether), 30 ether);
        distributor.createDistribution(DISTRIBUTION_B, _leaf(0, alice, 70 ether), 70 ether);
        vm.stopPrank();

        vm.prank(admin);
        distributor.cancelDistribution(DISTRIBUTION_B, recipient);

        ClaimDistributor.ClaimRequest[] memory requests = new ClaimDistributor.ClaimRequest[](2);
        requests[0] = _request(DISTRIBUTION_A, 0, 30 ether, new bytes32[](0));
        requests[1] = _request(DISTRIBUTION_B, 0, 70 ether, new bytes32[](0));

        vm.prank(alice);
        vm.expectRevert(ClaimDistributor.DistributionCancelled.selector);
        distributor.claimBatch(alice, requests);

        assertFalse(distributor.isClaimed(DISTRIBUTION_A, 0));
        (, uint256 remainingAmount, uint256 claimedCount) = distributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 30 ether);
        assertEq(claimedCount, 0);
        vm.prank(alice);
        distributor.claim(DISTRIBUTION_A, 0, alice, 30 ether, new bytes32[](0));
    }

    function testReentrantTokenCannotClaimSameLeafTwice() public {
        ClaimDistributorReentrantToken reentrantToken = new ClaimDistributorReentrantToken();
        ClaimDistributor reentrantDistributor = new ClaimDistributor(IERC20(address(reentrantToken)), publisher, admin);
        reentrantToken.mint(publisher, 50 ether);
        vm.startPrank(publisher);
        reentrantToken.approve(address(reentrantDistributor), 50 ether);
        reentrantDistributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);
        vm.stopPrank();

        reentrantToken.arm(reentrantDistributor, DISTRIBUTION_A, alice, 50 ether);
        vm.prank(outsider);
        reentrantDistributor.claimFor(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));

        assertTrue(reentrantToken.reentryAttempted());
        assertFalse(reentrantToken.reentrySucceeded());
        assertTrue(reentrantDistributor.isClaimed(DISTRIBUTION_A, 0));
        assertEq(reentrantToken.balanceOf(alice), 50 ether);
    }

    function testBlockedTokenEmergencyWithdrawRollsBackStopButIndependentStopStillWorks() public {
        (ClaimDistributorBlockingToken blockingToken, ClaimDistributor blockingDistributor) =
            _fundBlockingDistribution();
        blockingToken.setTransfersBlocked(true);

        vm.prank(admin);
        vm.expectRevert(ClaimDistributorBlockingToken.TransfersBlocked.selector);
        blockingDistributor.emergencyWithdraw(recipient);

        assertFalse(blockingDistributor.cancelledDistributions(DISTRIBUTION_A));
        assertFalse(blockingDistributor.emergencyStopped());
        assertEq(blockingToken.balanceOf(address(blockingDistributor)), 50 ether);
        assertEq(blockingToken.balanceOf(recipient), 0);
        (, uint256 remainingAmount, uint256 claimedCount) = blockingDistributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 50 ether);
        assertEq(claimedCount, 0);

        vm.prank(admin);
        blockingDistributor.emergencyStop();
        assertTrue(blockingDistributor.emergencyStopped());

        blockingToken.setTransfersBlocked(false);
        vm.prank(admin);
        blockingDistributor.emergencyWithdraw(recipient);
        assertFalse(blockingDistributor.cancelledDistributions(DISTRIBUTION_A));
        assertTrue(blockingDistributor.emergencyStopped());
        assertEq(blockingToken.balanceOf(recipient), 50 ether);
    }

    function testBlockedTokenCancelDistributionRollsBackBatchState() public {
        (ClaimDistributorBlockingToken blockingToken, ClaimDistributor blockingDistributor) =
            _fundBlockingDistribution();
        blockingToken.setTransfersBlocked(true);

        vm.prank(admin);
        vm.expectRevert(ClaimDistributorBlockingToken.TransfersBlocked.selector);
        blockingDistributor.cancelDistribution(DISTRIBUTION_A, recipient);

        assertFalse(blockingDistributor.cancelledDistributions(DISTRIBUTION_A));
        assertFalse(blockingDistributor.emergencyStopped());
        assertEq(blockingToken.balanceOf(address(blockingDistributor)), 50 ether);
        assertEq(blockingToken.balanceOf(recipient), 0);
        (, uint256 remainingAmount, uint256 claimedCount) = blockingDistributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 50 ether);
        assertEq(claimedCount, 0);
    }

    function testBlockedTokenClaimTransferRollsBackClaimState() public {
        (ClaimDistributorBlockingToken blockingToken, ClaimDistributor blockingDistributor) =
            _fundBlockingDistribution();
        blockingToken.setTransfersBlocked(true);

        vm.prank(alice);
        vm.expectRevert(ClaimDistributorBlockingToken.TransfersBlocked.selector);
        blockingDistributor.claim(DISTRIBUTION_A, 0, alice, 50 ether, new bytes32[](0));

        assertFalse(blockingDistributor.isClaimed(DISTRIBUTION_A, 0));
        assertEq(blockingToken.balanceOf(address(blockingDistributor)), 50 ether);
        assertEq(blockingToken.balanceOf(alice), 0);
        (, uint256 remainingAmount, uint256 claimedCount) = blockingDistributor.distributions(DISTRIBUTION_A);
        assertEq(remainingAmount, 50 ether);
        assertEq(claimedCount, 0);
    }

    function _fundBlockingDistribution()
        internal
        returns (ClaimDistributorBlockingToken blockingToken, ClaimDistributor blockingDistributor)
    {
        blockingToken = new ClaimDistributorBlockingToken();
        blockingDistributor = new ClaimDistributor(IERC20(address(blockingToken)), publisher, admin);
        blockingToken.mint(publisher, 50 ether);
        vm.startPrank(publisher);
        blockingToken.approve(address(blockingDistributor), 50 ether);
        blockingDistributor.createDistribution(DISTRIBUTION_A, _leaf(0, alice, 50 ether), 50 ether);
        vm.stopPrank();
    }

    function _createTwoClaimDistribution(
        bytes32 distributionId,
        address firstAccount,
        uint256 firstAmount,
        address secondAccount,
        uint256 secondAmount
    ) internal returns (bytes32 firstLeaf, bytes32 secondLeaf) {
        firstLeaf = _leaf(0, firstAccount, firstAmount);
        secondLeaf = _leaf(1, secondAccount, secondAmount);
        vm.prank(publisher);
        distributor.createDistribution(distributionId, _root(firstLeaf, secondLeaf), firstAmount + secondAmount);
    }

    // OpenZeppelin StandardMerkleTree hashes each ABI-encoded leaf twice and sorts sibling pairs.
    function _leaf(uint256 index, address account, uint256 amount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    function _root(bytes32 first, bytes32 second) internal pure returns (bytes32) {
        return first < second ? keccak256(abi.encodePacked(first, second)) : keccak256(abi.encodePacked(second, first));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    function _request(bytes32 distributionId, uint256 index, uint256 amount, bytes32[] memory proof)
        internal
        pure
        returns (ClaimDistributor.ClaimRequest memory)
    {
        return ClaimDistributor.ClaimRequest({
            distributionId: distributionId, index: index, amount: amount, merkleProof: proof
        });
    }

    function _outgoingTransferCount(Vm.Log[] memory logs, address tokenAddress, address sender)
        internal
        pure
        returns (uint256 count)
    {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].emitter == tokenAddress && logs[i].topics.length == 3 && logs[i].topics[0] == TRANSFER_TOPIC
                    && address(uint160(uint256(logs[i].topics[1]))) == sender
            ) {
                ++count;
            }
        }
    }
}
