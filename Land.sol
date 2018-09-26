pragma solidity 0.4.25;

import "./Manageable.sol";
import "./UserBalance.sol";
import "./MainInterface.sol";
import "./Auction.sol";


contract Land is Manageable, Auction {



    struct MapCell {
        uint8 resources;
        uint16 region;
        uint256 tokenId;
        uint256 buyPrice;
    }

    struct Coordinates {
        int256 x;
        int256 y;
    }

    struct LandToken {
        address owner;
        uint16 buildingId;
        uint8 buildingLevel;
        uint8 typeId;
        uint8 tokenType;// 0 - Regular, 1 - horisontal merged, 2 - vertical merged, 3 - 4x merged
        uint32 seed;
        //Basic token always with biggest x and y
    }


    mapping(int256 => mapping(int256 => MapCell)) public map;
    mapping(uint256 => Coordinates) public mapReverse;

    mapping(uint256 => Coordinates[]) public merged; // tokenId =>

    mapping(uint256 => address) public approved;
    mapping(address => uint256) public balances;

    LandToken[] public tokens;

    uint8 public divider = 8;

    bool public deployMode = true;

    UserBalance public userBalanceContract;
    MainInterface public mainContract;

    uint8 defaultRadius = 5;

    uint8 public RESOURCES_TYPE_ID = 2;
    uint8 public LEVEL_FOR_BIG_BUILDING = 5;

    modifier notNullAddress(address _address) {
        require(address(0) != _address);
        _;
    }

    modifier onlyTokenOwner(uint256 tokenId) {
        require(msg.sender == tokens[tokenId].owner);
        _;
    }

    constructor(address userBalanceAddress) public {
        userBalanceContract = UserBalance(userBalanceAddress);
        isStepAuctionAllowed = true;
        isFixedAuctionAllowed = true;
        isRegionShareEnabled = true;
    }

    function init() external onlyManager {
        //Reserve 0 token
        tokens.push(LandToken({
            owner : address(0),
            buildingId : 0,
            buildingLevel : 0,
            typeId : 0,
            tokenType: 0,
            seed: 0
        }));
    }

    function setMainContract(address _mainContractAddress) public onlyOwner {
        mainContract = MainInterface(_mainContractAddress);
    }

    function _createToken(int256 x, int256 y, address owner, uint256 buyPrice) internal returns(uint256){
        tokens.push(LandToken({
            owner : address(0),
            buildingId : 0,
            buildingLevel : map[x][y].resources,
            typeId : map[x][y].resources > 0 ? RESOURCES_TYPE_ID : 0,
            tokenType: 0,
            seed: 0
        }));

        if(buyPrice > 0) {
            map[x][y].buyPrice = buyPrice;
        }
        map[x][y].tokenId = tokens.length - 1;
        mapReverse[map[x][y].tokenId] = Coordinates({x : x, y : y});
        _transfer(address(0), owner, map[x][y].tokenId);

        if(map[x][y].resources > 0) {
            mainContract.setResourcesInfluence(x, y, map[x][y].region, map[x][y].resources, owner);
        }

        emit LandOwned(x, y, map[x][y].tokenId);
        return tokens.length - 1;
    }


    function createToken(int256 x, int256 y, address owner, uint256 buyPrice) external onlyManager returns(uint256) {
        return _createToken(x, y, owner, buyPrice);
    }

    function mintLand(int256[] x, int256[] y, uint256[] buyPrice, address[] owner) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            _createToken(x[i], y[i], owner[i], buyPrice[i]);
        }
    }

    function setOnAuction(uint256 tokenId, uint256 startPrice, uint256 endPrice, uint32 duration) public onlyTokenOwner(tokenId) {
        _setOnStepAuction(tokenId, startPrice, endPrice, msg.sender, duration);
    }

    function setOnFixedAuction(uint256 tokenId, uint256 startPrice) public onlyTokenOwner(tokenId) {
        _setOnFixedAuction(tokenId, startPrice, msg.sender);
    }

    function cancelAuction(uint256 tokenId) public onlyTokenOwner(tokenId) {
        _cancelAuction(tokenId);
    }

    function payout(int256 x, int256 y) external onlyManager {
        for (int256 xi = x - 3; xi <= x + 3; xi++) {
            for (int256 yi = y - 3; yi <= y + 3; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }
                if (map[xi][yi].buyPrice > 0) {
                    userBalanceContract.addBalance(
                        tokens[map[xi][yi].tokenId].owner,
                        map[xi][yi].buyPrice / divider, 0);

                     emit LandPayout(tokens[map[xi][yi].tokenId].owner, xi, yi, map[xi][yi].buyPrice / divider);
                }
            }
        }
    }

    function isOnAuction(int256 x, int256 y) external view returns (bool) {
        return _isOnAuction(map[x][y].tokenId);
    }

    function canBuild(int256 x, int256 y) external view returns (bool) {
        return map[x][y].tokenId != 0 && map[x][y].resources == 0;
    }

    function _build(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel, uint8 typeId
    ) internal returns (address, uint16)  {
        require(map[x][y].resources == 0);
        require(!_isOnAuction(map[x][y].tokenId));
        tokens[map[x][y].tokenId].buildingId = buildingId;
        tokens[map[x][y].tokenId].buildingLevel = buildingLevel;
        tokens[map[x][y].tokenId].typeId = typeId;

        if(buildingId == 1) {
            tokens[map[x][y].tokenId].seed = _createSeed(x, y);
        }

        if(buildingLevel > 5) {
            emit BigBuildingBuilded(map[x][y].tokenId, x, y, tokens[map[x][y].tokenId].tokenType);
        } else {
            emit Builded(map[x][y].tokenId, x, y, buildingId, buildingLevel, tokens[map[x][y].tokenId].seed);
        }


        return (tokens[map[x][y].tokenId].owner, map[x][y].region);
    }

    function build(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel, uint8 typeId
    ) external onlyManager returns (address, uint16) {
        return _build(x, y, buildingId, buildingLevel, typeId);
    }

    function upgradeToHuge(int256[2] x, int256[2] y, address owner) external onlyManager returns (uint16) {
        LandToken storage baseToken = tokens[map[x[0]][y[0]].tokenId];
        mergeToken2x(x, y, owner);
        _build(x[0], y[0], baseToken.buildingId, 6, baseToken.typeId);
        return map[x[0]][y[0]].region;
    }

    function upgradeToMega(int256[4] x, int256[4] y, address owner) external onlyManager returns (uint16) {
        LandToken storage baseToken = tokens[map[x[0]][y[0]].tokenId];
        mergeToken4x(x, y, owner);
        _build(x[0], y[0], baseToken.buildingId, 7, baseToken.typeId);
        return map[x[0]][y[0]].region;
    }

    function demolition(int256 x, int256 y) external onlyManager returns (uint8 orientation) {
        require(!_isOnAuction(map[x][y].tokenId));
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
            _createToken(x - 1, y, tokens[map[x - 1][y].tokenId].owner, 0);
            _build(x - 1, y, baseToken.buildingId, 5, baseToken.typeId);


            emit Destroyed(x, y);
        } else if(tokens[map[x][y].tokenId].tokenType == 2) {
            require(tokenId == map[x][y - 1].tokenId);
            _createToken(x, y - 1, tokens[map[x][y - 1].tokenId].owner, 0);
            _build(x, y - 1, baseToken.buildingId, 5, baseToken.typeId);

        } else if(tokens[map[x][y].tokenId].tokenType == 3) {
            require(
                tokenId    == map[x]    [y - 1].tokenId
                && tokenId == map[x - 1][y    ].tokenId
                && tokenId == map[x - 1][y - 1].tokenId
            );

            _createToken(x - 1, y, tokens[map[x][y].tokenId].owner, 0);
            _build(x - 1, y, baseToken.buildingId, 5, baseToken.typeId);

            _createToken(x, y - 1, tokens[map[x][y].tokenId].owner, 0);
            _build(x, y - 1, baseToken.buildingId, 5, baseToken.typeId);

            _createToken(x - 1, y - 1, tokens[map[x][y].tokenId].owner, 0);
            _build(x - 1, y - 1, baseToken.buildingId, 5, baseToken.typeId);

        }

        if(baseToken.tokenType > 0) {
            baseToken.tokenType = 0;
            _build(x, y, baseToken.buildingId, 5, baseToken.typeId);
        }
    }

    function getTypeIds(
        int256 x, int256 y
    ) external view returns (uint8[121] data) {
        uint256 iteration = 0;
        for (int256 xi = x - defaultRadius; xi <= x + defaultRadius; xi++) {
            for (int256 yi = x - defaultRadius; yi <= x + defaultRadius; yi++) {
                data[iteration] = tokens[map[x][y].tokenId].typeId;
                iteration++;
            }
        }
    }

    function getPrice(int256 x, int256 y) external view returns (uint256 value, uint8 tokensBought) {
        if (map[x][y].tokenId != 0) {
            return (0, 0);
        }

        for (int256 xi = x - 3; xi <= x + 3; xi++) {
            for (int256 yi = y - 3; yi <= y + 3; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }

                if (map[xi][yi].tokenId > 0) {
                    value += (map[xi][yi].buyPrice / divider);
                    tokensBought++;
                }
            }
        }
    }

    function getOwnerAndRegionByCoordinates(int256 x, int256 y) external view returns (address, uint16) {
        return (tokens[map[x][y].tokenId].owner, map[x][y].region);
    }

    function getOwner(int256 x, int256 y) external view returns (address) {
        return tokens[map[x][y].tokenId].owner;
    }

    function canBuy(int256 x, int256 y) external view returns (bool) {
        return map[x][y].tokenId == 0 && map[x][y].region != 0;
    }

    function implementsERC721() public pure returns (bool) {
        return true;
    }

    function mintMap(int256[] x, int256[] y, uint16 region) public onlyManager {//Only one region per call
        for (uint256 i = 0; i < x.length; i++) {
            map[x[i]][y[i]].region = region;
        }
    }

    function setResources(int256[] x, int256[] y, uint8[] resources) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            map[x[i]][y[i]].resources = resources[i];
        }
    }



    function getRegion(int256 x, int256 y) public view returns (uint16) {
        return map[x][y].region;
    }

    function checkBuilding(
        int256 x, int256 y, uint16 typeId, uint8 buildingLevel, uint8 count, uint8 range
    ) public view returns (bool) {
        uint8 cnt = count;
        for (int256 xi = x - range; xi <= x + range; xi++) {
            for (int256 yi = y - range; yi <= y + range; yi++) {
                if (x == xi && y == yi) {
                    continue;
                }
                if ((tokens[map[xi][yi].tokenId].typeId == typeId &&
                    tokens[map[xi][yi].tokenId].buildingLevel >= buildingLevel)
                        || (typeId == RESOURCES_TYPE_ID && map[xi][yi].resources >= buildingLevel)) {
                    cnt--;
                }

                if (cnt == 0) {
                    return true;
                }
            }
        }

        return false;
    }

    function mergeToken2x(int256[2] x, int256[2] y, address owner) internal {

        require(
            tokens[map[x[0]][y[0]].tokenId].owner == tokens[map[x[1]][y[1]].tokenId].owner &&
            tokens[map[x[0]][y[0]].tokenId].owner == owner,
            "Only same correct owner"
        );

        require(
            tokens[map[x[0]][y[0]].tokenId].buildingLevel == LEVEL_FOR_BIG_BUILDING && tokens[map[x[1]][y[1]].tokenId].buildingLevel == LEVEL_FOR_BIG_BUILDING
            && tokens[map[x[0]][y[0]].tokenId].typeId == tokens[map[x[1]][y[1]].tokenId].typeId
        );

        tokens[map[x[0]][y[0]].tokenId].tokenType = x[0] != x[1] ? 1 : 2;

        _trashToken(map[x[1]][y[1]].tokenId);

        delete mapReverse[map[x[1]][y[1]].tokenId];
        map[x[1]][y[1]].tokenId = map[x[0]][y[0]].tokenId;
    }

    function mergeToken4x(
        int256[4] x, int256[4] y, address owner
    ) internal {
        for (uint8 i = 0; i < 4; i++) {
            require(
                tokens[map[x[i]][y[i]].tokenId].owner == owner &&
                tokens[map[x[i]][y[i]].tokenId].tokenType == 0,
                "Only same correct owner and not merged"
            );
            require(map[x[i]][y[i]].resources == 0, "Resources not allowed");
            require(
                tokens[map[x[i]][y[i]].tokenId].buildingLevel == LEVEL_FOR_BIG_BUILDING
                && tokens[map[x[0]][y[0]].tokenId].typeId == tokens[map[x[i]][y[i]].tokenId].typeId
            );
        }

        tokens[map[x[0]][y[0]].tokenId].tokenType = 3;
        for (i = 1; i < 4; i++) {
            _trashToken(map[x[i]][y[i]].tokenId);
            delete mapReverse[map[x[i]][y[i]].tokenId];
            map[x[i]][y[i]].tokenId = map[x[0]][y[0]].tokenId;
        }
    }

    function getBuildingsCountByType(
        int256 x, int256 y, uint8 typeId, uint8 levelAtleast, uint8 range
    ) external view returns (uint8 count) {
        for (int256 xi = x - range; xi <= x + range; xi++) {
            for (int256 yi = y - range; yi <= y + range; yi++) {
                if ( (tokens[map[xi][yi].tokenId].typeId == typeId && tokens[map[xi][yi].tokenId].buildingLevel >= levelAtleast)
                    || (RESOURCES_TYPE_ID == typeId && map[xi][yi].resources >= levelAtleast)
                ) {
                    count++;
                }
            }
        }
    }

    function getBuildingsCount(int256 x, int256 y, uint8 range) external view returns (uint[8] types) {
        for (int256 xi = x - range; xi <= x + range; xi++) {
            for (int256 yi = y - range; yi <= y + range; yi++) {
                if(xi == x && yi == y) {
                    continue;
                }
                if(tokens[map[xi][yi].tokenId].typeId > 0) {
                    types[tokens[map[xi][yi].tokenId].typeId - 1]++;
                } else if(map[xi][yi].resources > 0) {
                    types[RESOURCES_TYPE_ID - 1]++;
                }
            }
        }
    }

    function _createSeed(int256 x, int256 y) internal view returns (uint32) {
        return uint32(keccak256(abi.encodePacked(now * uint(block.coinbase) * uint(x) / uint(y) + tokens.length)));
    }

    function getResources(int256 x, int256 y) external view returns (uint8) {
        return map[x][y].resources;
    }

    function getTokenId(int256 x, int256 y) external view returns (uint256) {
        return map[x][y].tokenId;
    }

    function getBuyPrice(int256 x, int256 y) external view returns (uint256) {
        return map[x][y].buyPrice;
    }

    function getBuilding(int256 x, int256 y) external view returns (uint16, uint8) {
        return map[x][y].tokenId == 0 ? (0,0) : (tokens[map[x][y].tokenId].buildingId, tokens[map[x][y].tokenId].buildingLevel);
    }

    function isLandOwner(int256 x, int256 y, address addr) public view returns (bool) {
        return tokens[map[x][y].tokenId].owner == addr;
    }

    function endDeploy() public onlyManager {
        deployMode = false;
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

    function transferFrom(address _from, address _to, uint256 _tokenId) public {
        require(approved[_tokenId] == _to, "Address not in approved list");
        _transfer(_from, _to, _tokenId);
    }

    function transfer(address _to, uint256 _tokenId) public onlyTokenOwner(_tokenId) {
        _transfer(msg.sender, _to, _tokenId);
    }

    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal {
        userBalanceContract.addBalance(_to, _value, _reason);
    }

    function _toRegionShareBank(uint256 _tokenId, int256 _value) internal {
        mainContract.addToRegionShareBank(map[mapReverse[_tokenId].x][mapReverse[_tokenId].y].region, _value);
    }

    function _trashToken(uint256 _tokenId) internal notOnAuction(_tokenId) {
        address _from = tokens[_tokenId].owner;
        tokens[_tokenId].owner = address(0);
        approved[_tokenId] = address(0);
        balances[_from] -= 1;
        emit Transfer(_from, address(0), _tokenId);
    }

    function _transfer(address _from, address _to, uint256 _tokenId) internal notOnAuction(_tokenId) {
        require(tokens[_tokenId].owner == _from, "Owner not correct");

        if(_from != address(0)) {
            mainContract.transferCallback(mapReverse[_tokenId].x, mapReverse[_tokenId].y, map[mapReverse[_tokenId].x][mapReverse[_tokenId].y].region, _from, _to);
        }

        tokens[_tokenId].owner = _to;
        approved[_tokenId] = address(0);
        if(_from != address(0)) {
            balances[_from] -= 1;
        }
        balances[_to] += 1;
        emit Transfer(_from, _to, _tokenId);
    }

    function _transferEther() internal {
        address(mainContract).transfer(address(this).balance);
    }
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event LandOwned(int256 x, int256 y, uint256 tokenId);
    event LandPayout(address indexed owner, int256 x, int256 y, uint256 value);
    event Builded(uint256 indexed tokenId, int256 indexed x, int256 indexed y, uint16 buildingId, uint8 level, uint32 seed);
    event Destroyed(int256 indexed x, int256 indexed y);
    event DestroyedWithCreateToken(uint256 tokenId, int256 indexed x, int256 indexed y);
    event BigBuildingBuilded(uint256 tokenId, int256 base_x, int256 base_y, uint8 orientation);

}
