pragma solidity 0.4.24;

import "./Manageable.sol";
import "./Land.sol";
import "./Region.sol";
import "./Influence.sol";
import "./UserBalance.sol";
import "./MainInterface.sol";


contract Main is Manageable, MainInterface {

    //enum TYPE_ID {NONE, RESOURCES, MINING, COMMERCIAL, RESIDENTIAL, PRODUCTION, OFFICE, ENERGY, UTILITIES}

    struct Requirements {
        uint8 typeId;
        uint8 targetLevel;
        uint8 range;
        uint8 count;
    }

    struct BuildingType {
        uint256[7] price;
    }


    mapping(uint16 => uint8) public buildings; // BuildingId => typeId
    mapping(uint8 => BuildingType) private buildingTypes;
    mapping(uint8 => mapping(uint8 => Requirements[])) public buildingRequirements;

    uint8 developerTax = 50;
    uint8 regionBankTax = 20;
    uint8 globalBankTax = 30;

    Land public landContract;
    Region public regionContract;
    Influence public influenceContract;
    UserBalance public userBalanceContract;

    uint256 public royalty = 0.001944 ether;
    uint256 public basePrice = 0.01 ether;

    constructor(address _land, address _region, address _influence, address _userBalance) public {
        landContract = Land(_land);
        regionContract = Region(_region);
        influenceContract = Influence(_influence);
        userBalanceContract = UserBalance(_userBalance);
    }

    modifier onlyLandOwner(int256 x, int256 y) {
        require(landContract.isLandOwner(x, y, msg.sender), "Only land owner");
        _;
    }

    function init() public onlyManager {
        landContract.init();
        influenceContract.init();
        regionContract.init();
    }

    function addBuildingType(uint8 typeId, uint256[7] price) public onlyManager {
        BuildingType storage newBuildingType = buildingTypes[typeId];
        newBuildingType.price = price;
    }

    function addBuilding(uint16 buildingId, uint8 typeId) public onlyManager {
        buildings[buildingId] = typeId;
    }

    function addRequirement(
        uint8 typeId, uint8 level, uint8[] count,
        uint8[] targetTypeId, uint8[] targetLevel, uint8[] range
    ) public onlyManager {
        Requirements[] storage requirements = buildingRequirements[typeId][level];
        for (uint256 i = 0; i < count.length; i++) {
            requirements.push(Requirements({
                typeId : targetTypeId[i],
                targetLevel : targetLevel[i],
                range : range[i],
                count : count[i]
            }));
        }
    }

    function getLandPrice(int256 x, int256 y) public view returns (uint256) {
        uint16 region = landContract.getRegion(x, y);

        if (!landContract.canBuy(x, y) || !regionContract.canSaleLands(region)) {
            return 0;
        }


        (uint256 landValue, uint8 tokensBought) = landContract.getPrice(x, y);

        uint256 royaltyValue = basePrice + (tokensBought ** 2) * royalty;

        uint256 taxValue = regionContract.getTaxValue(region, tokensBought, basePrice, royalty);

        return landValue + royaltyValue + taxValue;
    }

    function buyLand(int256 x, int256 y) public payable {
        require(landContract.canBuy(x, y), "Land cant be sold");

        (uint256 landValue, uint8 tokensBought) = landContract.getPrice(x, y);
        uint16 region = landContract.getRegion(x, y);

        require(regionContract.canSaleLands(region));

        uint256 royaltyValue = basePrice + (tokensBought ** 2) * royalty;
        uint256 taxValue = regionContract.getTaxValue(region, tokensBought, basePrice, royalty);

        uint256 totalValue = landValue + royaltyValue + taxValue;

        require(totalValue > 0 && msg.value >= totalValue, "Value is not enough");

        uint256 tokenId = landContract.createToken(x, y, msg.sender, totalValue);

        landContract.payout(x, y);
        regionContract.payout(region, taxValue);

        if(msg.value - totalValue > 0) {
            userBalanceContract.addBalance(msg.sender, msg.value - totalValue, 2);
        }

        emit LandBuy(tokenId, x, y, totalValue);
    }

    function influencePayoutSigned(uint256 period, uint256 value, bytes influenceSignature) public {
        uint256 payoutValue = influenceContract.convertToBalanceValueSigned(msg.sender, influenceSignature, value, period);
        userBalanceContract.addBalance(msg.sender, payoutValue, 4);
    }

    function influencePayout(uint16[] regionIds) public {
        int256 payoutValue = influenceContract.convertToBalanceValue(msg.sender, regionIds);
        if(payoutValue > 0){
            userBalanceContract.addBalance(msg.sender, uint(payoutValue), 4);
        }
    }


    function checkRequirements(int256 x, int256 y, uint16 buildingId, uint8 buildingLevel) public view returns (bool) {
        (uint16 currentBuilding, uint8 currentBuildingLevel) = landContract.getBuilding(x, y);
        if((currentBuilding != buildingId && currentBuilding != 0) || buildingLevel != currentBuildingLevel + 1) {
            return false;
        }

        uint8 typeId = buildings[buildingId];
        Requirements[] storage req = buildingRequirements[typeId][buildingLevel];
        for (uint256 i = 0; i < req.length; i++) {
            if (!landContract.checkBuilding(
                x, y,
                req[i].typeId,
                req[i].targetLevel,
                req[i].count,
                req[i].range
            )) {
                return false;
            }
        }

        return true;
    }

    function getMissedRequirementTypes(int256 x, int256 y, uint8 typeId, uint8 level) public view returns (uint8[8] counts, uint8[8] levels, uint8[8] ranges) {
        Requirements[] storage req = buildingRequirements[typeId][level];
        for (uint256 i = 0; i < req.length; i++) {
            uint8 reqCount = landContract.getBuildingsByType(
                x, y,
                req[i].typeId,
                req[i].targetLevel,
                req[i].range);

            counts[req[i].typeId - 1] =  reqCount > req[i].count ? 0 : req[i].count - reqCount;
            levels[req[i].typeId - 1] = req[i].targetLevel;
            ranges[req[i].typeId - 1] = req[i].range;
        }
    }

    function getBuildPrice(int256 x, int256 y, uint16 buildingId, uint8 buildingLevel) public view returns (uint256 value) {
        if(landContract.getTokenId(x, y) == 0) {
            return 0;
        }
        uint256 regionTax = regionContract.getTax(landContract.getRegion(x, y));

        uint256 baseBuildingPrice = buildingTypes[buildings[buildingId]].price[buildingLevel - 1];

        return baseBuildingPrice  + ((baseBuildingPrice * developerTax *  regionTax) / 10000) / 2;
    }

    function build(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel
    ) public payable onlyLandOwner(x, y) {
        uint256 buildingPrice = getBuildPrice(x, y, buildingId, buildingLevel);
        require((buildingPrice > 0 || buildingLevel == 0) && buildingPrice <= msg.value);
        require(buildingLevel == 0 || checkRequirements(x, y, buildingId, buildingLevel), "Requirements not satisfied");


        buildAndCalculateInfluences(x, y, buildingId, buildingLevel, buildingPrice);
        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
        }

        emit Builded(x, y, buildingId, buildingLevel);
    }

    function demolition(int256 x, int256 y) public onlyLandOwner(x, y) {
        buildAndCalculateInfluences(x, y, 0, 0, 0);
        emit Destroyed(x, y);
    }

    function buildAndCalculateInfluences(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel, uint256 buildingPrice
    ) internal {
        require(!landContract.isOnAuction(x, y));

        if(buildingId == 0) {
            (address owner, uint16 regionId) = landContract.demolition(x, y);
        } else {
            (owner, regionId) = landContract.build(x, y, buildingId, buildingLevel, buildings[buildingId]);
        }

        if(buildingPrice > 0) {
            influenceContract.addRegionShareBank(
                int(buildingTypes[buildings[buildingId]].price[buildingLevel - 1] * regionBankTax / 100),
                regionId
            );
            influenceContract.addGlobalShareBank(
                int(buildingTypes[buildings[buildingId]].price[buildingLevel - 1] * globalBankTax / 100)
            );
        }


        influenceContract.setType(x, y, buildings[buildingId], regionId, buildingLevel, owner);

        influenceContract.updateCellInfluence(x, y);
    }

    function userWithdrawal(uint256 value) public {
        msg.sender.transfer(userBalanceContract.userWithdrawal(value, msg.sender));
    }

    function userWithdrawal() public {
        uint256 value = userBalanceContract.getBalance(msg.sender);
        if(value > 0) {
            msg.sender.transfer(userBalanceContract.userWithdrawal(value, msg.sender));
        }
    }

    function transferCallback(int256 x, int256 y, uint16 regionId, address from, address to) external {
        require(msg.sender == address(landContract));

        influenceContract.moveToken(x, y, regionId, from, to);
    }

    event Log(uint256 data);
    event LandBuy(uint256 indexed tokenId, int256 x, int256 y, uint256 buyPrice);
    event Builded(int256 indexed x, int256 indexed y, uint16 buildingId, uint8 level);
    event Destroyed(int256 indexed x, int256 indexed y);
}
