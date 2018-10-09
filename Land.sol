pragma solidity 0.4.25;

import "./UserBalance.sol";
import "./MainInterface.sol";
import "./Auction.sol";


contract Land is Auction {


    struct MapCell {
        uint8 resources;
        uint16 region;
        uint256 tokenId;
        uint256 buyPrice;
    }

    struct LandToken {
        address owner;
        uint8 tokenType;// 0 - Regular, 1 - horisontal merged, 2 - vertical merged, 3 - 4x merged
        uint16 buildingId;
        uint32 seed;
        uint8 buildingLevel;
        uint8 typeId;
        int64 x;
        int64 y;
        //Basic token always with biggest x and y
    }


    mapping(int64 => mapping(int64 => MapCell)) public map;

    mapping(uint256 => address) public approved;
    mapping(address => uint256) public balances;

    LandToken[] public tokens;

    uint8 public divider = 8;

    UserBalance public userBalanceContract;
    MainInterface public mainContract;

    uint8 defaultRadius = 5;

    uint8 public RESOURCES_TYPE_ID = 2;

    uint32 public auctionStepInterval = 1 hours;
    uint32 public auctionFeePart =  0.025*1000; // 2.5%
    uint32 public regionSharePart = 0.025*1000;
    uint32 public shareBeneficiaryPart = 0.025*1000;

    modifier onlyTokenOwner(uint256 tokenId) {
        require(msg.sender == tokens[tokenId].owner);
        _;
    }

    constructor(address userBalanceAddress) public {
        userBalanceContract = UserBalance(userBalanceAddress);
    }

    function init() external onlyManager {
        //Reserve 0 token
        tokens.push(LandToken({
            owner : address(0),
            tokenType: 0,
            buildingId: 0,
            seed: 0,
            typeId: 0,
            buildingLevel: 0,
            x: 0,
            y: 0
        }));
    }

    function setMainContract(address _mainContractAddress) public onlyOwner {
        mainContract = MainInterface(_mainContractAddress);
    }

    function createToken(int64 x, int64 y, address owner, uint256 buyPrice) external onlyManager returns(uint256) {
        map[x][y].buyPrice = buyPrice;
        map[x][y].tokenId = _createToken(x, y, owner);

        return map[x][y].tokenId;
    }

    function _createToken(int64 x, int64 y, address owner) internal returns(uint256){
        tokens.push(LandToken({
            owner : owner,
            tokenType: 0,
            buildingId: 0,
            seed: 0,
            typeId: map[x][y].resources > 0 ? RESOURCES_TYPE_ID : 0,
            buildingLevel: map[x][y].resources > 0 ? map[x][y].resources : 0,
            x: x,
            y: y
        }));

        if(map[x][y].resources > 0) {
            mainContract.setResourcesInfluence(x, y, map[x][y].region, map[x][y].resources, owner);
        }

        emit Transfer(address(0), owner, tokens.length - 1);

        return tokens.length - 1;
    }


    function mintLand(int64[] x, int64[] y, uint256[] buyPrice, address[] owner, uint16 regionId) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            if(map[x[i]][y[i]].tokenId == 0) {
                map[x[i]][y[i]] = MapCell({
                    resources: map[x[i]][y[i]].resources,
                    region: regionId,
                    tokenId: tokens.length,
                    buyPrice: buyPrice[i]
                });

                tokens.push(LandToken({
                    owner : owner[i],
                    tokenType: 0,
                    buildingId: 0,
                    seed: 0,
                    typeId: map[x[i]][y[i]].resources > 0 ? RESOURCES_TYPE_ID : 0,
                    buildingLevel: map[x[i]][y[i]].resources > 0 ? map[x[i]][y[i]].resources : 0,
                    x: x[i],
                    y: y[i]
                }));

                if(map[x[i]][y[i]].resources > 0) {
                    mainContract.setResourcesInfluence(x[i], y[i], map[x[i]][y[i]].region, map[x[i]][y[i]].resources, owner[i]);
                }

                emit Transfer(address(0), owner[i], tokens.length - 1);
            }
        }
    }

    function setOnAuction(uint256 tokenId, uint256 startPrice, uint256 endPrice, uint32 duration) public onlyTokenOwner(tokenId) {
        require(startPrice > 0 && endPrice > 0);
        require(duration >= 1 days && duration <= 90 days);

        AuctionItem storage newAuction = activeAuctions[tokenId];
        newAuction.startPrice = startPrice;
        newAuction.endPrice = endPrice;
        newAuction.auctionType = AuctionTypes.STEP;
        newAuction.activeTill = now + duration;
        newAuction.started = now;
        newAuction.seller = msg.sender;
        newAuction.shareBeneficiary = mainContract.regionOwner(map[tokens[tokenId].x][tokens[tokenId].y].region);
        emit AuctionStepStart(tokenId, msg.sender, startPrice, endPrice, newAuction.started, newAuction.activeTill);
    }

    function setOnFixedAuction(uint256 tokenId, uint256 startPrice) public onlyTokenOwner(tokenId) {
        require(startPrice > 0);

        AuctionItem storage newAuction = activeAuctions[tokenId];
        newAuction.startPrice = startPrice;
        newAuction.auctionType = AuctionTypes.FIXED;
        newAuction.activeTill = 0;
        newAuction.started = now;
        newAuction.seller = msg.sender;
        newAuction.shareBeneficiary = mainContract.regionOwner(map[tokens[tokenId].x][tokens[tokenId].y].region);
        emit AuctionFixedStart(tokenId, msg.sender, startPrice, now);
    }

    function cancelAuction(uint256 tokenId) public onlyTokenOwner(tokenId) {
        _cancelAuction(tokenId);
    }

    function payout(int64 x, int64 y) external onlyManager {
        for (int64 xi = x - 3; xi <= x + 3; xi++) {
            for (int64 yi = y - 3; yi <= y + 3; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }
                if (map[xi][yi].buyPrice > 0) {
                    _addToBalance(
                        tokens[map[xi][yi].tokenId].owner,
                        map[xi][yi].buyPrice / divider, 0);

                     emit LandPayout(tokens[map[xi][yi].tokenId].owner, xi, yi, map[xi][yi].buyPrice / divider);
                }
            }
        }
    }

    function isOnAuction(int64 x, int64 y) external view returns (bool) {
        return _isOnAuction(map[x][y].tokenId);
    }

    function canBuild(int64 x, int64 y) external view returns (bool) {
        return map[x][y].tokenId != 0 && map[x][y].resources == 0 && !_isOnAuction(map[x][y].tokenId);
    }

    function _build(
        int64 x, int64 y, uint16 buildingId, uint8 buildingLevel, uint8 typeId
    ) internal returns (address, uint16)  {
        require(map[x][y].tokenId != 0 && map[x][y].resources == 0 && !_isOnAuction(map[x][y].tokenId));
        uint256 tokenId = map[x][y].tokenId;
        tokens[tokenId].buildingId = buildingId;
        tokens[tokenId].buildingLevel = buildingLevel;
        tokens[tokenId].typeId = typeId;

        if(buildingId == 1) {
            tokens[tokenId].seed = uint32(keccak256(abi.encodePacked(now * uint(block.coinbase) * uint(x) / uint(y) + tokens.length)));
        }

        if(buildingLevel > 5) {
            emit BigBuildingBuilded(tokenId, x, y, tokens[tokenId].tokenType);
        } else {
            emit Builded(tokenId, x, y, buildingId, buildingLevel, tokens[tokenId].seed);
        }


        return (tokens[map[x][y].tokenId].owner, map[x][y].region);
    }

    function build(
        int64 x, int64 y, uint16 buildingId, uint8 buildingLevel, uint8 typeId
    ) external onlyManager returns (address, uint16) {
        return _build(x, y, buildingId, buildingLevel, typeId);
    }

    function upgradeToHuge(int64[2] x, int64[2] y, address owner) external onlyManager returns (uint16) {
        _mergeToken2x(x, y, owner);
        _build(x[0], y[0], tokens[map[x[0]][y[0]].tokenId].buildingId, 6, tokens[map[x[0]][y[0]].tokenId].typeId);
        return map[x[0]][y[0]].region;
    }

    function upgradeToMega(int64[4] x, int64[4] y, address owner) external onlyManager returns (uint16) {
        _mergeToken4x(x, y, owner);
        _build(x[0], y[0], tokens[map[x[0]][y[0]].tokenId].buildingId, 7, tokens[map[x[0]][y[0]].tokenId].typeId);
        return map[x[0]][y[0]].region;
    }

    function demolition(int64 x, int64 y) external onlyManager returns (uint8 orientation) {
        require(!_isOnAuction(map[x][y].tokenId));
        require(map[x][y].resources == 0 && tokens[map[x][y].tokenId].buildingLevel > 0);
        orientation = tokens[map[x][y].tokenId].tokenType;
        uint256 tokenId = map[x][y].tokenId;
        LandToken storage baseToken = tokens[tokenId];

        if(baseToken.tokenType == 0) {
            tokens[tokenId].buildingId = 0;
            tokens[tokenId].buildingLevel = 0;
            tokens[tokenId].typeId = 0;
            tokens[tokenId].tokenType = 0;
            emit Destroyed(x, y);
            return;
        }


        if(tokens[map[x][y].tokenId].tokenType == 1) {
            require(tokenId == map[x - 1][y].tokenId);
            map[x - 1][y].tokenId = _createToken(x - 1, y, tokens[map[x - 1][y].tokenId].owner);

            _build(x - 1, y, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);


            emit Destroyed(x, y);
        } else if(tokens[map[x][y].tokenId].tokenType == 2) {
            require(tokenId == map[x][y - 1].tokenId);
            map[x][y - 1].tokenId = _createToken(x, y - 1, tokens[map[x][y - 1].tokenId].owner);
            _build(x, y - 1, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);

        } else if(tokens[map[x][y].tokenId].tokenType == 3) {
            require(
                tokenId    == map[x]    [y - 1].tokenId
                && tokenId == map[x - 1][y    ].tokenId
                && tokenId == map[x - 1][y - 1].tokenId
            );

            map[x - 1][y].tokenId = _createToken(x - 1, y, tokens[map[x][y].tokenId].owner);
            _build(x - 1, y, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);

            map[x][y - 1].tokenId = _createToken(x, y - 1, tokens[map[x][y].tokenId].owner);
            _build(x, y - 1, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);

            map[x - 1][y - 1].tokenId = _createToken(x - 1, y - 1, tokens[map[x][y].tokenId].owner);
            _build(x - 1, y - 1, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);

        }

        baseToken.tokenType = 0;
        _build(x, y, tokens[tokenId].buildingId, 5, tokens[tokenId].typeId);
    }

    function getPrice(int64 x, int64 y) external view returns (uint256 value, uint8 tokensBought) {
        if (map[x][y].tokenId != 0) {
            return (0, 0);
        }

        for (int64 xi = x - 3; xi <= x + 3; xi++) {
            for (int64 yi = y - 3; yi <= y + 3; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }

                if (map[xi][yi].buyPrice > 0) {
                    value += (map[xi][yi].buyPrice / divider);
                    tokensBought++;
                }
            }
        }
    }

    function getOwner(int64 x, int64 y) external view returns (address) {
        return tokens[map[x][y].tokenId].owner;
    }

    function canBuy(int64 x, int64 y) external view returns (bool) {
        return map[x][y].tokenId == 0 && map[x][y].region != 0;
    }

    function getBuyPrice(int64 x, int64 y) external view returns (uint256) {
        return map[x][y].buyPrice;
    }

    function implementsERC721() public pure returns (bool) {
        return true;
    }

    function mintMap(int64[] x, int64[] y, uint16 region) public onlyManager {//Only one region per call
        for (uint256 i = 0; i < x.length; i++) {
            map[x[i]][y[i]].region = region;
        }
    }

    function setResources(int64[] x, int64[] y, uint8[] resources) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            map[x[i]][y[i]].resources = resources[i];
        }
    }

    function getRegion(int64 x, int64 y) public view returns (uint16) {
        return map[x][y].region;
    }

    function checkBuilding(
        int64 x, int64 y, uint16 typeId, uint8 buildingLevel, uint8 count, uint8 range
    ) public view returns (bool) {
        uint8 cnt = count;
        for (int64 xi = x - range; xi <= x + range; xi++) {
            for (int64 yi = y - range; yi <= y + range; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }
                if(typeId == RESOURCES_TYPE_ID && map[xi][yi].resources > 0) {
                    if(cnt <= map[xi][yi].resources) {
                        return true;
                    }

                    cnt = cnt - map[xi][yi].resources;
                } else if (tokens[map[xi][yi].tokenId].typeId == typeId && tokens[map[xi][yi].tokenId].buildingLevel >= buildingLevel) {
                    cnt--;
                }

                if (cnt == 0) {
                    return true;
                }
            }
        }

        return false;
    }

    function _mergeToken2x(int64[2] x, int64[2] y, address owner) internal {
        LandToken storage master = tokens[map[x[0]][y[0]].tokenId];
        LandToken storage slave = tokens[map[x[1]][y[1]].tokenId];

        require(
            slave.owner == owner &&
            master.owner == owner,
            "Only same correct owner"
        );

        require(
            master.buildingLevel == 5 &&
            slave.buildingLevel == 5 &&
            master.typeId == slave.typeId &&
            master.typeId != RESOURCES_TYPE_ID
        );

        master.tokenType = x[0] != x[1] ? 1 : 2;

        _trashToken(map[x[1]][y[1]].tokenId);

        map[x[1]][y[1]].tokenId = map[x[0]][y[0]].tokenId;
    }

    function _mergeToken4x(
        int64[4] x, int64[4] y, address owner
    ) internal {
        LandToken storage master = tokens[map[x[0]][y[0]].tokenId];
        require(master.owner == owner && master.buildingLevel == 5 && master.tokenType == 0 && master.typeId != RESOURCES_TYPE_ID);

        for (uint8 i = 1; i < 4; i++) {
            require(
                tokens[map[x[i]][y[i]].tokenId].owner == master.owner &&
                tokens[map[x[i]][y[i]].tokenId].tokenType == 0
            );
            require(
                tokens[map[x[i]][y[i]].tokenId].buildingLevel == 5 &&
                tokens[map[x[i]][y[i]].tokenId].typeId == master.typeId
            );

            _trashToken(map[x[i]][y[i]].tokenId);

            map[x[i]][y[i]].tokenId = map[x[0]][y[0]].tokenId;
        }

        master.tokenType = 3;
    }

    function getBuildingsCountByType(
        int64 x, int64 y, uint8 typeId, uint8 levelAtleast, uint8 range
    ) external view returns (uint8 count) {
        for (int64 xi = x - range; xi <= x + range; xi++) {
            for (int64 yi = y - range; yi <= y + range; yi++) {
                if(RESOURCES_TYPE_ID == typeId && map[xi][yi].resources > 0) {
                    count = count + map[xi][yi].resources;
                } else if (tokens[map[xi][yi].tokenId].typeId == typeId && tokens[map[xi][yi].tokenId].buildingLevel >= levelAtleast) {
                    count++;
                }
            }
        }
    }

    function getBuildingsCount(int64 x, int64 y, uint8 range) external view returns (uint[8] types) {
        for (int64 xi = x - range; xi <= x + range; xi++) {
            for (int64 yi = y - range; yi <= y + range; yi++) {
                if(xi == x && yi == y) {
                    continue;
                }
                if(tokens[map[xi][yi].tokenId].typeId > 0) {
                    types[tokens[map[xi][yi].tokenId].typeId - 1]++;
                } else if(map[xi][yi].resources > 0) {
                    types[RESOURCES_TYPE_ID - 1] = types[RESOURCES_TYPE_ID - 1] + map[xi][yi].resources;
                }
            }
        }
    }

    function _toGlobalShareBank(uint256 _value) internal {
        mainContract.addToGlobalShareBankCallable(int(_value));
        address(mainContract).transfer(_value);
    }

    function _toRegionShareBank(uint256 _tokenId, uint256 _value) internal {
        mainContract.addToRegionShareBank(map[tokens[_tokenId].x][tokens[_tokenId].y].region, int(_value));
        address(mainContract).transfer(_value);
    }

    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal {
        if(_value > 0) {
            userBalanceContract.addBalance(_to, _value, _reason);
        }
    }

    function makeAuctionBid(uint256 subjectId) public payable onlyOnSale {

        uint256 minimalBid = getMinimalBid(subjectId);
        require(minimalBid > 0 && msg.value >= minimalBid);
        require(activeAuctions[subjectId].buyer != msg.sender);
        address shareBeneficiary = activeAuctions[subjectId].shareBeneficiary;

        if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
            address oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            _auctionPayouts(subjectId, minimalBid, oldOwner, shareBeneficiary, msg.sender, msg.value);

            emit AuctionWon(subjectId, msg.sender, minimalBid);
        } else if(activeAuctions[subjectId].auctionType == AuctionTypes.FIXED) {
            oldOwner = activeAuctions[subjectId].seller;

            delete activeAuctions[subjectId];
            _transfer(oldOwner, msg.sender, subjectId);

            _auctionPayouts(subjectId, minimalBid, oldOwner, shareBeneficiary, msg.sender, msg.value);

            emit AuctionWon(subjectId, msg.sender, minimalBid);

        } else {
            msg.sender.transfer(msg.value);
        }
    }

    function _auctionPayouts(uint256 subjectId, uint256 price, address seller, address shareBeneficiary, address buyer, uint256 value) internal {
        uint256 allFees = _getFee(price) + _getRegionFee(price) + _getShareBeneficiary(price);

        if(seller != address(0)) {
            if(!seller.send(price - allFees)) {
                _addToBalance(seller, price - allFees, 3);
            }
            emit AuctionPayout(seller, price - allFees, subjectId, 3);
        }

        _toRegionShareBank(subjectId, _getRegionFee(price));

        if(price < value) {
            if(!buyer.send(value - price)) {
                _addToBalance(buyer, value - price, 7);
            }

            emit AuctionPayout(buyer, value - price, subjectId, 7);
        }

        if(!shareBeneficiary.send(_getShareBeneficiary(price))) {
            _addToBalance(shareBeneficiary, _getShareBeneficiary(price), 6);
        }

        emit AuctionPayout(shareBeneficiary, _getShareBeneficiary(price), subjectId, 6);

        beneficiary.transfer(_getFee(price));
    }

    function getMinimalBid(uint256 subjectId) public view returns (uint256) {
        if(activeAuctions[subjectId].startPrice == 0) {
            return 0;
        }

        if(activeAuctions[subjectId].auctionType == AuctionTypes.STEP) {
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

    function _getFee(uint256 value) internal view returns (uint256) {
        return (value * auctionFeePart) / 1000;
    }

    function _getRegionFee(uint256 value) internal view returns (uint256) {
        return (value * regionSharePart) / 1000;
    }

    function _getShareBeneficiary(uint256 value) internal view returns (uint256) {
        return (value * shareBeneficiaryPart) / 1000;
    }

    function getResources(int64 x, int64 y) external view returns (uint8) {
        return map[x][y].resources;
    }

    function getBuilding(int64 x, int64 y) external view returns (uint16, uint8) {
        return map[x][y].tokenId == 0 ? (0,0) : (tokens[map[x][y].tokenId].buildingId, tokens[map[x][y].tokenId].buildingLevel);
    }

    function isLandOwner(int64 x, int64 y, address addr) public view returns (bool) {
        return tokens[map[x][y].tokenId].owner == addr;
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

    function _trashToken(uint256 _tokenId) internal notOnAuction(_tokenId) {
        address _from = tokens[_tokenId].owner;
        tokens[_tokenId].owner = address(0);
        approved[_tokenId] = address(0);
        balances[_from] -= 1;
        delete tokens[_tokenId];
        emit Transfer(_from, address(0), _tokenId);
    }

    function _transfer(address _from, address _to, uint256 _tokenId) internal notOnAuction(_tokenId) {
        require(tokens[_tokenId].owner == _from, "Owner not correct");

        if(_from != address(0)) {
            mainContract.transferCallback(tokens[_tokenId].x, tokens[_tokenId].y, map[tokens[_tokenId].x][tokens[_tokenId].y].region, _from, _to);
        }

        tokens[_tokenId].owner = _to;
        approved[_tokenId] = address(0);
        if(_from != address(0)) {
            balances[_from] -= 1;
        }
        balances[_to] += 1;
        emit Transfer(_from, _to, _tokenId);
    }



    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event LandPayout(address indexed owner, int64 x, int64 y, uint256 value);
    event Builded(uint256 indexed tokenId, int64 indexed x, int64 indexed y, uint16 buildingId, uint8 level, uint32 seed);
    event Destroyed(int64 indexed x, int64 indexed y);
    event BigBuildingBuilded(uint256 tokenId, int64 base_x, int64 base_y, uint8 orientation);

}
