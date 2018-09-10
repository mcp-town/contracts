pragma solidity 0.4.24;

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
        uint8 resources;
        uint8 tokenType;// 0 - Regular, 1 - Vertical merged, 2 - horisontal merged, 3 - 4x merged
        //Basic token always with highest x and y
    }


    mapping(int256 => mapping(int256 => MapCell)) public map;
    mapping(uint256 => Coordinates) public mapReverse;

    mapping(uint256 => address) public approved;
    mapping(address => uint256) public balances;

    LandToken[] public tokens;

    uint8 public divider = 8;

    bool public deployMode = true;

    UserBalance public userBalanceContract;
    MainInterface public mainContract;

    uint8 defaultRadius = 5;

    uint8 RESOURCES_TYPE_ID = 2;

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
    }

    function init() external onlyManager {
        //Reserve 0 token
        tokens.push(LandToken({
            owner : address(0),
            buildingId : 0,
            buildingLevel : 0,
            typeId : 0,
            resources : 0,
            tokenType: 0
        }));
    }

    function setMainContract(address _mainContractAddress) public onlyOwner {
        mainContract = MainInterface(_mainContractAddress);
    }


    function createToken(int256 x, int256 y, address owner, uint256 buyPrice) external onlyManager returns(uint256) {
        tokens.push(LandToken({
            owner : address(0),
            buildingId : 0,
            buildingLevel : 0,
            typeId : map[x][y].resources > 0 ? RESOURCES_TYPE_ID : 0,
            resources : map[x][y].resources,
            tokenType: 0
        }));

        map[x][y].buyPrice = buyPrice;
        map[x][y].tokenId = tokens.length - 1;
        mapReverse[tokens.length - 1] = Coordinates({x : x, y : y});
        _transfer(address(0), owner, tokens.length - 1);
        emit LandOwned(x, y, tokens.length - 1);
        return tokens.length - 1;
    }


    function setOnAuction(uint256 tokenId, uint256 startPrice, uint256 endPrice, uint32 duration) public onlyTokenOwner(tokenId) {
        _setOnStepAuction(tokenId, startPrice, endPrice, msg.sender, duration);
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
        return isOnAuction(map[x][y].tokenId);
    }

    function build(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel, uint8 typeId
    ) external onlyManager returns (address owner, uint16 regionId) {
        require(!isOnAuction(map[x][y].tokenId));
        tokens[map[x][y].tokenId].buildingId = buildingId;
        tokens[map[x][y].tokenId].buildingLevel = buildingLevel;
        tokens[map[x][y].tokenId].typeId = typeId;

        return (tokens[map[x][y].tokenId].owner, map[x][y].region);
    }

    function demolition(int256 x, int256 y) external onlyManager returns (address owner, uint16 regionId) {
        require(!isOnAuction(map[x][y].tokenId));
        tokens[map[x][y].tokenId].buildingId = 0;
        tokens[map[x][y].tokenId].buildingLevel = 0;
        tokens[map[x][y].tokenId].typeId = 0;

        return (tokens[map[x][y].tokenId].owner, map[x][y].region);
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
            MapCell storage tmpCell = map[x[i]][y[i]];
            tmpCell.region = region;
        }
    }

    function setResources(int256[] x, int256[] y, uint8[] resources) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            map[x[i]][y[i]].resources = resources[i];
        }
    }

    function mintLand(int256[] x, int256[] y, uint256[] buyPrice, address[] owner) public onlyManager {
        for (uint256 i = 0; i < x.length; i++) {
            tokens.push(LandToken({
                owner : owner[i],
                buildingId : 0,
                buildingLevel : 0,
                typeId : 0,
                resources : map[x[i]][y[i]].resources,
                tokenType : 0
            }));

            map[x[i]][y[i]].buyPrice = buyPrice[i];
            map[x[i]][y[i]].tokenId = tokens.length - 1;
            mapReverse[tokens.length - 1] = Coordinates({x : x[i], y : y[i]});
            emit LandOwned(x[i], y[i], tokens.length - 1);
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

    function mergeTokensVertical(
        int256 x1, int256 y1, int256 x2, int256 y2, address owner
    ) external onlyManager returns (int256 destroyedX, int256 destroyedY) {
        require(x1 == x2 && (y1 - 1 == y2 || y1 == y2 - 1), "Only nearby alowed");
        require(
            tokens[map[x1][y1].tokenId].owner == tokens[map[x2][y2].tokenId].owner &&
            tokens[map[x1][y1].tokenId].owner == owner,
            "Only same correct owner"
        );
        require(tokens[map[x1][y1].tokenId].tokenType == 0 && tokens[map[x2][y2].tokenId].tokenType == 0, "Only not merged");
        require(map[x1][y1].resources == 0 && map[x2][y2].resources == 0, "Resources not allowed");

        if(y1 > y2) {
            tokens[map[x1][y1].tokenId].tokenType = 1;
            delete mapReverse[map[x2][y2].tokenId];
            _transfer(owner, address(0), map[x2][y2].tokenId);
            map[x2][y2].tokenId = map[x1][y1].tokenId;
            return (x2, y2);
        } else {
            tokens[map[x2][y2].tokenId].tokenType = 1;
            delete mapReverse[map[x1][y1].tokenId];
            _transfer(owner, address(0), map[x1][y1].tokenId);
            map[x1][y1].tokenId = map[x2][y2].tokenId;
            return (x1, y1);
        }
    }

    function mergeTokensHorisontal(
        int256 x1, int256 y1, int256 x2, int256 y2, address owner
    ) external onlyManager returns (int256 destroyedX, int256 destroyedY) {
        require(y1 == y2 && (x1 - 1 == x2 || x1 == x2 - 1), "Only nearby alowed");
        require(
            tokens[map[x1][y1].tokenId].owner == owner &&
            tokens[map[x2][y2].tokenId].owner == owner,
            "Only same correct owner"
        );
        require(tokens[map[x1][y1].tokenId].tokenType == 0 && tokens[map[x2][y2].tokenId].tokenType == 0, "Only not merged");
        require(map[x1][y1].resources == 0 && map[x2][y2].resources == 0, "Resources not allowed");

        if(x1 > x2) {
            tokens[map[x1][y1].tokenId].tokenType = 1;
            delete mapReverse[map[x2][y2].tokenId];
            _transfer(owner, address(0), map[x2][y2].tokenId);
            map[x2][y2].tokenId = map[x1][y1].tokenId;
            return (x2, y2);
        } else {
            tokens[map[x2][y2].tokenId].tokenType = 1;
            delete mapReverse[map[x1][y1].tokenId];
            _transfer(owner, address(0), map[x1][y1].tokenId);
            map[x1][y1].tokenId = map[x2][y2].tokenId;
            return (x1, y1);
        }
    }

    function mergeToken4x(
        int256[4] x, int256[4] y, address owner
    ) external onlyManager returns (uint8 baseCellIndex) { //Returns index of base cell
        for (uint8 i = 0; i < 4; i++) {
            require(
                tokens[map[x[i]][y[i]].tokenId].owner == owner &&
                tokens[map[x[i]][y[i]].tokenId].tokenType == 0,
                "Only same correct owner and not merged"
            );
            require(map[x[i]][y[i]].resources == 0, "Resources not allowed");

            if(i == 0) {
                for(uint8 j = 1; j < 4; j++) {
                    if(x[i] > x[j]) {
                        require(x[i] - x[j] == 1 && (y[i] - y[j] == 1 || y[i] - y[j] == -1 || y[i] - y[j] == 0));
                    } else if(x[i] == x[j]) {
                        require(y[i] - y[j] == 1 || y[i] - y[j] == -1);
                    } else {
                        require(x[j] - x[i] == 1 && (y[i] - y[j] == 1 || y[i] - y[j] == -1 || y[i] - y[j] == 0));
                    }
                }
            }
        }
        Coordinates memory base;
        uint8 baseIndex;
        base.x = x[0];
        base.y = y[0];
        for (i = 0; i < 4; i++) {
            if (x[i] > base.x && y[i] > base.y) {
                base.x = x[i];
                base.y = y[i];
                baseIndex = i;
            }
        }
        tokens[map[x[baseIndex]][y[baseIndex]].tokenId].tokenType = 3;
        for (i = 0; i < 4; i++) {
            if (baseIndex == i) {
                continue;
            }

            delete mapReverse[map[x[i]][y[i]].tokenId];
            _transfer(owner, address(0), map[x[i]][y[i]].tokenId);
            map[x[i]][y[i]].tokenId = map[x[baseIndex]][y[baseIndex]].tokenId;
        }

        return baseIndex;
    }

    function getBuildingsByType(
        int256 x, int256 y, uint8 typeId, uint8 levelAtleast, uint8 range
    ) public view returns (uint8 count) {
        for (int256 xi = x - range; xi <= x + range; xi++) {
            for (int256 yi = y - range; yi <= y + range; yi++) {
                if ( (tokens[map[xi][yi].tokenId].typeId == typeId && tokens[map[xi][yi].tokenId].buildingId >= levelAtleast)
                    || (RESOURCES_TYPE_ID == typeId && map[xi][yi].resources > levelAtleast)
                ) {
                    count++;
                }
            }
        }
    }

    function getTokenId(int256 x, int256 y) public view returns (uint256) {
        return map[x][y].tokenId;
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

    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        require(tokens[_tokenId].owner == _from, "Owner not correct");
        require(activeAuctions[_tokenId].activeTill == 0);

        if(_from != address(0)) {
            mainContract.transferCallback(mapReverse[_tokenId].x, mapReverse[_tokenId].y, map[mapReverse[_tokenId].x][mapReverse[_tokenId].y].region, _from, _to);
        }
        tokens[_tokenId].owner = _to;
        approved[_tokenId] = address(0);
        balances[_from] -= 1;
        balances[_to] += 1;
        emit Transfer(_from, _to, _tokenId);
    }

    function _transferEther(uint256 value) internal {
        address(mainContract).transfer(value);
    }

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event LandOwned(int256 x, int256 y, uint256 tokenId);
    event LandPayout(address indexed owner, int256 x, int256 y, uint256 value);
}
