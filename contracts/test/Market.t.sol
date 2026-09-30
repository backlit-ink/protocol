// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {BacklitMarket} from "../src/BacklitMarket.sol";
import {BacklitPool} from "../src/BacklitPool.sol";
import {IVerifier} from "../src/interfaces/IVerifier.sol";
import {SNARK_SCALAR_FIELD} from "../src/libs/Field.sol";

import {BacklitTest} from "./Base.t.sol";
import {EchoVerifier} from "./mocks/EchoVerifier.sol";
import {HollowCollection} from "./mocks/HollowCollection.sol";
import {PlainCollection} from "./mocks/PlainCollection.sol";
import {RejectingRecipient} from "./mocks/RejectingRecipient.sol";
import {ReturnBomb} from "./mocks/ReturnBomb.sol";
import {TestCollection} from "./mocks/TestCollection.sol";

contract MarketTest is BacklitTest {
    bytes32 internal constant PRICE_COMMITMENT = bytes32(uint256(555));

    function _fund() internal returns (bytes32 root) {
        depositAs(buyer, 5 ether, BUYER_PK, bytes32(uint256(1)));
        return pool.currentRoot();
    }

    function test_keysAreReadableAndReplaceable() public {
        (bytes32 ownerPk, bytes32 viewingPk) = market.keysOf(seller);
        assertEq(ownerPk, SELLER_PK);
        assertEq(viewingPk, VIEWING_PK);
        assertTrue(market.hasKeys(seller));
        assertFalse(market.hasKeys(stranger));

        vm.prank(seller);
        market.registerKeys(bytes32(uint256(777)), bytes32(uint256(888)));
        (ownerPk,) = market.keysOf(seller);
        assertEq(ownerPk, bytes32(uint256(777)));
    }

    function test_keysCannotBeZero() public {
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.ZeroAddress.selector);
        market.registerKeys(bytes32(0), VIEWING_PK);
    }

    function test_listEscrowsTheToken() public {
        bytes32 listingId = mintAndList(1);
        assertEq(IERC721(address(collection)).ownerOf(1), address(market));

        BacklitMarket.Listing memory listing = market.listingOf(listingId);
        assertEq(listing.collection, address(collection));
        assertEq(listing.tokenId, 1);
        assertEq(listing.seller, seller);
        assertTrue(listing.active);
    }

    function test_listRefusesATransferThatDidNotHappen() public {
        HollowCollection hollow = new HollowCollection(creator, uint96(ROYALTY_BPS));
        vm.startPrank(seller);
        hollow.mint(seller);
        vm.expectRevert(BacklitMarket.NotEscrowed.selector);
        market.list(address(hollow), 1);
        vm.stopPrank();
    }

    /// @dev Only `list` may put a token in escrow. A safe transfer from outside
    /// would create no listing and could never be returned.
    function test_theMarketRefusesSafeTransfers() public {
        vm.startPrank(seller);
        collection.mint(seller);
        vm.expectRevert();
        collection.safeTransferFrom(seller, address(market), 1);
        vm.stopPrank();
        assertEq(IERC721(address(collection)).ownerOf(1), seller);
    }

    function test_listRefusesACollectionWithoutRoyaltyTerms() public {
        PlainCollection plain = new PlainCollection();
        vm.startPrank(seller);
        plain.mint(seller);
        plain.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.CollectionNotSupported.selector);
        market.list(address(plain), 1);
        vm.stopPrank();
    }

    function test_listRefusesACreatorWithoutKeys() public {
        TestCollection orphan = new TestCollection("Orphan", "ORPH", stranger, 500);
        vm.startPrank(seller);
        orphan.mint(seller);
        orphan.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.list(address(orphan), 1);
        vm.stopPrank();
    }

    function test_listRefusesASellerWithoutKeys() public {
        vm.startPrank(stranger);
        collection.mint(stranger);
        collection.approve(address(market), 1);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.list(address(collection), 1);
        vm.stopPrank();
    }

    function test_cancelListingReturnsTheToken() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(seller);
        market.cancelListing(listingId);

        assertEq(IERC721(address(collection)).ownerOf(1), seller);
        assertFalse(market.listingOf(listingId).active);
    }

    function test_onlyTheSellerCancelsAListing() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.cancelListing(listingId);
    }

    function test_cancelListingRefusesAReturnThatDidNotHappen() public {
        HollowCollection hollow = new HollowCollection(creator, uint96(ROYALTY_BPS));
        bytes32 listingId = _listWhileHonest(hollow);
        hollow.setHollow(true);

        vm.prank(seller);
        vm.expectRevert(BacklitMarket.NotDelivered.selector);
        market.cancelListing(listingId);
        assertTrue(market.listingOf(listingId).active, "the listing stays open to try again");

        hollow.setHollow(false);
        vm.prank(seller);
        market.cancelListing(listingId);
        assertEq(IERC721(address(hollow)).ownerOf(1), seller);
    }

    function test_royaltyOfReadsTheCollection() public view {
        (address receiver, uint256 basisPoints) = market.royaltyOf(address(collection), 1);
        assertEq(receiver, creator);
        assertEq(basisPoints, ROYALTY_BPS);
    }

    function test_offerStoresTheBuyersKeyAtTheTime() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        BacklitMarket.Offer memory offer = market.offerOf(offerId);
        assertEq(offer.buyer, buyer);
        assertEq(offer.buyerPk, BUYER_PK);
        assertEq(offer.priceCommitment, PRICE_COMMITMENT);
    }

    function test_offerNeedsKeys() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.offer(listingId, PRICE_COMMITMENT, stranger, hex"", uint64(block.timestamp + 1 days));
    }

    function test_offerNeedsAnExpiryInTheFuture() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(buyer);
        vm.expectRevert(BacklitMarket.OutOfRange.selector);
        market.offer(listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp));
    }

    function test_theBuyerCancelsTheirOwnOffer() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheBuyer.selector);
        market.cancelOffer(offerId);

        vm.prank(buyer);
        market.cancelOffer(offerId);
        assertTrue(market.offerOf(offerId).cancelled);
    }

    function test_acceptAndUnaccept() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);
        assertGt(market.offerOf(offerId).acceptedAt, 0);
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, ROYALTY_BPS, "the rate is pinned");

        vm.prank(seller);
        market.unaccept(offerId);
        assertEq(market.offerOf(offerId).acceptedAt, 0);
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, 0, "and cleared");
    }

    function test_aLaterAcceptancePinsTheRateAtThatMoment() public {
        (, bytes32 offerId) = _accepted();
        vm.prank(seller);
        market.unaccept(offerId);

        collection.setRoyalty(creator, 700);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, 700);
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, 700);
    }

    /// @dev The seller read an opening of one commitment. An index that pairs
    /// it with another offer's id cannot get that offer accepted.
    function test_acceptHoldsTheSellerToTheOfferTheyOpened() public {
        bytes32 listingId = mintAndList(1);
        openOffer(listingId, PRICE_COMMITMENT);
        bytes32 lowball = openOffer(listingId, bytes32(uint256(556)));

        vm.prank(seller);
        vm.expectRevert(BacklitMarket.CommitmentMismatch.selector);
        market.accept(lowball, PRICE_COMMITMENT, ROYALTY_BPS);
        assertEq(market.offerOf(lowball).acceptedAt, 0);
    }

    /// @dev A raise that lands just before the acceptance makes it revert.
    /// Agreeing to the new rate is then the seller's call.
    function test_acceptRefusesARateAboveTheSellersCeiling() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        collection.setRoyalty(creator, 1_000);
        vm.prank(seller);
        vm.expectRevert(BacklitMarket.RoyaltyOutOfRange.selector);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, 1_000);
        assertEq(market.offerOf(offerId).acceptedRoyaltyBps, 1_000);
    }

    function test_anExpiredOfferCanBeClosedByAnyone() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.expectRevert(BacklitMarket.OfferNotExpired.selector);
        market.expireOffer(offerId);

        vm.warp(block.timestamp + 8 days);
        vm.prank(stranger);
        market.expireOffer(offerId);

        assertTrue(market.offerOf(offerId).cancelled);
    }

    function test_anAcceptedOfferExpiresAfterTheSettlementWindow() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        vm.warp(block.timestamp + market.ACCEPT_WINDOW() + 1);
        market.expireOffer(offerId);
        assertTrue(market.offerOf(offerId).cancelled);
    }

    /// @dev The deadline in `Accepted` has to be the one `settle` will honour.
    /// With an offer that outlives the window that is now plus `ACCEPT_WINDOW`.
    function test_acceptedReportsTheWindowWhenItIsTheBindingDeadline() public {
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);
        uint64 expected = uint64(block.timestamp) + uint64(market.ACCEPT_WINDOW());

        vm.expectEmit(true, false, false, true, address(market));
        emit BacklitMarket.Accepted(offerId, expected);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        assertLt(expected, market.offerOf(offerId).expiresAt, "the window has to be the tighter of the two");
    }

    /// @dev A seller can accept seconds before the offer expires. The deadline
    /// reported is then the expiry, because that is where `settle` stops.
    function test_acceptedReportsTheOfferExpiryWhenItComesFirst() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(buyer);
        bytes32 offerId =
            market.offer(listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 hours));

        uint64 expected = market.offerOf(offerId).expiresAt;

        vm.expectEmit(true, false, false, true, address(market));
        emit BacklitMarket.Accepted(offerId, expected);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        assertLt(expected, block.timestamp + market.ACCEPT_WINDOW(), "the expiry is inside the window");
    }

    /// @dev Whatever the event says, `settle` has to agree with it.
    function test_theReportedDeadlineIsTheOneSettleHonours() public {
        bytes32 root = _fund();
        bytes32 listingId = mintAndList(1);
        vm.prank(buyer);
        bytes32 offerId =
            market.offer(listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 hours));

        vm.recordLogs();
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint64 deadline;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == BacklitMarket.Accepted.selector) {
                assertEq(logs[i].topics[1], offerId);
                deadline = abi.decode(logs[i].data, (uint64));
            }
        }
        assertEq(uint256(deadline), market.offerOf(offerId).expiresAt);

        vm.warp(deadline - 1);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());
        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the sale went through before the deadline");
    }

    function _accepted() internal returns (bytes32 listingId, bytes32 offerId) {
        listingId = mintAndList(1);
        offerId = openOffer(listingId, PRICE_COMMITMENT);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);
    }

    function test_settleMovesTheNFTPaysTheFeeAndWritesAReceipt() public {
        bytes32 root = _fund();
        (bytes32 listingId, bytes32 offerId) = _accepted();

        uint256 feeBefore = feeRecipient.balance;

        vm.prank(stranger);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the NFT went to the offer's recipient");
        assertEq(feeRecipient.balance - feeBefore, FEE);
        assertEq(pool.leafCount(), 4, "one deposit plus three settlement notes");
        assertEq(market.receiptCount(), 1);

        BacklitMarket.Receipt memory receipt = market.receiptOf(offerId);
        assertEq(receipt.listingId, listingId);
        assertEq(receipt.collection, address(collection));
        assertEq(receipt.tokenId, 1);
        assertEq(receipt.seller, seller);
        assertEq(receipt.nftRecipient, buyer);
        assertEq(receipt.royaltyReceiver, creator);
        assertEq(receipt.royaltyBps, ROYALTY_BPS);
        assertEq(receipt.feeWei, FEE);
        assertEq(
            receipt.priceCommitment, PRICE_COMMITMENT, "the receipt carries the commitment, not the price"
        );
        assertEq(receipt.creatorCommitment, settlePublic(root).creatorCommitment);
        assertEq(receipt.timestamp, block.timestamp);
        assertEq(market.recentReceipts(5)[0].offerId, offerId);
    }

    function test_settleNeedsAnAcceptedOffer() public {
        bytes32 root = _fund();
        bytes32 listingId = mintAndList(1);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);

        vm.expectRevert(BacklitMarket.NotAccepted.selector);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());
    }

    function test_settleNeedsTheExactFee() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.expectRevert(BacklitMarket.FeeMismatch.selector);
        market.settle{value: FEE - 1}(offerId, hex"00", settlePublic(root), emptyPayloads());
    }

    function test_settleRejectsABadProof() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        BacklitMarket.SettlePublic memory p = settlePublic(root);
        settleVerifier.setAccepts(false);

        vm.expectRevert(BacklitMarket.BadProof.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    function test_anOfferCannotSettleTwice() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        BacklitMarket.SettlePublic memory again = settlePublic(root);
        vm.expectRevert(BacklitMarket.OfferClosed.selector);
        market.settle{value: FEE}(offerId, hex"00", again, emptyPayloads());
    }

    function test_settleFailsAfterTheSettlementWindow() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.warp(block.timestamp + market.ACCEPT_WINDOW() + 1);
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        vm.expectRevert(BacklitMarket.OfferClosed.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    function test_settleFailsIfTheCreatorDropsTheirKeys() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        // The collection points its royalty somewhere with no keys.
        collection.setRoyalty(stranger, uint96(ROYALTY_BPS));
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        vm.expectRevert(BacklitMarket.NoKeys.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
    }

    /// @dev Raised after the seller accepted, the rate would take their share.
    /// The sale stops instead, and goes through once the rate is back.
    function test_aRateRaisedAfterAcceptanceStopsTheSale() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        collection.setRoyalty(creator, 10_000);
        vm.expectRevert(BacklitMarket.RoyaltyRaised.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
        assertEq(IERC721(address(collection)).ownerOf(1), address(market), "the token left escrow");
        assertFalse(pool.isSpent(p.nullifiers[0]), "the buyer's notes were spent");

        collection.setRoyalty(creator, uint96(ROYALTY_BPS));
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
        assertEq(market.receiptOf(offerId).royaltyBps, ROYALTY_BPS);
    }

    function test_aRateLoweredAfterAcceptanceSettlesAtTheLowerRate() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        collection.setRoyalty(creator, 250);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());
        assertEq(market.receiptOf(offerId).royaltyBps, 250, "settled at the live rate");
    }

    function test_offerPayloadsAreCapped() public {
        bytes32 listingId = mintAndList(1);
        uint256 cap = market.MAX_PAYLOAD_BYTES();
        uint64 expiresAt = uint64(block.timestamp + 1 days);

        vm.startPrank(buyer);
        market.offer(listingId, PRICE_COMMITMENT, buyer, new bytes(cap), expiresAt);
        vm.expectRevert(BacklitMarket.PayloadTooLarge.selector);
        market.offer(listingId, PRICE_COMMITMENT, buyer, new bytes(cap + 1), expiresAt);
        vm.stopPrank();
    }

    /// @dev The pool caps every note payload, the three a settlement adds too.
    function test_settlementNotePayloadsAreCapped() public {
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        BacklitMarket.SettlePublic memory p = settlePublic(root);
        bytes[3] memory payloads = emptyPayloads();
        payloads[1] = new bytes(pool.MAX_PAYLOAD_BYTES() + 1);

        vm.expectRevert(BacklitPool.PayloadTooLarge.selector);
        market.settle{value: FEE}(offerId, hex"00", p, payloads);
    }

    function test_settleBuildsThePublicInputsTheCircuitExpects() public {
        BacklitMarket echoed = new BacklitMarket(
            pool, IVerifier(address(new EchoVerifier())), feeRecipient, FEE, guardian
        );

        vm.prank(seller);
        echoed.registerKeys(SELLER_PK, VIEWING_PK);
        vm.prank(buyer);
        echoed.registerKeys(BUYER_PK, VIEWING_PK);
        vm.prank(creator);
        echoed.registerKeys(CREATOR_PK, VIEWING_PK);

        vm.startPrank(seller);
        collection.mint(seller);
        collection.approve(address(echoed), 1);
        bytes32 listingId = echoed.list(address(collection), 1);
        vm.stopPrank();

        vm.prank(buyer);
        bytes32 offerId = echoed.offer(
            listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 days)
        );
        vm.prank(seller);
        echoed.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);

        bytes32 root = _fund();
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        try echoed.settle{value: FEE}(offerId, hex"00", p, emptyPayloads()) {
            revert("the echo verifier always reverts");
        } catch (bytes memory reason) {
            bytes32[] memory publicInputs = abi.decode(_stripSelector(reason), (bytes32[]));

            assertEq(publicInputs.length, 14, "settle takes fourteen public inputs");
            assertEq(publicInputs[0], pool.poolId());
            assertEq(publicInputs[1], bytes32(uint256(uint160(address(weth)))));
            assertEq(publicInputs[2], root);
            assertEq(publicInputs[3], p.nullifiers[0]);
            assertEq(publicInputs[4], p.nullifiers[1]);
            assertEq(publicInputs[5], p.sellerCommitment);
            assertEq(publicInputs[6], p.creatorCommitment);
            assertEq(publicInputs[7], p.changeCommitment);
            assertEq(publicInputs[8], PRICE_COMMITMENT);
            assertEq(publicInputs[9], bytes32(ROYALTY_BPS));
            assertEq(publicInputs[10], SELLER_PK);
            assertEq(publicInputs[11], CREATOR_PK);
            assertEq(publicInputs[12], BUYER_PK);
            bytes32 binding = keccak256(abi.encode(offerId, keccak256(abi.encode(emptyPayloads()))));
            assertEq(publicInputs[13], bytes32(uint256(binding) % SNARK_SCALAR_FIELD), "binding slot");
            assertTrue(publicInputs[13] != listingId);
        }
    }

    function test_theSettleBindingCoversTheOfferAndEveryPayload() public view {
        bytes[3] memory payloads = emptyPayloads();
        bytes32 honest = market.settleBinding(bytes32(uint256(1)), payloads);

        assertTrue(market.settleBinding(bytes32(uint256(2)), payloads) != honest, "offer");
        assertTrue(
            market.settleBinding(bytes32(uint256(1)), [payloads[1], payloads[0], payloads[2]]) != honest, "order"
        );
        assertTrue(
            market.settleBinding(bytes32(uint256(1)), [payloads[0], payloads[1], bytes(hex"06")]) != honest,
            "payload"
        );
        assertLt(uint256(honest), SNARK_SCALAR_FIELD);
    }

    function test_aFeeRecipientThatRefusesETHDoesNotBlockASale() public {
        RejectingRecipient router = new RejectingRecipient();
        vm.prank(guardian);
        market.setFeeRecipient(address(router));

        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.expectEmit(true, false, false, true, address(market));
        emit BacklitMarket.FeeDeferred(address(router), FEE);
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the sale went through");
        assertEq(market.feesOwed(), FEE);
        assertEq(address(market).balance, FEE);

        vm.expectRevert(BacklitMarket.FeeTransferFailed.selector);
        market.forwardFees();

        router.setRefusing(false);
        vm.prank(stranger);
        market.forwardFees();
        assertEq(address(router).balance, FEE);
        assertEq(market.feesOwed(), 0);
        assertEq(address(market).balance, 0);
    }

    function test_forwardingNothingIsANoOp() public {
        market.forwardFees();
        assertEq(market.feesOwed(), 0);
    }

    /// @dev Copying a refusal this size back would cost settle more gas than
    /// it has left, at any gas limit.
    function test_aFeeRecipientThatRevertsWithAHugePayloadDoesNotBlockASale() public {
        ReturnBomb bomb = new ReturnBomb(true);
        vm.prank(guardian);
        market.setFeeRecipient(address(bomb));

        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();

        vm.expectEmit(true, false, false, true, address(market));
        emit BacklitMarket.FeeDeferred(address(bomb), FEE);
        market.settle{value: FEE, gas: 30_000_000}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(IERC721(address(collection)).ownerOf(1), buyer, "the sale went through");
        assertEq(market.feesOwed(), FEE);
        assertEq(address(market).balance, FEE);
    }

    function test_aFeeRecipientThatReturnsAHugePayloadIsPaidWithinTheGasCap() public {
        ReturnBomb bomb = new ReturnBomb(false);
        vm.prank(guardian);
        market.setFeeRecipient(address(bomb));

        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        market.settle{value: FEE, gas: 30_000_000}(offerId, hex"00", settlePublic(root), emptyPayloads());

        assertEq(address(bomb).balance, FEE);
        assertEq(market.feesOwed(), 0);
        // A call that carries value adds a 2,300 stipend to the gas it passes.
        assertLe(bomb.gasOnEntry(), market.FEE_GAS() + 2_300, "the recipient got more than FEE_GAS");
    }

    /// @dev `forwardFees` passes on all its gas, so the recipient can burn
    /// nearly all of it; the send still finishes because nothing comes back.
    function test_forwardFeesCopiesNothingTheRecipientReturns() public {
        RejectingRecipient router = new RejectingRecipient();
        vm.prank(guardian);
        market.setFeeRecipient(address(router));
        bytes32 root = _fund();
        (, bytes32 offerId) = _accepted();
        market.settle{value: FEE}(offerId, hex"00", settlePublic(root), emptyPayloads());

        ReturnBomb bomb = new ReturnBomb(false);
        vm.prank(guardian);
        market.setFeeRecipient(address(bomb));
        market.forwardFees{gas: 30_000_000}();

        assertEq(address(bomb).balance, FEE);
        assertEq(market.feesOwed(), 0);
        assertGt(bomb.gasOnEntry(), market.FEE_GAS(), "forwardFees capped the recipient");
    }

    /// @dev The buyer's notes are spent before the transfer, so a collection
    /// that turns hollow after listing would otherwise keep the payment.
    function test_settleRefusesADeliveryThatDidNotHappen() public {
        bytes32 root = _fund();
        HollowCollection hollow = new HollowCollection(creator, uint96(ROYALTY_BPS));
        bytes32 listingId = _listWhileHonest(hollow);
        bytes32 offerId = openOffer(listingId, PRICE_COMMITMENT);
        vm.prank(seller);
        market.accept(offerId, PRICE_COMMITMENT, ROYALTY_BPS);
        hollow.setHollow(true);
        BacklitMarket.SettlePublic memory p = settlePublic(root);

        vm.expectRevert(BacklitMarket.NotDelivered.selector);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
        assertFalse(pool.isSpent(p.nullifiers[0]), "the buyer's notes were spent");
        assertTrue(market.listingOf(listingId).active);

        hollow.setHollow(false);
        market.settle{value: FEE}(offerId, hex"00", p, emptyPayloads());
        assertEq(IERC721(address(hollow)).ownerOf(1), buyer);
    }

    function test_aCollectionWithNoRoyaltyPaysTheThirdNoteToTheSeller() public {
        collection.setRoyalty(creator, 0);
        bytes32 root = _fund();

        BacklitMarket echoed = new BacklitMarket(
            pool, IVerifier(address(new EchoVerifier())), feeRecipient, FEE, guardian
        );
        vm.prank(seller);
        echoed.registerKeys(SELLER_PK, VIEWING_PK);
        vm.prank(buyer);
        echoed.registerKeys(BUYER_PK, VIEWING_PK);

        vm.startPrank(seller);
        collection.mint(seller);
        collection.approve(address(echoed), 1);
        bytes32 listingId = echoed.list(address(collection), 1);
        vm.stopPrank();

        vm.prank(buyer);
        bytes32 offerId = echoed.offer(
            listingId, PRICE_COMMITMENT, buyer, hex"", uint64(block.timestamp + 1 days)
        );
        vm.prank(seller);
        echoed.accept(offerId, PRICE_COMMITMENT, 0);

        BacklitMarket.SettlePublic memory zeroRoyalty = settlePublic(root);
        try echoed.settle{value: FEE}(offerId, hex"00", zeroRoyalty, emptyPayloads()) {
            revert("the echo verifier always reverts");
        } catch (bytes memory reason) {
            bytes32[] memory publicInputs = abi.decode(_stripSelector(reason), (bytes32[]));
            assertEq(publicInputs[9], bytes32(uint256(0)), "no royalty");
            assertEq(publicInputs[11], SELLER_PK, "the empty creator note stays spendable");
        }
    }

    function test_theGuardianSetsTheFeeWithinBounds() public {
        vm.prank(guardian);
        market.setFeeWei(0.001 ether);
        assertEq(market.feeWei(), 0.001 ether);

        uint256 tooHigh = market.MAX_FEE_WEI() + 1;
        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.FeeTooHigh.selector);
        market.setFeeWei(tooHigh);

        vm.prank(stranger);
        vm.expectRevert(BacklitMarket.NotTheGuardian.selector);
        market.setFeeWei(0);
    }

    function test_theGuardianSetsTheFeeRecipient() public {
        vm.prank(guardian);
        market.setFeeRecipient(stranger);
        assertEq(market.feeRecipient(), stranger);

        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.ZeroAddress.selector);
        market.setFeeRecipient(address(0));
    }

    function test_theGuardianHasNoRouteToATokenOrANote() public {
        bytes32 listingId = mintAndList(1);
        vm.prank(guardian);
        vm.expectRevert(BacklitMarket.NotTheSeller.selector);
        market.cancelListing(listingId);
    }

    function _listWhileHonest(HollowCollection hollow) internal returns (bytes32 listingId) {
        hollow.setHollow(false);
        vm.startPrank(seller);
        hollow.mint(seller);
        hollow.approve(address(market), 1);
        listingId = market.list(address(hollow), 1);
        vm.stopPrank();
    }

    function _stripSelector(bytes memory reason) private pure returns (bytes memory out) {
        out = new bytes(reason.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = reason[i + 4];
        }
    }
}
