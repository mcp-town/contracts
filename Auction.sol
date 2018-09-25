pragma solidity 0.4.25;

import './Manageable.sol';

contract Auction is Manageable {

    enum AuctionTypes {REGULAR, STEP, FIXED}

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
    uint32 public auctionFeePart =  0.025*1000; // 2.5%
    uint32 public regionSharePart = 0.05*1000; // 5%

    bool public isStepAuctionAllowed = false;
    bool public isRegularAuctionAllowed = false;
    bool public isFixedAuctionAllowed = false;

    bool public isRegionShareEnabled = false;

    modifier onlyAuctionWinner(uint256 subjectId) {
        require(activeAuctions[subjectId].activeTill < now && activeAuctions[subjectId].buyer == msg.sender);
        _;
    }

    modifier notOnAuction(uint256 subjectId) {
        require(activeAuctions[subjectId].startPrice == 0);
        _;
    }

    function _isOnAuction(uint256 subjectId) internal view returns (bool) {
        return activeAuctions[subjectId].startPrice != 0;
    }

    function setAuctionDuration(uint32 duration) public onlyManager {
        auctionDuration = duration;

        emit AuctionDuration(duration);
    }

    function setAuctionStepInterval(uint32 interval) public onlyManager {
        auctionStepInterval = interval;
    }


    function _setOnRegularAuction(uint256 subjectId, uint256 startPrice, uint256 minimalRaise, address seller) internal notOnAuction(subjectId) {
        require(isRegularAuctionAllowed);
        require(startPrice > 0 && minimalRaise > 0);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.REGULAR;
        newAuction.minimalRaise = minimalRaise;
        newAuction.activeTill = now + auctionDuration;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionRegularStart(subjectId, seller, startPrice, newAuction.activeTill);
    }

    function _setOnStepAuction(uint256 subjectId, uint256 startPrice, uint256 endPrice, address seller, uint32 duration) internal notOnAuction(subjectId) {
        require(isStepAuctionAllowed);
        require(startPrice > 0 && endPrice > 0);
        require(duration >= 1 days && duration <= 90 days);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.endPrice = endPrice;
        newAuction.auctionType = AuctionTypes.STEP;
        newAuction.activeTill = now + duration;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionStepStart(subjectId, seller, startPrice, endPrice, newAuction.started, newAuction.activeTill);
    }

    function _setOnFixedAuction(uint256 subjectId, uint256 startPrice, address seller) internal notOnAuction(subjectId) {
        require(isFixedAuctionAllowed);
        require(startPrice > 0);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.FIXED;
        newAuction.activeTill = 0;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionFixedStart(subjectId, seller, startPrice);
    }

    function makeAuctionBid(uint256 subjectId) public payable {

        uint256 minimalBid = getMinimalBid(subjectId);
        require(minimalBid > 0 && msg.value >= minimalBid);
        require(activeAuctions[subjectId].buyer != msg.sender);


        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            if(activeAuctions[subjectId].buyer != address(0)) {
                //Return old bid
                _addToBalance(activeAuctions[subjectId].buyer, activeAuctions[subjectId].bid, 3);
            }

            activeAuctions[subjectId].bidCount++;
            activeAuctions[subjectId].bid = msg.value;
            activeAuctions[subjectId].buyer = msg.sender;
            activeAuctions[subjectId].activeTill = now + auctionDuration;
            emit AuctionBid(subjectId, msg.sender, activeAuctions[subjectId].activeTill, msg.value, activeAuctions[subjectId].bidCount);
            _transferEther();

        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
            address oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            if(oldOwner != address(0)) {
                _addToBalance(oldOwner, minimalBid - getFee(minimalBid) - getRegionFee(minimalBid), 3);
            }

            if(minimalBid > msg.value) {
                _addToBalance(msg.sender, msg.value - minimalBid, 3);
            }

            if(isRegionShareEnabled) {
                _toRegionShareBank(subjectId, int(getRegionFee(minimalBid)));
            }

            emit AuctionWon(subjectId, msg.sender, minimalBid);
            _transferEther();

        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.FIXED) {
            oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            if(oldOwner != address(0)) {
                _addToBalance(oldOwner, minimalBid - getFee(minimalBid) - getRegionFee(minimalBid), 3);
            }

            if(isRegionShareEnabled) {
                _toRegionShareBank(subjectId, int(getRegionFee(minimalBid)));
            }

            if(minimalBid > msg.value) {
                _addToBalance(msg.sender, msg.value - minimalBid, 3);
            }

            emit AuctionWon(subjectId, msg.sender, minimalBid);
            _transferEther();

        } else {
            msg.sender.transfer(msg.value);
        }
    }

    function getMinimalBid(uint256 subjectId) public view returns (uint256){
        if(activeAuctions[subjectId].startPrice == 0) {
            return 0;
        }

        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            return activeAuctions[subjectId].bid + activeAuctions[subjectId].minimalRaise;
        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
            if(activeAuctions[subjectId].activeTill < now) {
                return activeAuctions[subjectId].endPrice;
            }
            uint256 allSteps = (activeAuctions[subjectId].activeTill - activeAuctions[subjectId].started) / auctionStepInterval;
            uint256 pastSteps = (now - activeAuctions[subjectId].started) / auctionStepInterval;

            uint256 stepPrice =
                (activeAuctions[subjectId].startPrice > activeAuctions[subjectId].endPrice
                ? activeAuctions[subjectId].startPrice - activeAuctions[subjectId].endPrice
                : activeAuctions[subjectId].endPrice - activeAuctions[subjectId].startPrice)
                / allSteps;

            return activeAuctions[subjectId].startPrice > activeAuctions[subjectId].endPrice
            ? activeAuctions[subjectId].startPrice - stepPrice * pastSteps
            : activeAuctions[subjectId].startPrice + stepPrice * pastSteps;
        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.FIXED) {
            return activeAuctions[subjectId].startPrice;
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
            _addToBalance(seller, value - getFee(value) - getRegionFee(value), 3);
        } else if(isRegionShareEnabled) {
            _toRegionShareBank(subjectId, int(getRegionFee(value)));
        }
        emit AuctionWon(subjectId, buyer, value);

    }

    function _cancelAuction(uint256 subjectId) internal {
        require(activeAuctions[subjectId].bidCount == 0 && activeAuctions[subjectId].startPrice > 0);
        delete activeAuctions[subjectId];

        emit AuctionCanceled(subjectId);
    }

    function getFee(uint256 value) internal view returns (uint256) {
        return (value * auctionFeePart) / 1000;
    }

    function getRegionFee(uint256 value) internal view returns (uint256) {
        return isRegionShareEnabled ? (value * regionSharePart) / 1000 : 0;
    }

    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal;
    function _toRegionShareBank(uint256 _tokenId, int256 _value) internal;
    function _transfer(address _from, address _to, uint256 _tokenId) internal;
    function _transferEther() internal;


    event AuctionDuration(uint256 duration);
    event AuctionBid(uint256 indexed subjectId, address indexed buyer, uint256 activeTill, uint256 bid, uint256 bidCount);
    event AuctionWon(uint256 indexed subjectId, address indexed winner, uint256 bid);
    event AuctionRegularStart(uint256 indexed subjectId, address indexed seller, uint256 startPrice, uint256 activeTill);
    event AuctionFixedStart(uint256 indexed subjectId, address indexed seller, uint256 startPrice);
    event AuctionStepStart(uint256 indexed subjectId, address  indexed seller, uint256 startPrice, uint256 endPrice, uint256 started, uint256 activeTill);
    event AuctionCanceled(uint256 indexed subjectId);
}
