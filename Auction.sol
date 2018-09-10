pragma solidity ^0.4.24;

import './Manageable.sol';

contract Auction is Manageable {

    enum AuctionTypes {REGULAR, STEP}

    struct AuctionItem {
        address buyer;
        address seller;
        uint256 bid;
        uint32 bidCount;
        AuctionTypes auctionType;
        uint256 minimalRaise;
        uint256 activeTill;
        uint256 started;
        uint256 startPrice;
        uint256 endPrice;
    }

    mapping(uint256 => AuctionItem) public activeAuctions;

    uint32 public auctionDuration = 7 days;
    uint32 public auctionStepInterval = 1 hours;
    uint32 public auctionFeePart = 0.03*1e6; // 3%

    bool public isStepAuctionAllowed = false;
    bool public isRegularAuctionAllowed = false;

    modifier onlyAuctionWinner(uint256 subjectId) {
        require(activeAuctions[subjectId].activeTill < now && activeAuctions[subjectId].buyer == msg.sender);
        _;
    }

    modifier notOnAuction(uint256 subjectId) {
        require(activeAuctions[subjectId].activeTill == 0);
        _;
    }

    function isOnAuction(uint256 subjectId) internal view returns (bool) {
        return activeAuctions[subjectId].activeTill != 0;
    }

    function setAuctionDuration(uint32 duration) public onlyManager {
        auctionDuration = duration;

        emit AuctionDuration(duration);
    }

    function setAuctionStepInterval(uint32 interval) public onlyManager {
        auctionStepInterval = interval;
    }


    function _setOnRegularAuction(uint256 subjectId, uint256 startPrice, uint256 minimalRaise, address seller) internal {
        require(isRegularAuctionAllowed);
        require(activeAuctions[subjectId].activeTill == 0);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.REGULAR;
        newAuction.minimalRaise = minimalRaise;
        newAuction.activeTill = now + auctionDuration;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionRegularStart(subjectId, startPrice, newAuction.activeTill);
    }

    function _setOnStepAuction(uint256 subjectId, uint256 startPrice, uint256 endPrice, address seller, uint32 duration) internal {
        require(isStepAuctionAllowed);
        require(activeAuctions[subjectId].activeTill == 0);
        require(duration >= 1 days && duration <= 90 days);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.endPrice = endPrice;
        newAuction.auctionType = AuctionTypes.STEP;
        newAuction.activeTill = now + duration;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionStepStart(subjectId, startPrice, endPrice, newAuction.started, newAuction.activeTill);
    }

    function _makeAuctionBid(uint256 subjectId) public payable {

        uint256 minimalBid = getMinimalBid(subjectId);
        require(minimalBid > 0 && msg.value >= minimalBid);


        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            if(activeAuctions[subjectId].buyer != address(0)) {
                //Return old bid
                _addToBalance(activeAuctions[subjectId].buyer, activeAuctions[subjectId].bid, 3);
            }

            activeAuctions[subjectId].bidCount++;
            activeAuctions[subjectId].bid = msg.value;
            activeAuctions[subjectId].buyer = msg.sender;
            activeAuctions[subjectId].activeTill = now + auctionDuration;
            emit AuctionBid(subjectId, msg.sender, activeAuctions[subjectId].activeTill, msg.value);
            _transferEther(msg.value);

        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
            address oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            if(oldOwner != address(0)) {
                _addToBalance(oldOwner, minimalBid - getFee(minimalBid), 3);
            }

            if(minimalBid > msg.value) {
                _addToBalance(msg.sender, msg.value - minimalBid, 3);
            }

            emit AuctionWon(subjectId, minimalBid);
            _transferEther(msg.value);
        } else {
            msg.sender.transfer(msg.value);
        }


    }

    function getMinimalBid(uint256 subjectId) public view returns (uint256){
        if(activeAuctions[subjectId].activeTill == 0 || activeAuctions[subjectId].activeTill < now) {
            return 0;
        }

        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            return activeAuctions[subjectId].bid + activeAuctions[subjectId].minimalRaise;
        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
            uint256 leftSteps = (activeAuctions[subjectId].activeTill - now) / auctionStepInterval;
            uint256 allSteps = (activeAuctions[subjectId].activeTill - activeAuctions[subjectId].started) / auctionStepInterval;
            uint256 stepPrice =
                (activeAuctions[subjectId].startPrice > activeAuctions[subjectId].endPrice
                ? activeAuctions[subjectId].startPrice - activeAuctions[subjectId].endPrice
                : activeAuctions[subjectId].endPrice - activeAuctions[subjectId].startPrice)
                / allSteps;

            return activeAuctions[subjectId].startPrice > activeAuctions[subjectId].endPrice
            ? activeAuctions[subjectId].startPrice - stepPrice * (allSteps - leftSteps)
            : activeAuctions[subjectId].startPrice + stepPrice * (allSteps - leftSteps);
        }

        return 0;
    }

    function claimAuction(uint256 subjectId) public {
        address seller = activeAuctions[subjectId].seller;
        uint256 value = activeAuctions[subjectId].bid;
        address buyer = activeAuctions[subjectId].buyer;

        delete activeAuctions[subjectId];

        _transfer(seller, buyer, subjectId);
        if(address(0) != seller) {
            _addToBalance(seller, value - getFee(value), 3);
        }
        emit AuctionWon(subjectId, value);

    }

    function transferRegularAuction(
        uint256 subjectId, uint256 startPrice, uint256 minimalRaise, uint256 activeTill
    ) public onlyManager {
        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.REGULAR;
        newAuction.minimalRaise = minimalRaise;
        newAuction.activeTill = activeTill;
        newAuction.started = now;
        newAuction.seller = address(0);
        emit AuctionRegularStart(subjectId, startPrice, newAuction.activeTill);
    }

    function cancelAuctionInt(uint256 subjectId) internal {
        require(activeAuctions[subjectId].activeTill > 0 && activeAuctions[subjectId].bidCount == 0); //not ended
        delete activeAuctions[subjectId];

        emit AuctionCanceled(subjectId);
    }

    function getFee(uint256 value) public view returns (uint256) {
        return (value * auctionFeePart) / 1e6;
    }

    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal;
    function _transfer(address _from, address _to, uint256 _tokenId) internal;
    function _transferEther(uint256 value) internal;


    event AuctionDuration(uint256 duration);
    event AuctionBid(uint256 indexed subjectId, address buyer, uint256 activeTill, uint256 bid);
    event AuctionWon(uint256 indexed subjectId, uint256 bid);
    event AuctionRegularStart(uint256 indexed subjectId, uint256 startPrice, uint256 activeTill);
    event AuctionStepStart(uint256 indexed subjectId, uint256 startPrice, uint256 endPrice, uint256 started, uint256 activeTill);
    event AuctionCanceled(uint256 indexed subjectId);
}
