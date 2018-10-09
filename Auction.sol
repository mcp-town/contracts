pragma solidity 0.4.25;

import './Manageable.sol';

contract Auction is Manageable {

    enum AuctionTypes {REGULAR, STEP, FIXED}

    struct AuctionItem {
        address buyer;
        address seller;
        address shareBeneficiary;
        uint256 bid;
        uint32 bidCount;
        AuctionTypes auctionType;
        uint256 minimalRaise;
        uint256 activeTill;
        uint256 started;
        uint256 startPrice;
        uint256 endPrice;
        uint256 transferPrice;
    }

    mapping(uint256 => AuctionItem) public activeAuctions;

    modifier notOnAuction(uint256 subjectId) {
        require(activeAuctions[subjectId].startPrice == 0);
        _;
    }

    function _isOnAuction(uint256 subjectId) internal view returns (bool) {
        return activeAuctions[subjectId].startPrice != 0;
    }

    function _cancelAuction(uint256 subjectId) internal {
        require(activeAuctions[subjectId].bidCount == 0 && activeAuctions[subjectId].seller != address(0));
        delete activeAuctions[subjectId];

        emit AuctionCanceled(subjectId);
    }

    event AuctionDuration(uint256 duration);
    event AuctionPayout(address indexed to, uint256 value, uint256 indexed tokenId, uint8 reason);
    event AuctionBid(uint256 indexed subjectId, address indexed buyer, uint256 activeTill, uint256 bid, uint256 bidCount);
    event AuctionWon(uint256 indexed subjectId, address indexed winner, uint256 bid);
    event AuctionRegularStart(uint256 indexed subjectId, address indexed seller, uint256 startPrice, uint256 activeTill, uint256 started);
    event AuctionFixedStart(uint256 indexed subjectId, address indexed seller, uint256 startPrice, uint256 started);
    event AuctionStepStart(uint256 indexed subjectId, address  indexed seller, uint256 startPrice, uint256 endPrice, uint256 started, uint256 activeTill);
    event AuctionCanceled(uint256 indexed subjectId);
}
