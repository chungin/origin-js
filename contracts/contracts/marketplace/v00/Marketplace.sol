pragma solidity ^0.4.24;

import "../../../../node_modules/openzeppelin-solidity/contracts/ownership/Ownable.sol";

/**
 * @title A Marketplace contract for managing listings, offers, payments, escrow and arbitration
 * @author Nick Poulden <nick@poulden.com>
 *
 * Listings may be priced in Eth or ERC20.
 */


contract ERC20 {
    function transfer(address _to, uint256 _value) external returns (bool);
    function transferFrom(address _from, address _to, uint256 _value) external returns (bool);
}


contract V00_Marketplace is Ownable {

    /**
    * @notice All events have the same indexed signature offsets for easy filtering
    */
    event ListingCreated   (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingUpdated   (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingWithdrawn (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingData      (address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event ListingArbitrated(address indexed party, uint indexed listingID, bytes32 ipfsHash);
    event OfferCreated     (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferWithdrawn   (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferAccepted    (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferFundsAdded  (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferDisputed    (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferRuling      (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash, uint ruling);
    event OfferFinalized   (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event OfferData        (address indexed party, uint indexed listingID, uint indexed offerID, bytes32 ipfsHash);
    event MarketplaceData  (address indexed party, bytes32 ipfsHash);
    event AffiliateAdded   (address indexed party, bytes32 ipfsHash);
    event AffiliateRemoved (address indexed party, bytes32 ipfsHash);

    struct Listing {
        address seller;     // Seller wallet / identity contract / other contract
        uint deposit;       // Deposit in Origin Token
        address arbitrator; // Address of arbitration contract
    }

    struct Offer {
        uint value;         // Amount in Eth or token buyer is offering
        uint commission;    // Amount of commission earned if offer is accepted
        uint refund;        // Amount to refund buyer upon finalization
        ERC20 currency;     // Currency of listing. Copied incase seller deleted listing
        address buyer;      // Buyer wallet / identity contract / other contract
        address affiliate;  // Address to send any commission
        address arbitrator; // Address of arbitration contract
        uint finalizes;     // Timestamp offer finalizes
        uint8 status;       // 0: Undefined, 1: Created, 2: Accepted, 3: Disputed
    }

    Listing[] public listings;
    mapping(uint => Offer[]) public offers; // listingID => Offers
    mapping(address => bool) public allowedAffiliates;

    ERC20 public tokenAddr; // Origin Token address

    address public constant ALLOW_ALL_AFFILIATES = 0x0;

    constructor(address _tokenAddr) public {
        owner = msg.sender;
        setTokenAddr(_tokenAddr); // Origin Token contract
    }

    // @dev Return the total number of listings
    function totalListings() public view returns (uint) {
        return listings.length;
    }

    // @dev Return the total number of offers
    function totalOffers(uint listingID) public view returns (uint) {
        return offers[listingID].length;
    }

    // @dev Seller creates listing
    function createListing(bytes32 _ipfsHash, uint _deposit, address _arbitrator)
        public
    {
        _createListing(msg.sender, _ipfsHash, _deposit, _arbitrator);
    }

    // @dev Can only be called by token
    function createListingWithSender(
        address _seller,
        bytes32 _ipfsHash,
        uint _deposit,
        address _arbitrator
    )
        public returns (bool)
    {
        require(msg.sender == address(tokenAddr), "token must call");
        _createListing(_seller, _ipfsHash, _deposit, _arbitrator);
        return true;
    }

    // Private
    function _createListing(
        address _seller,
        bytes32 _ipfsHash,  // IPFS JSON with details, pricing, availability
        uint _deposit,      // Deposit in Origin Token
        address _arbitrator // Address of listing arbitrator
    )
        private
    {
        /* require(_deposit > 0); // Listings must deposit some amount of Origin Token */
        require(_arbitrator != 0x0, "must specify arbitrator");

        listings.push(Listing({
            seller: _seller,
            deposit: _deposit,
            arbitrator: _arbitrator
        }));

        if (_deposit > 0) {
            tokenAddr.transferFrom(_seller, this, _deposit); // Transfer Origin Token
        }
        emit ListingCreated(_seller, listings.length - 1, _ipfsHash);
    }

    // @dev Seller updates listing
    function updateListing(
        uint listingID,
        bytes32 _ipfsHash,
        uint _additionalDeposit
    ) public {
        _updateListing(msg.sender, listingID, _ipfsHash, _additionalDeposit);
    }

    function updateListingWithSender(
        address _seller,
        uint listingID,
        bytes32 _ipfsHash,
        uint _additionalDeposit
    )
        public returns (bool)
    {
        require(msg.sender == address(tokenAddr), "token must call");
        _updateListing(_seller, listingID, _ipfsHash, _additionalDeposit);
        return true;
    }

    function _updateListing(
        address _seller,
        uint listingID,
        bytes32 _ipfsHash,      // Updated IPFS hash
        uint _additionalDeposit // Additional deposit to add
    ) private {
        Listing storage listing = listings[listingID];
        require(listing.seller == _seller, "seller must call");

        if (_additionalDeposit > 0) {
            tokenAddr.transferFrom(_seller, this, _additionalDeposit);
            listing.deposit += _additionalDeposit;
        }

        emit ListingUpdated(listing.seller, listingID, _ipfsHash);
    }

    // @dev Listing arbitrator withdraws listing. IPFS hash contains reason for withdrawl.
    function withdrawListing(uint listingID, address _target, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        require(msg.sender == listing.arbitrator, "arbitrator required");
        require(_target != 0x0, "no target");
        tokenAddr.transfer(_target, listing.deposit); // Send deposit to target
        delete listings[listingID]; // Remove data to get some gas back
        emit ListingWithdrawn(_target, listingID, _ipfsHash);
    }

    // @dev Buyer makes offer.
    function makeOffer(
        uint listingID,
        bytes32 _ipfsHash,   // IPFS hash containing offer data
        uint _finalizes,     // Timestamp an accepted offer will finalize
        address _affiliate,  // Address to send any required commission to
        uint256 _commission, // Amount of commission to send in Origin Token if offer finalizes
        uint _value,         // Offer amount in ERC20 or Eth
        ERC20 _currency,     // ERC20 token address or 0x0 for Eth
        address _arbitrator  // Escrow arbitrator
    )
        public
        payable
    {
        require(
            _affiliate == 0x0 || allowedAffiliates[ALLOW_ALL_AFFILIATES] || allowedAffiliates[_affiliate],
            "Affiliate not allowed"
        );

        offers[listingID].push(Offer({
            status: 1,
            buyer: msg.sender,
            finalizes: _finalizes,
            affiliate: _affiliate,
            commission: _commission,
            currency: _currency,
            value: _value,
            arbitrator: _arbitrator,
            refund: 0
        }));

        if (address(_currency) == 0x0) { // Listing is in ETH
            require(msg.value == _value, "ETH value doesn't match offer");
        } else { // Listing is in ERC20
            require(msg.value == 0, "ETH would be lost");
            require(
                _currency.transferFrom(msg.sender, this, _value),
                "transferFrom failed"
            );
        }

        emit OfferCreated(msg.sender, listingID, offers[listingID].length-1, _ipfsHash);
    }

    // @dev Make new offer after withdrawl
    function makeOffer(
        uint listingID,
        bytes32 _ipfsHash,
        uint _finalizes,
        address _affiliate,
        uint256 _commission,
        uint _value,
        ERC20 _currency,
        address _arbitrator,
        uint _withdrawOfferID
    )
        public
        payable
    {
        withdrawOffer(listingID, _withdrawOfferID, _ipfsHash);
        makeOffer(listingID, _ipfsHash, _finalizes, _affiliate, _commission, _value, _currency, _arbitrator);
    }

    // @dev Seller accepts offer
    function acceptOffer(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == listing.seller, "seller must accept");
        require(offer.status == 1, "state != created");
        require(
            listing.deposit >= offer.commission,
            "deposit must cover commission"
        );
        if (offer.finalizes < 1000000000) { // Relative finalization window
            offer.finalizes = now + offer.finalizes;
        }
        listing.deposit -= offer.commission; // Accepting an offer puts Origin Token into escrow
        offer.status = 2; // Set offer to 'Accepted'
        emit OfferAccepted(msg.sender, listingID, offerID, _ipfsHash);
    }

    // @dev Buyer withdraws offer. IPFS hash contains reason for withdrawl.
    function withdrawOffer(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(
            msg.sender == offer.buyer || msg.sender == listing.seller,
            "restricted to buyer or seller"
        );
        if (listing.seller == 0x0) { // If listing was withdrawn
            require(
                offer.status == 1 || offer.status == 2,
                "state not created or accepted"
            );
            if (offer.status == 2) { // Pay out commission if seller accepted offer then withdrew listing
                payCommission(listingID, offerID);
            }
        } else {
            require(offer.status == 1, "state != created");
        }
        refundBuyer(listingID, offerID);
        emit OfferWithdrawn(msg.sender, listingID, offerID, _ipfsHash);
        delete offers[listingID][offerID];
    }

    // @dev Buyer adds extra funds to an accepted offer.
    function addFunds(uint listingID, uint offerID, bytes32 _ipfsHash, uint _value) public payable {
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == offer.buyer, "buyer must call");
        require(offer.status == 2, "state != accepted");
        if (address(offer.currency) == 0x0) { // Listing is in ETH
            require(
                msg.value == _value,
                "sent != offered value"
            );
        } else { // Listing is in ERC20
            require(msg.value == 0, "ETH must not be sent");
            require(
                offer.currency.transferFrom(msg.sender, this, _value),
                "transferFrom failed"
            );
        }
        offer.value += _value;
        emit OfferFundsAdded(msg.sender, listingID, offerID, _ipfsHash);
    }

    // @dev Buyer must finalize transaction to receive commission
    function finalize(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        if (now <= offer.finalizes) { // Only buyer can finalize before finalization window
            require(
                msg.sender == offer.buyer,
                "only buyer can finalize"
            );
        } else { // Allow both seller and buyer to finalize if finalization window has passed
            require(
                msg.sender == offer.buyer || msg.sender == listing.seller,
                "seller or buyer must finalize"
            );
        }
        require(offer.status == 2, "state != accepted");
        paySeller(listingID, offerID); // Pay seller
        if (msg.sender == offer.buyer) { // Only pay commission if buyer is finalizing
            payCommission(listingID, offerID);
        }
        emit OfferFinalized(msg.sender, listingID, offerID, _ipfsHash);
        delete offers[listingID][offerID];
    }

    // @dev Buyer or seller can dispute transaction during finalization window
    function dispute(uint listingID, uint offerID, bytes32 _ipfsHash) public {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        require(
            msg.sender == offer.buyer || msg.sender == listing.seller,
            "must be seller or buyer"
        );
        require(offer.status == 2, "state != accepted");
        require(now <= offer.finalizes, "already finalized");
        offer.status = 3; // Set status to "Disputed"
        emit OfferDisputed(msg.sender, listingID, offerID, _ipfsHash);
    }

    // @dev Called by arbitrator
    function executeRuling(
        uint listingID,
        uint offerID,
        bytes32 _ipfsHash,
        uint _ruling, // 0: Seller, 1: Buyer, 2: Com + Seller, 3: Com + Buyer
        uint _refund
    ) public {
        Offer storage offer = offers[listingID][offerID];
        require(msg.sender == offer.arbitrator, "must be arbitrator");
        require(offer.status == 3, "state != disputed");
        require(_refund <= offer.value, "refund too high");
        offer.refund = _refund;
        if (_ruling & 1 == 1) {
            refundBuyer(listingID, offerID);
        } else  {
            paySeller(listingID, offerID);
        }
        if (_ruling & 2 == 2) {
            payCommission(listingID, offerID);
        } else  { // Refund commission to seller
            listings[listingID].deposit += offer.commission;
        }
        emit OfferRuling(offer.arbitrator, listingID, offerID, _ipfsHash, _ruling);
        delete offers[listingID][offerID];
    }

    // @dev Sets the amount that a seller wants to refund to a buyer.
    function updateRefund(uint listingID, uint offerID, uint _refund, bytes32 _ipfsHash) public {
        Offer storage offer = offers[listingID][offerID];
        Listing storage listing = listings[listingID];
        require(msg.sender == listing.seller, "seller must call");
        require(offer.status == 2, "state != accepted");
        require(_refund <= offer.value, "excessive refund");
        offer.refund = _refund;
        emit OfferData(msg.sender, listingID, offerID, _ipfsHash);
    }

    // @dev Refunds buyer in ETH or ERC20 - used by 1) executeRuling() and 2) to allow a seller to refund a purchase
    function refundBuyer(uint listingID, uint offerID) private {
        Offer storage offer = offers[listingID][offerID];
        if (address(offer.currency) == 0x0) {
            require(offer.buyer.send(offer.value), "ETH refund failed");
        } else {
            require(
                offer.currency.transfer(offer.buyer, offer.value),
                "refund failed"
            );
        }
    }

    // @dev Pay seller in ETH or ERC20
    function paySeller(uint listingID, uint offerID) private {
        Listing storage listing = listings[listingID];
        Offer storage offer = offers[listingID][offerID];
        uint value = offer.value - offer.refund;

        if (address(offer.currency) == 0x0) {
            require(offer.buyer.send(offer.refund), "ETH refund failed");
            require(listing.seller.send(value), "ETH send failed");
        } else {
            require(
                offer.currency.transfer(offer.buyer, offer.refund),
                "refund failed"
            );
            require(
                offer.currency.transfer(listing.seller, value),
                "transfer failed"
            );
        }
    }

    // @dev Pay commission to affiliate
    function payCommission(uint listingID, uint offerID) private {
        Offer storage offer = offers[listingID][offerID];
        if (offer.affiliate != 0x0) {
            require(
                tokenAddr.transfer(offer.affiliate, offer.commission),
                "commission transfer failed"
            );
        }
    }

    function addData(bytes32 ipfsHash) public {
        emit MarketplaceData(msg.sender, ipfsHash);
    }

    function addData(uint listingID, bytes32 ipfsHash) public {
        emit ListingData(msg.sender, listingID, ipfsHash);
    }

    // @dev Associate ipfs data with an offer
    function addData(uint listingID, uint offerID, bytes32 ipfsHash) public {
        emit OfferData(msg.sender, listingID, offerID, ipfsHash);
    }

    // @dev Allow listing arbitrator to send deposit
    function sendDeposit(uint listingID, address target, uint value, bytes32 ipfsHash) public {
        Listing storage listing = listings[listingID];
        require(listing.arbitrator == msg.sender, "arbitrator must call");
        require(listing.deposit >= value, "value too high");
        listing.deposit -= value;
        require(tokenAddr.transfer(target, value), "transfer failed");
        emit ListingArbitrated(target, listingID, ipfsHash);
    }

    // @dev Set the address of the Origin token contract
    function setTokenAddr(address _tokenAddr) public onlyOwner {
        tokenAddr = ERC20(_tokenAddr);
    }

    // @dev Add affiliate to whitelist. Set to ALLOW_ALL_AFFILIATES to disable.
    function addAffiliate(address _affiliate, bytes32 ipfsHash) public onlyOwner {
        allowedAffiliates[_affiliate] = true;
        emit AffiliateAdded(_affiliate, ipfsHash);
    }

    // @dev Remove affiliate from whitelist.
    function removeAffiliate(address _affiliate, bytes32 ipfsHash) public onlyOwner {
        delete allowedAffiliates[_affiliate];
        emit AffiliateRemoved(_affiliate, ipfsHash);
    }
}
