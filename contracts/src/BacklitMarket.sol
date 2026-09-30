// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";

import {BacklitPool} from "./BacklitPool.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";
import {Field} from "./libs/Field.sol";

/// @title BacklitMarket
/// @notice Lists NFTs, carries encrypted offers, and settles a sale in one
/// proof: the seller's share, the creator's royalty and the buyer's change
/// all land as notes in the pool, and the chain records that the royalty was
/// exactly the collection's basis points of a price nobody can read.
///
/// The market takes tokens with `transferFrom` only and does not implement
/// `onERC721Received`: a token sent with `safeTransferFrom` outside `list`
/// would have no listing and no way back, so the transfer is refused instead.
contract BacklitMarket {
    using Field for bytes32;

    /// @notice ERC-2981 asked for royalties on a sale price of 10,000 returns
    /// the royalty in basis points directly.
    uint256 public constant BPS_DENOM = 10_000;

    /// @notice The most a buyer has to see a settlement through after a seller
    /// accepts. The offer's own expiry can cut that short, so the window the
    /// buyer really has is `min(ACCEPT_WINDOW, expiresAt - acceptedAt)`; past
    /// whichever comes first the buyer's funds are free again.
    uint256 public constant ACCEPT_WINDOW = 72 hours;

    /// @notice Ceiling on the flat fee, so the guardian can never price
    /// settlement out of reach.
    uint256 public constant MAX_FEE_WEI = 0.01 ether;

    /// @notice Gas the fee recipient gets inside `settle`. A Safe takes about
    /// 7,000 to receive ETH and a contract that wraps it into aeWETH about
    /// 40,000, so this leaves room for either while capping what a recipient
    /// can burn on every sale. A recipient that needs more has its fee held
    /// for `forwardFees`, which passes on all the gas it is given.
    uint256 public constant FEE_GAS = 100_000;

    /// @notice Ceiling on an offer payload. The SDK's are 114 bytes. Sellers
    /// and the indexer download every payload, so without a cap anyone could
    /// make that arbitrarily expensive.
    uint256 public constant MAX_PAYLOAD_BYTES = 160;

    BacklitPool public immutable pool;
    IVerifier public immutable settleVerifier;
    address public immutable guardian;
    bytes32 public immutable poolId;
    bytes32 public immutable assetField;

    address public feeRecipient;
    uint256 public feeWei;

    /// @notice Fees a settlement could not forward, held until `forwardFees`.
    uint256 public feesOwed;

    struct Keys {
        bytes32 ownerPk;
        bytes32 viewingPk;
    }

    struct Listing {
        address collection;
        uint256 tokenId;
        address seller;
        bool active;
    }

    struct Offer {
        bytes32 listingId;
        address buyer;
        bytes32 buyerPk;
        bytes32 priceCommitment;
        address nftRecipient;
        uint64 expiresAt;
        uint64 acceptedAt;
        bool settled;
        bool cancelled;
        // The collection's rate when the seller accepted, zero until then.
        // Settlement refuses a higher one. Appended, so the fields above keep
        // their places in the `offers` getter, and it shares acceptedAt's slot.
        uint16 acceptedRoyaltyBps;
    }

    struct Receipt {
        bytes32 listingId;
        bytes32 offerId;
        address collection;
        uint256 tokenId;
        address seller;
        address nftRecipient;
        address royaltyReceiver;
        uint256 royaltyBps;
        uint256 feeWei;
        bytes32 priceCommitment;
        bytes32 creatorCommitment;
        uint256 timestamp;
    }

    struct SettlePublic {
        bytes32 root;
        bytes32[2] nullifiers;
        bytes32 sellerCommitment;
        bytes32 creatorCommitment;
        bytes32 changeCommitment;
    }

    mapping(address wallet => Keys) private _keys;
    mapping(bytes32 listingId => Listing) public listings;
    mapping(bytes32 offerId => Offer) public offers;
    mapping(bytes32 offerId => Receipt) public receipts;

    uint256 private listingNonce;
    uint256 private offerNonce;
    bytes32[] private settledOffers;

    event KeysRegistered(address indexed wallet, bytes32 ownerPk, bytes32 viewingPk);
    event Listed(
        bytes32 indexed listingId,
        address indexed collection,
        uint256 indexed tokenId,
        address seller,
        address royaltyReceiver,
        uint256 royaltyBps
    );
    event ListingCancelled(bytes32 indexed listingId);
    event Offered(
        bytes32 indexed offerId,
        bytes32 indexed listingId,
        address indexed buyer,
        bytes32 priceCommitment,
        address nftRecipient,
        uint64 expiresAt,
        bytes payloadToSeller
    );
    event OfferCancelled(bytes32 indexed offerId);
    event Accepted(bytes32 indexed offerId, uint64 acceptDeadline);
    event Unaccepted(bytes32 indexed offerId);
    event OfferExpired(bytes32 indexed offerId);
    event Settled(
        bytes32 indexed offerId,
        bytes32 indexed listingId,
        address indexed nftRecipient,
        address royaltyReceiver,
        uint256 royaltyBps,
        uint256 feeWei
    );
    event FeeDeferred(address indexed feeRecipient, uint256 amount);
    event FeesForwarded(address indexed feeRecipient, uint256 amount);
    event FeeRecipientSet(address feeRecipient);
    event FeeWeiSet(uint256 feeWei);

    error AlreadySettled();
    error BadProof();
    error CollectionNotSupported();
    error CommitmentMismatch();
    error FeeMismatch();
    error FeeTooHigh();
    error FeeTransferFailed();
    error ListingInactive();
    error NoKeys();
    error NotAccepted();
    error NotDelivered();
    error NotEscrowed();
    error NotTheBuyer();
    error NotTheGuardian();
    error NotTheSeller();
    error OfferClosed();
    error OfferNotExpired();
    error OfferStillOpen();
    error OutOfRange();
    error PayloadTooLarge();
    error Reentered();
    error RoyaltyOutOfRange();
    error RoyaltyRaised();
    error ZeroAddress();

    uint256 private locked = 1;

    modifier nonReentrant() {
        if (locked != 1) revert Reentered();
        locked = 2;
        _;
        locked = 1;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotTheGuardian();
        _;
    }

    constructor(
        BacklitPool pool_,
        IVerifier settleVerifier_,
        address feeRecipient_,
        uint256 feeWei_,
        address guardian_
    ) {
        if (
            address(pool_) == address(0) || address(settleVerifier_) == address(0)
                || feeRecipient_ == address(0) || guardian_ == address(0)
        ) revert ZeroAddress();
        if (feeWei_ > MAX_FEE_WEI) revert FeeTooHigh();

        pool = pool_;
        settleVerifier = settleVerifier_;
        guardian = guardian_;
        feeRecipient = feeRecipient_;
        feeWei = feeWei_;
        poolId = pool_.poolId();
        assetField = Field.fromAddress(address(pool_.weth()));

        emit FeeRecipientSet(feeRecipient_);
        emit FeeWeiSet(feeWei_);
    }

    /// @notice Publishes the caller's Backlit keys so others can address notes
    /// and encrypted offers to them. Re-registering replaces the old pair.
    function registerKeys(bytes32 ownerPk, bytes32 viewingPk) external {
        if (ownerPk == bytes32(0) || viewingPk == bytes32(0)) revert ZeroAddress();
        _keys[msg.sender] = Keys(ownerPk.check(), viewingPk);
        emit KeysRegistered(msg.sender, ownerPk, viewingPk);
    }

    function keysOf(address wallet) public view returns (bytes32 ownerPk, bytes32 viewingPk) {
        Keys storage k = _keys[wallet];
        return (k.ownerPk, k.viewingPk);
    }

    function hasKeys(address wallet) public view returns (bool) {
        return _keys[wallet].ownerPk != bytes32(0);
    }

    /// @notice Escrows an NFT and opens it to encrypted offers.
    /// @dev The collection has to answer ERC-2981, and whoever it names as the
    /// royalty receiver has to have registered keys; otherwise there is no
    /// note to pay the royalty into.
    function list(address collection, uint256 tokenId)
        external
        nonReentrant
        returns (bytes32 listingId)
    {
        (address royaltyReceiver, uint256 bps) = royaltyOf(collection, tokenId);
        // A royalty is paid into a note, so the receiver needs keys. A
        // collection that charges nothing has nobody to pay.
        if (bps > 0 && !hasKeys(royaltyReceiver)) revert NoKeys();
        if (!hasKeys(msg.sender)) revert NoKeys();

        listingId = keccak256(abi.encode(address(this), collection, tokenId, msg.sender, listingNonce++))
            .reduce();
        listings[listingId] = Listing(collection, tokenId, msg.sender, true);

        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        // A collection that reports success without moving the token would
        // leave a listing with nothing behind it.
        if (IERC721(collection).ownerOf(tokenId) != address(this)) revert NotEscrowed();

        emit Listed(listingId, collection, tokenId, msg.sender, royaltyReceiver, bps);
    }

    /// @notice Returns an unsold NFT to its seller.
    function cancelListing(bytes32 listingId) external nonReentrant {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ListingInactive();
        if (listing.seller != msg.sender) revert NotTheSeller();

        listing.active = false;
        IERC721(listing.collection).transferFrom(address(this), listing.seller, listing.tokenId);
        // A listing closed on a token still in escrow could never return it.
        if (IERC721(listing.collection).ownerOf(listing.tokenId) != listing.seller) revert NotDelivered();
        emit ListingCancelled(listingId);
    }

    /// @notice Reads the collection's royalty terms, in basis points.
    function royaltyOf(address collection, uint256 tokenId)
        public
        view
        returns (address receiver, uint256 bps)
    {
        if (!IERC165(collection).supportsInterface(type(IERC2981).interfaceId)) {
            revert CollectionNotSupported();
        }
        (receiver, bps) = IERC2981(collection).royaltyInfo(tokenId, BPS_DENOM);
        if (bps > BPS_DENOM) revert RoyaltyOutOfRange();
        if (bps > 0 && receiver == address(0)) revert RoyaltyOutOfRange();
    }

    /// @notice Makes an offer at a price only the seller can read.
    /// @param priceCommitment Poseidon commitment to the price and a blinding factor.
    /// @param nftRecipient Must still own the token when the transfer at
    /// settlement returns, so a contract that passes it on from
    /// `onERC721Received` makes the settlement revert.
    /// @param payloadToSeller The opening, encrypted to the seller's viewing key.
    function offer(
        bytes32 listingId,
        bytes32 priceCommitment,
        address nftRecipient,
        bytes calldata payloadToSeller,
        uint64 expiresAt
    ) external returns (bytes32 offerId) {
        Listing storage listing = listings[listingId];
        if (!listing.active) revert ListingInactive();
        if (nftRecipient == address(0)) revert ZeroAddress();
        if (expiresAt <= block.timestamp) revert OutOfRange();
        if (payloadToSeller.length > MAX_PAYLOAD_BYTES) revert PayloadTooLarge();

        (bytes32 buyerPk,) = keysOf(msg.sender);
        if (buyerPk == bytes32(0)) revert NoKeys();

        offerId = keccak256(abi.encode(address(this), listingId, msg.sender, offerNonce++));
        offers[offerId] = Offer({
            listingId: listingId,
            buyer: msg.sender,
            buyerPk: buyerPk,
            priceCommitment: priceCommitment.check(),
            nftRecipient: nftRecipient,
            expiresAt: expiresAt,
            acceptedAt: 0,
            settled: false,
            cancelled: false,
            acceptedRoyaltyBps: 0
        });

        emit Offered(
            offerId, listingId, msg.sender, priceCommitment, nftRecipient, expiresAt, payloadToSeller
        );
    }

    function cancelOffer(bytes32 offerId) external {
        Offer storage o = offers[offerId];
        if (o.buyer != msg.sender) revert NotTheBuyer();
        _close(o);
        emit OfferCancelled(offerId);
    }

    /// @notice The seller takes the offer. The buyer then has `ACCEPT_WINDOW`, or
    /// whatever is left of the offer's expiry, whichever is shorter, to settle.
    /// `Accepted` reports that deadline rather than the bare window.
    /// @param priceCommitment The commitment whose opening the seller read. An
    /// offer with any other is refused, so the seller accepts the price they
    /// saw whatever a page or an indexer said the offer id was.
    /// @param maxRoyaltyBps The highest rate the seller agrees to, normally the
    /// one they were shown, so a rate raised just before this lands makes it
    /// revert. The rate now is pinned to the offer and settlement refuses a
    /// higher one.
    function accept(bytes32 offerId, bytes32 priceCommitment, uint256 maxRoyaltyBps) external {
        Offer storage o = offers[offerId];
        Listing storage listing = listings[o.listingId];
        if (listing.seller != msg.sender) revert NotTheSeller();
        if (!listing.active) revert ListingInactive();
        if (o.settled || o.cancelled) revert OfferClosed();
        if (block.timestamp >= o.expiresAt) revert OfferClosed();
        if (priceCommitment != o.priceCommitment) revert CommitmentMismatch();

        (, uint256 bps) = royaltyOf(listing.collection, listing.tokenId);
        if (bps > maxRoyaltyBps) revert RoyaltyOutOfRange();

        o.acceptedAt = uint64(block.timestamp);
        // Fits: royaltyOf refuses anything above BPS_DENOM.
        o.acceptedRoyaltyBps = uint16(bps);
        // `settle` closes the offer at `expiresAt` as well as after the window,
        // so the deadline reported here is the one that actually binds.
        uint256 deadline = block.timestamp + ACCEPT_WINDOW;
        if (o.expiresAt < deadline) deadline = o.expiresAt;
        // Fits: the shorter of the two is never above `expiresAt`, which is a
        // `uint64` in the first place.
        // forge-lint: disable-next-line(unsafe-typecast)
        emit Accepted(offerId, uint64(deadline));
    }

    function unaccept(bytes32 offerId) external {
        Offer storage o = offers[offerId];
        Listing storage listing = listings[o.listingId];
        if (listing.seller != msg.sender) revert NotTheSeller();
        if (o.settled || o.cancelled) revert OfferClosed();
        if (o.acceptedAt == 0) revert NotAccepted();

        o.acceptedAt = 0;
        o.acceptedRoyaltyBps = 0;
        emit Unaccepted(offerId);
    }

    /// @notice Closes an offer whose expiry, or whose settlement window, has run out.
    function expireOffer(bytes32 offerId) external {
        Offer storage o = offers[offerId];
        if (o.buyer == address(0)) revert OfferClosed();
        bool pastExpiry = block.timestamp >= o.expiresAt;
        bool pastWindow = o.acceptedAt != 0 && block.timestamp >= uint256(o.acceptedAt) + ACCEPT_WINDOW;
        if (!pastExpiry && !pastWindow) revert OfferNotExpired();
        _close(o);
        emit OfferExpired(offerId);
    }

    function _close(Offer storage o) private {
        if (o.settled) revert AlreadySettled();
        if (o.cancelled) revert OfferClosed();
        o.cancelled = true;
    }

    /// @notice Settles an accepted offer. The proof authorises the spend, so
    /// anyone may submit it.
    function settle(
        bytes32 offerId,
        bytes calldata proof,
        SettlePublic calldata p,
        bytes[3] calldata payloads
    ) external payable nonReentrant {
        Offer storage o = offers[offerId];
        Listing storage listing = listings[o.listingId];

        if (o.settled || o.cancelled) revert OfferClosed();
        if (!listing.active) revert ListingInactive();
        if (o.acceptedAt == 0) revert NotAccepted();
        if (block.timestamp >= o.expiresAt) revert OfferClosed();
        if (block.timestamp >= uint256(o.acceptedAt) + ACCEPT_WINDOW) revert OfferClosed();
        if (msg.value != feeWei) revert FeeMismatch();

        (address royaltyReceiver, uint256 bps) = royaltyOf(listing.collection, listing.tokenId);
        // A rate raised since the acceptance would take the difference out of
        // the seller's share, up to all of it, so the sale stops instead. A
        // lower rate only leaves the seller more, and the proof is built at
        // the live rate either way.
        if (bps > o.acceptedRoyaltyBps) revert RoyaltyRaised();
        (bytes32 sellerPk,) = keysOf(listing.seller);
        (bytes32 creatorPk,) = keysOf(royaltyReceiver);
        if (sellerPk == bytes32(0)) revert NoKeys();
        if (bps > 0 && creatorPk == bytes32(0)) revert NoKeys();
        // With no royalty there is still a third note; it is worth zero and is
        // addressed to the seller so it stays spendable.
        if (bps == 0) creatorPk = sellerPk;

        _verify(offerId, proof, p, payloads, o, sellerPk, creatorPk, bps);

        o.settled = true;
        listing.active = false;

        pool.spendFromMarket(
            p.root,
            p.nullifiers,
            [p.sellerCommitment, p.creatorCommitment, p.changeCommitment],
            payloads
        );

        _writeReceipt(offerId, o, listing, royaltyReceiver, bps, p.creatorCommitment);

        IERC721(listing.collection).safeTransferFrom(address(this), o.nftRecipient, listing.tokenId);
        // The buyer's notes are spent by now, so a collection that reports a
        // transfer it did not make would otherwise keep the payment.
        if (IERC721(listing.collection).ownerOf(listing.tokenId) != o.nftRecipient) revert NotDelivered();

        // A fee recipient that stops accepting ETH must not stop sales, so a
        // failed send is held and forwarded later by anyone. That includes a
        // send the submitter starved of gas: it only delays the fee.
        if (msg.value > 0 && !_send(feeRecipient, msg.value, FEE_GAS)) {
            feesOwed += msg.value;
            emit FeeDeferred(feeRecipient, msg.value);
        }

        emit Settled(offerId, o.listingId, o.nftRecipient, royaltyReceiver, bps, msg.value);
    }

    function _verify(
        bytes32 offerId,
        bytes calldata proof,
        SettlePublic calldata p,
        bytes[3] calldata payloads,
        Offer storage o,
        bytes32 sellerPk,
        bytes32 creatorPk,
        uint256 bps
    ) private view {
        bytes32[] memory publicInputs = new bytes32[](14);
        publicInputs[0] = poolId;
        publicInputs[1] = assetField;
        publicInputs[2] = p.root;
        publicInputs[3] = p.nullifiers[0].check();
        publicInputs[4] = p.nullifiers[1].check();
        publicInputs[5] = p.sellerCommitment.check();
        publicInputs[6] = p.creatorCommitment.check();
        publicInputs[7] = p.changeCommitment.check();
        publicInputs[8] = o.priceCommitment;
        publicInputs[9] = bytes32(bps);
        publicInputs[10] = sellerPk;
        publicInputs[11] = creatorPk;
        publicInputs[12] = o.buyerPk;
        publicInputs[13] = settleBinding(offerId, payloads);

        if (!settleVerifier.verify(proof, publicInputs)) revert BadProof();
    }

    /// @notice What the settle circuit's binding input is set to. The circuit
    /// only binds that slot, so hashing the offer id and the payloads into it
    /// ties a proof to one offer (and with it the listing, the buyer and the
    /// NFT recipient) and to payloads nobody can swap for unreadable ones.
    function settleBinding(bytes32 offerId, bytes[3] calldata payloads) public pure returns (bytes32) {
        return keccak256(abi.encode(offerId, keccak256(abi.encode(payloads)))).reduce();
    }

    function _writeReceipt(
        bytes32 offerId,
        Offer storage o,
        Listing storage listing,
        address royaltyReceiver,
        uint256 bps,
        bytes32 creatorCommitment
    ) private {
        receipts[offerId] = Receipt({
            listingId: o.listingId,
            offerId: offerId,
            collection: listing.collection,
            tokenId: listing.tokenId,
            seller: listing.seller,
            nftRecipient: o.nftRecipient,
            royaltyReceiver: royaltyReceiver,
            royaltyBps: bps,
            feeWei: msg.value,
            priceCommitment: o.priceCommitment,
            creatorCommitment: creatorCommitment,
            timestamp: block.timestamp
        });
        settledOffers.push(offerId);
    }

    /// @notice The whole receipt in one read, for the indexer and the receipt
    /// page.
    function receiptOf(bytes32 offerId) external view returns (Receipt memory) {
        return receipts[offerId];
    }

    function offerOf(bytes32 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }

    function listingOf(bytes32 listingId) external view returns (Listing memory) {
        return listings[listingId];
    }

    function receiptCount() external view returns (uint256) {
        return settledOffers.length;
    }

    function recentReceipts(uint256 limit) external view returns (Receipt[] memory out) {
        uint256 total = settledOffers.length;
        uint256 n = limit > total ? total : limit;
        out = new Receipt[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = receipts[settledOffers[total - 1 - i]];
        }
    }

    /// @notice Sends deferred fees to the current fee recipient. Anyone may
    /// call it; the money can only go to `feeRecipient`.
    function forwardFees() external nonReentrant {
        uint256 amount = feesOwed;
        if (amount == 0) return;
        feesOwed = 0;
        if (!_send(feeRecipient, amount, gasleft())) revert FeeTransferFailed();
        emit FeesForwarded(feeRecipient, amount);
    }

    /// @dev Solidity's `.call` copies whatever the callee returns, and a
    /// callee can return more than the 1/64 of gas the caller kept can pay
    /// to copy. Nothing here reads the return data, so none is copied.
    function _send(address to, uint256 amount, uint256 gasLimit) private returns (bool sent) {
        assembly ("memory-safe") {
            sent := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
    }

    function setFeeRecipient(address feeRecipient_) external onlyGuardian {
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        feeRecipient = feeRecipient_;
        emit FeeRecipientSet(feeRecipient_);
    }

    function setFeeWei(uint256 feeWei_) external onlyGuardian {
        if (feeWei_ > MAX_FEE_WEI) revert FeeTooHigh();
        feeWei = feeWei_;
        emit FeeWeiSet(feeWei_);
    }
}
