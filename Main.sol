pragma solidity 0.4.25;

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
    mapping(uint16 => bool) public canBeHuge; // BuildingId => canBeHuge
    mapping(uint8 => BuildingType) private buildingTypes;
    mapping(uint8 => mapping(uint8 => Requirements[])) public buildingRequirements; // type => level => Requirements

    //Building fees
    uint8 developerTax = 20;
    uint8 regionBankTax = 40;
    uint8 globalBankTax = 40;

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

    function addBuilding(uint16 buildingId, uint8 typeId, bool isCanBeHuge) public onlyManager {
        buildings[buildingId] = typeId;
        canBeHuge[buildingId] = isCanBeHuge;
    }

    function addToGlobalShareBank() public payable {
        require(msg.value > 0);
        influenceContract.addGlobalShareBank(int(msg.value));
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
            emit OperationChange(msg.sender, msg.value - totalValue);
        }

        emit LandBuy(tokenId, x, y, totalValue);
    }

    function influencePayout(uint16[] regionIds) public {
        int256 payoutValue = influenceContract.convertToBalanceValue(msg.sender, regionIds);
        if(payoutValue > 0){
            userBalanceContract.addBalance(msg.sender, uint(payoutValue), 4);
            emit InfluencePayout(msg.sender, uint(payoutValue));
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

    function getRequirements(uint8 typeId, uint8 level) public view returns (uint8[8] counts, uint8[8] levels, uint8[8] ranges) {
        Requirements[] storage req = buildingRequirements[typeId][level];

        for (uint256 i = 0; i < req.length; i++) {
            counts[req[i].typeId - 1] = req[i].count;
            levels[req[i].typeId - 1] = req[i].targetLevel;
            ranges[req[i].typeId - 1] = req[i].range;
        }
    }

    function getMissedRequirementTypes(int256 x, int256 y, uint8 typeId, uint8 level) public view returns (uint8[8] counts, uint8[8] levels, uint8[8] ranges) {
        Requirements[] storage req = buildingRequirements[typeId][level];
        for (uint256 i = 0; i < req.length; i++) {
            uint8 reqCount = landContract.getBuildingsCountByType(
                x, y,
                req[i].typeId,
                req[i].targetLevel,
                req[i].range);

            counts[req[i].typeId - 1] =  reqCount > req[i].count ? 0 : req[i].count - reqCount;
            levels[req[i].typeId - 1] = req[i].targetLevel;
            ranges[req[i].typeId - 1] = req[i].range;
        }
    }

    function getBuildPrice(int256 x, int256 y, uint16 buildingId, uint8 buildingLevel) public view returns (uint256) {
        if(!landContract.canBuild(x, y)) {
            return 0;
        }
        uint256 regionTax = regionContract.getTax(landContract.getRegion(x, y));

        uint256 baseBuildingPrice = buildingTypes[buildings[buildingId]].price[buildingLevel - 1];

        return baseBuildingPrice  + ((baseBuildingPrice * developerTax *  regionTax) / 10000) / 2;
    }

    function getUpgradePrice(int256 x, int256 y) public view returns (uint256) {
        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x, y);

        uint256 regionTax = regionContract.getTax(landContract.getRegion(x, y));

        uint256 baseBuildingPrice = buildingTypes[buildings[buildingId]].price[buildingLevel];

        return baseBuildingPrice  + ((baseBuildingPrice * developerTax *  regionTax) / 10000) / 2;
    }

    function getBuildPrices(uint16 regionId) public view returns (uint256[9][9] prices) {

        uint256 regionTax = regionContract.getTax(regionId);

        for (uint8 i = 1; i < 9; i++) {
            for (uint256 j = 0; j < buildingTypes[i].price.length; j++) {
                uint256 baseBuildingPrice = buildingTypes[i].price[j];
                prices[i][j] = baseBuildingPrice  + ((baseBuildingPrice * developerTax *  regionTax) / 10000) / 2;
            }
        }
    }

    function build(
        int256 x, int256 y, uint16 buildingId
    ) public payable onlyLandOwner(x, y) {
        uint256 buildingPrice = getBuildPrice(x, y, buildingId, 1);
        require(buildingId > 0);
        require(buildingPrice > 0 && buildingPrice <= msg.value);
        require(checkRequirements(x, y, buildingId, 1), "Requirements not satisfied");

        uint32 seed = buildAndCalculateInfluences(x, y, buildingId, 1, buildingPrice);

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
            emit OperationChange(msg.sender, msg.value - buildingPrice);
        }

        emit Builded(x, y, buildingId, 1, seed);
    }

    function upgrade(int256 x, int256 y) public payable onlyLandOwner(x, y) {

        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x, y);
        require(buildingId > 0);
        require(buildingLevel < 5);

        uint256 buildingPrice = getBuildPrice(x, y, buildingId, buildingLevel + 1);

        require(buildingPrice <= msg.value);
        require(checkRequirements(x, y, buildingId, buildingLevel + 1), "Requirements not satisfied");

        buildAndCalculateInfluences(x, y, buildingId, buildingLevel + 1, buildingPrice);
        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
            emit OperationChange(msg.sender, msg.value - buildingPrice);
        }

        emit Builded(x, y, buildingId, buildingLevel + 1, 0);
    }

    function upgradeToHuge(int256[2] x, int256[2] y) public payable {
        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x[0], y[0]);

        require(canBeHuge[buildingId]);

        uint256 buildingPrice = getBuildPrice(x[0], y[0], buildingId, 6);
        require(msg.value >= buildingPrice);

        (uint8 master, uint8 orientation) = landContract.mergeToken2x(x, y, msg.sender);
        (address owner, uint16 regionId,) = landContract.build(x[master], y[master], buildingId, buildingLevel, buildings[buildingId]);

        influenceContract.addRegionShareBank(
            int(buildingTypes[buildings[buildingId]].price[6] * regionBankTax / 100),
            regionId
        );
        influenceContract.addGlobalShareBank(
            int(buildingTypes[buildings[buildingId]].price[6] * globalBankTax / 100)
        );

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
            emit OperationChange(msg.sender, msg.value - buildingPrice);
        }

        influenceContract.setType(x[0], y[0], buildings[buildingId], regionId, 6, owner);
        influenceContract.setType(x[1], y[1], buildings[buildingId], regionId, 6, owner);
        influenceContract.updateCellInfluence(x[0], y[0]);
        influenceContract.updateCellInfluence(x[1], y[1]);

        emit BigBuildingBuilded(x[master], y[master], orientation);
    }

    function upgradeToMega(int256[4] x, int256[4] y) public payable {

        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x[0], y[0]);
        require(canBeHuge[buildingId]);

        uint256 buildingPrice = getBuildPrice(x[0], y[0], buildingId, 6);
        require(msg.value >= buildingPrice);

        uint8 base = landContract.mergeToken4x(x, y, msg.sender);

        (address owner, uint16 regionId, ) = landContract.build(x[base], y[base], buildingId, buildingLevel, buildings[buildingId]);

        influenceContract.addRegionShareBank(
            int(buildingTypes[buildings[buildingId]].price[6] * regionBankTax / 100),
            regionId
        );

        influenceContract.addGlobalShareBank(
            int(buildingTypes[buildings[buildingId]].price[6] * globalBankTax / 100)
        );

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
            emit OperationChange(msg.sender, msg.value - buildingPrice);
        }

        for(uint8 i = 0; i < 4; i++) {
            influenceContract.setType(x[i], y[i], buildings[buildingId], regionId, 6, owner);
            influenceContract.updateCellInfluence(x[i], y[i]);
        }

        emit BigBuildingBuilded(x[base], y[base], 3);
    }

    function demolition(int256 x, int256 y) public onlyLandOwner(x, y) {
        landContract.demolition(x, y);
        influenceContract.markForDemolition(x, y);
        influenceContract.updateCellInfluence(x, y);

        emit Destroyed(x, y);
    }

    function demolitionHuge(int256 x, int256 y) public onlyLandOwner(x, y) {
        (int[2] memory xr, int[2] memory yr) = landContract.demolitionHuge(x, y);
        for(uint8 i = 0; i < xr.length; i++) {
            influenceContract.markForDemolition(xr[i], yr[i]);
            influenceContract.updateCellInfluence(xr[i], yr[i]);
            emit Destroyed(xr[i], yr[i]);
        }
    }

    function demolitionMega(int256 x, int256 y) public onlyLandOwner(x, y) {
        (int[4] memory xr, int[4] memory yr) = landContract.demolitionMega(x, y);
        for(uint8 i = 0; i < xr.length; i++) {
            influenceContract.markForDemolition(xr[i], yr[i]);
            influenceContract.updateCellInfluence(xr[i], yr[i]);
            emit Destroyed(xr[i], yr[i]);
        }
    }

    function buildAndCalculateInfluences(
        int256 x, int256 y, uint16 buildingId, uint8 buildingLevel, uint256 buildingPrice
    ) internal returns (uint32) {
        require(!landContract.isOnAuction(x, y));

        (address owner, uint16 regionId, uint32 seed) = landContract.build(x, y, buildingId, buildingLevel, buildings[buildingId]);

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

        return seed;
    }

    function setResourcesInfluence(int256 x, int256 y, uint16 regionId, uint8 resources, address owner) external {
        require(msg.sender == address(landContract));

        _setResourcesInfluence(x, y, regionId, resources, owner);
    }

    function _setResourcesInfluence(int256 x, int256 y, uint16 regionId, uint8 resources, address owner) internal {
        influenceContract.setType(x, y, landContract.RESOURCES_TYPE_ID(), regionId, resources, owner);
    }

    function addToRegionShareBank(uint16 regionId, int256 value) external {
        require(msg.sender == address(landContract) || msg.sender == address(regionContract));
        influenceContract.addRegionShareBank(value, regionId);
    }

    function userWithdrawal(uint256 value) public {
        userBalanceContract.userWithdrawal(value, msg.sender);
        require(address(this).balance >= value);
        msg.sender.transfer(value);
    }

    function userWithdrawal() public {
        uint256 value = userBalanceContract.getBalance(msg.sender);
        require(value > 0 && address(this).balance >= value);
        userBalanceContract.userWithdrawal(value, msg.sender);
        if(value > 0) {
            msg.sender.transfer(value);
        }
    }

    function transferCallback(int256 x, int256 y, uint16 regionId, address from, address to) external {
        require(msg.sender == address(landContract));

        influenceContract.moveToken(x, y, regionId, from, to);
    }

    function () public payable {
        require(msg.sender == address(landContract) || msg.sender == address(regionContract));
    }


    event OperationChange(address user, uint256 value);
    event LandBuy(uint256 indexed tokenId, int256 x, int256 y, uint256 buyPrice);
    event Builded(int256 indexed x, int256 indexed y, uint16 buildingId, uint8 level, uint32 seed);
    event Destroyed(int256 indexed x, int256 indexed y);
    event BigBuildingBuilded(int256 base_x, int256 base_y, uint8 orientation);
    event InfluencePayout(address user, uint256 value);
}
