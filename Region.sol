pragma solidity 0.4.25;

import "./Manageable.sol";
import "./UserBalance.sol";
import "./MainInterface.sol";
import "./Auction.sol";


contract Region is Auction {

    struct RegionToken {
        uint16 regionId;
        address owner;
        uint8 tax;
        string regionName;
        bool isCanSale;
    }

    uint32 public auctionDuration = 7 days;

    uint32 public auctionStepInterval = 1 hours;
    uint32 public auctionFeePart =  0.025*1000; // 2.5%
    uint32 public globalSharePart = 0.025*1000;

    mapping(uint16 => uint256) public regionMap;
    mapping(uint256 => address) public approved;
    mapping(address => uint256) public balances;

    RegionToken[] public tokens;

    uint8 public defaultTax = 50;

    UserBalance public userBalanceContract;
    MainInterface public mainContract;


    modifier onlyTokenOwner(uint256 tokenId) {
        require(msg.sender == tokens[tokenId].owner, "Only token owner allowed");
        _;
    }

    constructor(address userBalanceAddress) public {
        userBalanceContract = UserBalance(userBalanceAddress);
    }

    function init() public onlyManager {
        tokens.push(RegionToken({
            regionId: 0,
            owner: address(0),
            tax: 0,
            regionName: "",
            isCanSale: false
        }));
    }

    function getTaxValue(
        uint16 regionId, uint8 cnt, uint256 basePrice, uint256 royalty
    ) external view returns (uint256) {
        return (
            (basePrice * tokens[regionMap[regionId]].tax) / 100
        ) +
        (
            (
                (cnt ** 2) * royalty * tokens[regionMap[regionId]].tax
            ) / 100
        );
    }

    function implementsERC721() public pure returns (bool) {
        return true;
    }

    function setMainContract(address _mainContractAddress) public onlyOwner {
        mainContract = MainInterface(_mainContractAddress);
    }

    function createRegion(uint16 regionId, address owner, string regionName, uint8 tax) public onlyManager {
        tokens.push(RegionToken({
            regionId: regionId,
            owner: address(0),
            tax: tax,
            regionName: regionName,
            isCanSale: owner != address(0)
        }));

        regionMap[regionId] = tokens.length - 1;

        _transfer(address(0), owner, tokens.length - 1);

        emit RegionChanged(regionMap[regionId], owner, regionName, tax, regionId, tokens[regionMap[regionId]].isCanSale);
    }

    function setOnRegularAuction(
        uint16 regionId, uint256 startPrice, uint256 minimalRaise
    ) public onlyTokenOwner(regionMap[regionId]) {
        _setOnRegularAuction(regionMap[regionId], startPrice, minimalRaise, msg.sender);
    }

    function transferRegularAuction(
        uint256 subjectId, uint256 startPrice, uint256 minimalRaise, uint256 activeTill, address buyer, uint256 currentBid, uint32 bidCount
    ) public onlyManager notOnAuction(subjectId) {
        require(tokens[subjectId].owner == address(0));

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.REGULAR;
        newAuction.minimalRaise = minimalRaise;
        newAuction.activeTill = activeTill;
        newAuction.buyer = buyer;
        newAuction.bid = currentBid;
        newAuction.bidCount = bidCount;
        newAuction.started = now;
        newAuction.seller = address(0);
        newAuction.transferPrice = currentBid;

        emit AuctionRegularTransfer(subjectId, address(0), startPrice, newAuction.activeTill, buyer, currentBid, bidCount, now);
    }


    function setOnAuctionByGameManager(
        uint16 regionId, uint256 startPrice, uint256 minimalRaise
    ) public onlyManager {
        uint256 tokenId = regionMap[regionId];
        require(tokens[tokenId].owner == address(0) && !_isOnAuction(tokenId));

        _setOnRegularAuction(tokenId, startPrice, minimalRaise, address(0));
    }

    function cancelAuction(uint16 regionId) public onlyTokenOwner(regionMap[regionId]) {
        _cancelAuction(regionMap[regionId]);
    }

    function setOnFixedAuction(uint16 regionId, uint256 startPrice) public onlyTokenOwner(regionMap[regionId]) {
        require(startPrice > 0);

        AuctionItem storage newAuction = activeAuctions[regionMap[regionId]];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.FIXED;
        newAuction.activeTill = 0;
        newAuction.started = now;
        newAuction.seller = msg.sender;
        emit AuctionFixedStart(regionMap[regionId], msg.sender, startPrice, now);
    }

    function setTax(uint16 _regionId, uint8 _tax) public onlyTokenOwner(regionMap[_regionId]) {
        tokens[regionMap[_regionId]].tax = _tax;

        emit RegionTaxUpdate(_regionId, _tax);
    }

    function getTax(uint16 regionId) public view returns (uint8) {
        return tokens[regionMap[regionId]].tax;
    }

    function getOwner(uint16 regionId) public view returns (address) {
        return tokens[regionMap[regionId]].owner;
    }

    function openForSale(uint16 regionId) public onlyTokenOwner(regionMap[regionId]) {
        require(!tokens[regionMap[regionId]].isCanSale);
        RegionToken storage region = tokens[regionMap[regionId]];
        region.isCanSale = true;

        emit RegionChanged(regionMap[regionId], region.owner, region.regionName, region.tax, regionId, region.isCanSale);
    }

    function sudoOpenForSale(uint16 regionId) public onlyManager {
        require(!tokens[regionMap[regionId]].isCanSale);
        RegionToken storage region = tokens[regionMap[regionId]];
        region.isCanSale = true;

        emit RegionChanged(regionMap[regionId], region.owner, region.regionName, region.tax, regionId, region.isCanSale);
    }

    function canSaleLands(uint16 regionId) external view returns (bool) {
        return tokens[regionMap[regionId]].isCanSale;
    }

    function payout(uint16 regionId, uint256 value, uint8 payoutType) public onlyManager {
        RegionToken memory region = tokens[regionMap[regionId]];
        if(region.owner != address(0) && value > 0) {
            _addToBalance(region.owner, value, 1);
            emit RegionPayout(regionId, value, payoutType);
        }
    }

    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal {
        if(_value > 0) {
            userBalanceContract.addBalance(_to, _value, _reason);
        }
    }


    function totalSupply() public view returns (uint256) {
        return tokens.length;
    }

    function balanceOf(address _owner) public view returns (uint256 balance) {
        balance = balances[_owner];
    }

    function ownerOf(uint256 _tokenId) public view returns (address owner) {
        owner = tokens[_tokenId].owner;
    }

    function approve(address _to, uint256 _tokenId) public onlyTokenOwner(_tokenId) {
        approved[_tokenId] = _to;
        emit Approval(msg.sender, _to, _tokenId);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) public notOnAuction(_tokenId) {
        require(approved[_tokenId] == _to, "Address not in approved list");
        _transfer(_from, _to, _tokenId);
    }

    function transfer(address _to, uint256 _tokenId) public onlyTokenOwner(_tokenId) notOnAuction(_tokenId) {
        _transfer(msg.sender, _to, _tokenId);
    }

    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        require(tokens[_tokenId].owner == _from,"Owner not correct");

        if(_from != address(0)) {
            balances[_from] -= 1;
        }

        tokens[_tokenId].owner = _to;
        approved[_tokenId] = address(0);
        balances[_to] += 1;
        emit Transfer(_from, _to, _tokenId);
    }

    function _toRegionShareBank(uint256 _tokenId, uint256 _value) internal {
        mainContract.addToRegionShareBank(tokens[_tokenId].regionId, int(_value));
        address(mainContract).transfer(_value);
    }

    function _toGlobalShareBank(uint256 _value) internal {
        mainContract.addToGlobalShareBankCallable(int(_value));
        address(mainContract).transfer(_value);
    }

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


    function _setOnRegularAuction(uint256 subjectId, uint256 startPrice, uint256 minimalRaise, address seller) internal notOnAuction(subjectId) onlyOnSale {
        require(startPrice > 0 && minimalRaise > 0);

        AuctionItem storage newAuction = activeAuctions[subjectId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.REGULAR;
        newAuction.minimalRaise = minimalRaise;
        newAuction.activeTill = now + auctionDuration;
        newAuction.started = now;
        newAuction.seller = seller;
        emit AuctionRegularStart(subjectId, seller, startPrice, newAuction.activeTill, now);
    }

    function makeAuctionBid(uint256 subjectId) public payable onlyOnSale {

        uint256 minimalBid = getMinimalBid(subjectId);
        require(minimalBid > 0 && msg.value >= minimalBid);
        require(activeAuctions[subjectId].buyer != msg.sender);

        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            require(activeAuctions[subjectId].activeTill == 0 || activeAuctions[subjectId].activeTill > now);
            address oldBuyer = activeAuctions[subjectId].buyer;
            uint256 oldBid = activeAuctions[subjectId].bid ;
            activeAuctions[subjectId].bidCount++;
            activeAuctions[subjectId].bid = msg.value;
            activeAuctions[subjectId].buyer = msg.sender;
            activeAuctions[subjectId].activeTill = now + auctionDuration;

            if(oldBuyer != address(0)) {
                if(!oldBuyer.send(oldBid)) {
                    _addToBalance(oldBuyer, oldBid, 7);
                }

                emit AuctionPayout(oldBuyer, oldBid, subjectId, 7);
            }


            emit AuctionBid(subjectId, msg.sender, activeAuctions[subjectId].activeTill, msg.value, activeAuctions[subjectId].bidCount);
        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.FIXED) {
            address oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            _auctionPayouts(subjectId, minimalBid, oldOwner, msg.sender, msg.value);

            emit AuctionWon(subjectId, msg.sender, minimalBid);

        } else {
            msg.sender.transfer(msg.value);
        }
    }

    function _auctionPayouts(uint256 subjectId, uint256 price, address seller, address buyer, uint256 value) internal {
        uint256 allFees = getFee(price) + getGlobalFee(price);

        if(seller != address(0)) {
            if(!seller.send(price - allFees)) {
                _addToBalance(seller, price - allFees, 3);
            }
            emit AuctionPayout(seller, price - allFees, subjectId, 3);
        }

        _toGlobalShareBank(getGlobalFee(price));

        if(price < value) {
            if(!buyer.send(value - price)) {
                _addToBalance(buyer, value - price, 7);
            }
            emit AuctionPayout(buyer, value - price, subjectId, 7);
        }

        beneficiary.transfer(getFee(price));
    }

    function getMinimalBid(uint256 subjectId) public view returns (uint256) {
        if(activeAuctions[subjectId].startPrice == 0) {
            return 0;
        }

        if(activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR) {
            if(activeAuctions[subjectId].bid == 0) {
                return activeAuctions[subjectId].startPrice;
            }

            return activeAuctions[subjectId].bid + activeAuctions[subjectId].minimalRaise;
        }  else if(activeAuctions[subjectId].auctionType == AuctionTypes.FIXED) {
            return activeAuctions[subjectId].startPrice;
        }

        return 0;
    }



    function claimAuction(uint256 subjectId) public {
        require(activeAuctions[subjectId].bidCount > 0 &&
            activeAuctions[subjectId].activeTill < now &&
            activeAuctions[subjectId].auctionType == AuctionTypes.REGULAR);

        address seller = activeAuctions[subjectId].seller;
        uint256 value = activeAuctions[subjectId].bid;
        uint256 transferPrice = activeAuctions[subjectId].transferPrice;
        address buyer = activeAuctions[subjectId].buyer;

        delete activeAuctions[subjectId];

        _transfer(seller, buyer, subjectId);
        uint256 allFees = getFee(value) + getGlobalFee(value) ;

        if(address(0) != seller) {
            if(!seller.send(value - allFees)) {
                _addToBalance(seller, value - allFees, 3);
            }
            emit AuctionPayout(seller, value - allFees, subjectId, 3);

            _toGlobalShareBank(getGlobalFee(value));

            beneficiary.transfer(getFee(value));

        } else if(value - transferPrice > 0){
            beneficiary.transfer(value - transferPrice);
        }

        emit AuctionWon(subjectId, buyer, value);

    }

    function getFee(uint256 value) internal view returns (uint256) {
        return (value * auctionFeePart) / 1000;
    }

    function getGlobalFee(uint256 value) internal view returns (uint256) {
        return (value * globalSharePart) / 1000;
    }


    event AuctionRegularTransfer(uint256 indexed subjectId, address indexed seller, uint256 startPrice, uint256 activeTill, address indexed buyer, uint256 bid, uint256 bidCount, uint256 started);
    event RegionChanged(uint256 tokenId, address owner, string regionName, uint8 tax, uint16 regionId, bool isCanSale);
    event RegionOpen(uint16 regionId);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event RegionPayout(uint16 regionId, uint256 value, uint8 payoutType);// 0 - buyLand, 1 - build & upgrade
    event RegionTaxUpdate(uint16 regionId, uint8 tax);
}
