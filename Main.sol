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


    mapping(uint16 => uint8) public buildings; // BuildingId => typeId
    mapping(uint8 => uint256[7]) private buildingPrices;
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

    modifier onlyLandOwner(int64 x, int64 y) {
        require(landContract.isLandOwner(x, y, msg.sender), "Only land owner");
        _;
    }

    function init() public onlyManager {
        landContract.init();
        influenceContract.init();
        regionContract.init();
    }

    function openSale() public onlyManager {
        landContract.setSaleOpen();
        influenceContract.setSaleOpen();
        regionContract.setSaleOpen();
        setSaleOpen();
    }

    function addBuildingType(uint8 typeId, uint256[7] price) public onlyManager {
        buildingPrices[typeId] = price;
    }

    function addBuildingPrices(uint8[] typeId, uint256[7][] price) public onlyManager {
        for(uint256 i = 0; i < typeId.length; i++) {
            buildingPrices[typeId[i]] = price[i];
        }

    }

    function addBuildings(uint16[] buildingIds, uint8[] typeIds) public onlyManager {
        for(uint256 i = 0; i < buildingIds.length; i++) {
            buildings[buildingIds[i]] = typeIds[i];
        }
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

    function getLandPrice(int64 x, int64 y) public view returns (uint256) {
        uint16 region = landContract.getRegion(x, y);

        if (!landContract.canBuy(x, y) || !regionContract.canSaleLands(region)) {
            return 0;
        }


        (uint256 landValue, uint8 tokensBought) = landContract.getPrice(x, y);

        uint256 royaltyValue = basePrice + (tokensBought ** 2) * royalty;

        uint256 taxValue = regionContract.getTaxValue(region, tokensBought, basePrice, royalty);

        return landValue + royaltyValue + taxValue;
    }

    function buyLand(int64 x, int64 y) public payable onlyOnSale {
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
        regionContract.payout(region, taxValue, 0);

        if(msg.value - totalValue > 0) {
            userBalanceContract.addBalance(msg.sender, msg.value - totalValue, 2);
        }

        beneficiary.transfer(royaltyValue);

        emit LandBuy(tokenId, x, y, totalValue);
    }

    function influencePayout(uint16[] regionIds) public {
        int256 payoutValue = influenceContract.convertToBalanceValue(msg.sender, regionIds);
        if(payoutValue > 0){
            userBalanceContract.addBalance(msg.sender, uint(payoutValue), 4);
            emit InfluencePayout(msg.sender, uint(payoutValue));
        }
    }


    function checkRequirements(int64 x, int64 y, uint16 buildingId, uint8 buildingLevel) public view returns (bool) {
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

    function getMissedRequirementTypes(int64 x, int64 y, uint8 typeId, uint8 level) public view returns (uint8[8] counts, uint8[8] levels, uint8[8] ranges) {
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

    function getBuildPrice(int64 x, int64 y, uint16 buildingId, uint8 buildingLevel) public view returns (uint256 fullPrice) {
        if(!landContract.canBuild(x, y)) {
            return 0;
        }
        uint256 regionTax = regionContract.getTax(landContract.getRegion(x, y));

        uint256 baseBuildingPrice = buildingPrices[buildings[buildingId]][buildingLevel - 1];

        return baseBuildingPrice  + (baseBuildingPrice  *  regionTax) / 200;
    }

    function _getBuildPrice(uint16 buildingId, uint8 buildingLevel, uint16 regionId) internal view returns (uint256 fullPrice, uint256 regionFee) {
        uint256 regionTax = regionContract.getTax(regionId);

        uint256 baseBuildingPrice = buildingPrices[buildings[buildingId]][buildingLevel - 1];

        fullPrice = baseBuildingPrice  + (baseBuildingPrice  *  regionTax) / 200;
        regionFee = (baseBuildingPrice  *  regionTax) / 200;
    }

    function getUpgradePrice(int64 x, int64 y) public view returns (uint256) {
        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x, y);

        uint256 regionTax = regionContract.getTax(landContract.getRegion(x, y));

        uint256 baseBuildingPrice = buildingPrices[buildings[buildingId]][buildingLevel];

        return baseBuildingPrice  + (baseBuildingPrice  *  regionTax) / 200;
    }

    function getBuildPrices(uint16 regionId) public view returns (uint256[9][9] prices) {

        uint256 regionTax = regionContract.getTax(regionId);

        for (uint8 i = 1; i < 9; i++) {
            for (uint256 j = 0; j < buildingPrices[i].length; j++) {
                uint256 baseBuildingPrice = buildingPrices[i][j];
                prices[i][j] = baseBuildingPrice  + (baseBuildingPrice  *  regionTax) / 200;
            }
        }
    }

    function build(
        int64 x, int64 y, uint16 buildingId
    ) public payable onlyLandOwner(x, y) {
        require(landContract.canBuild(x, y));
        uint16 regionId = landContract.getRegion(x, y);
        (uint256 buildingPrice, uint256 regionFee) = _getBuildPrice(buildingId, 1, regionId);

        require(buildingId > 0);
        require(buildingPrice > 0 && buildingPrice <= msg.value);
        require(checkRequirements(x, y, buildingId, 1), "Requirements not satisfied");

        _buildAndCalculateInfluences(x, y, buildingId, 1, buildingPrice);

        regionContract.payout(regionId, regionFee, 1);

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
        }

        beneficiary.transfer(getFee(buildingPrices[buildings[buildingId]][0]));
    }

    function upgrade(int64 x, int64 y) public payable onlyLandOwner(x, y) {
        require(landContract.canBuild(x, y));
        (uint16 buildingId, uint8 buildingLevel) = landContract.getBuilding(x, y);

        require(buildingId > 0);
        require(buildingLevel < 5);

        uint16 regionId = landContract.getRegion(x, y);
        (uint256 buildingPrice, uint256 regionFee) = _getBuildPrice(buildingId, buildingLevel + 1, regionId);

        require(buildingPrice <= msg.value);
        require(checkRequirements(x, y, buildingId, buildingLevel + 1), "Requirements not satisfied");

        _buildAndCalculateInfluences(x, y, buildingId, buildingLevel + 1, buildingPrice);

        regionContract.payout(regionId, regionFee, 1);

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
        }

        beneficiary.transfer(getFee(buildingPrices[buildings[buildingId]][buildingLevel]));
    }

    function upgradeToHuge(int64 x, int64 y, bool isHorisontal) public payable {
        require(landContract.canBuild(x, y));
        (uint16 buildingId, ) = landContract.getBuilding(x, y);

        uint16 regionId = landContract.getRegion(x, y);
        (uint256 buildingPrice, uint256 regionFee) = _getBuildPrice(buildingId, 6, regionId);


        require(msg.value >= buildingPrice);

        int64[2] memory xToMerge = isHorisontal ? [x, x]     : [x, x - 1];
        int64[2] memory yToMerge = isHorisontal ? [y, y - 1] : [y, y];

        landContract.upgradeToHuge(xToMerge, yToMerge, msg.sender);

        influenceContract.addRegionShareBank(
            int(buildingPrices[buildings[buildingId]][5] * regionBankTax / 100),
            regionId
        );
        influenceContract.addGlobalShareBank(
            int(buildingPrices[buildings[buildingId]][5] * globalBankTax / 100)
        );

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
        }

        regionContract.payout(regionId, regionFee, 1);

        influenceContract.setLevelAndUpdate(xToMerge[0], yToMerge[0], 6);
        influenceContract.setLevelAndUpdate(xToMerge[1], yToMerge[1], 6);

        beneficiary.transfer(getFee(buildingPrices[buildings[buildingId]][5]));

    }

    function upgradeToMega(int64 x, int64 y) public payable {
        require(landContract.canBuild(x, y));

        (uint16 buildingId, ) = landContract.getBuilding(x, y);

        uint16 regionId = landContract.getRegion(x, y);
        (uint256 buildingPrice, uint256 regionFee) = _getBuildPrice(buildingId, 7, regionId);

        require(msg.value >= buildingPrice);

        int64[4] memory xToMerge = [x, x,     x - 1, x - 1];
        int64[4] memory yToMerge = [y, y - 1, y,     y - 1];


        landContract.upgradeToMega(xToMerge, yToMerge, msg.sender);

        influenceContract.addRegionShareBank(
            int(buildingPrices[buildings[buildingId]][6] * regionBankTax / 100),
            regionId
        );

        influenceContract.addGlobalShareBank(
            int(buildingPrices[buildings[buildingId]][6] * globalBankTax / 100)
        );

        if(msg.value > buildingPrice) {
            userBalanceContract.addBalance(msg.sender, msg.value - buildingPrice, 2);
        }

        regionContract.payout(regionId, regionFee, 1);

        for(uint8 i = 0; i < 4; i++) {
            influenceContract.setLevelAndUpdate(xToMerge[i], yToMerge[i], 7);
        }

        beneficiary.transfer(getFee(buildingPrices[buildings[buildingId]][6]));

    }

    function demolition(int64 x, int64 y) public onlyLandOwner(x, y) {
        uint8 orientation = landContract.demolition(x, y);
        if(orientation == 0) {
            influenceContract.markForDemolitionAndUpdate(x, y);
            return;
        }

        if(orientation == 1) {
            influenceContract.setLevelAndUpdate(x - 1, y, 5);
        } else if(orientation == 2) {
            influenceContract.setLevelAndUpdate(x, y - 1, 5);
        } else if(orientation == 3) {
            influenceContract.setLevelAndUpdate(x - 1, y, 5);
            influenceContract.setLevelAndUpdate(x, y - 1, 5);
            influenceContract.setLevelAndUpdate(x - 1, y - 1, 5);
        }

        if(orientation > 0) {
            influenceContract.setLevelAndUpdate(x, y, 5);
        }

    }

    function _buildAndCalculateInfluences(
        int64 x, int64 y, uint16 buildingId, uint8 buildingLevel, uint256 buildingPrice
    ) internal {
        require(!landContract.isOnAuction(x, y));

        (address owner, uint16 regionId) = landContract.build(x, y, buildingId, buildingLevel, buildings[buildingId]);

        if(buildingPrice > 0) {
            influenceContract.addRegionShareBank(
                int(buildingPrices[buildings[buildingId]][buildingLevel - 1] * regionBankTax / 100),
                regionId
            );
            influenceContract.addGlobalShareBank(
                int(buildingPrices[buildings[buildingId]][buildingLevel - 1] * globalBankTax / 100)
            );

        }


        if(buildingLevel == 1) {
            influenceContract.setTypeAndUpdate(x, y, buildings[buildingId], regionId, buildingLevel, owner);
        } else {
            influenceContract.setLevelAndUpdate(x, y, buildingLevel);
        }
    }

    function setResourcesInfluence(int64 x, int64 y, uint16 regionId, uint8 resources, address owner) external {
        require(msg.sender == address(landContract));
        if(saleOpen) {
            influenceContract.setTypeAndUpdate(x, y, 2, regionId, resources, owner);
        } else {
            influenceContract.setType(x, y, 2, regionId, resources, owner);
        }
    }

    function addToRegionShareBank(uint16 regionId, int256 value) external {
        require(msg.sender == address(landContract) || msg.sender == address(regionContract));
        influenceContract.addRegionShareBank(value, regionId);
    }

    function addToGlobalShareBankCallable(int256 value) external {
        require(msg.sender == address(landContract) || msg.sender == address(regionContract));
        influenceContract.addGlobalShareBank(value);
    }

    function sendToBeneficiary(uint256 value) external {
        require(msg.sender == address(landContract) || msg.sender == address(regionContract));
        beneficiary.transfer(value);
    }

    function userWithdrawal() public {
        uint256 value = userBalanceContract.getBalance(msg.sender);
        require(value > 0 && address(this).balance >= value);
        userBalanceContract.userWithdrawal(value, msg.sender);
        if(value > 0) {
            msg.sender.transfer(value);
        }
    }

    function setTax(uint8 _developerTax, uint8 _regionBankTax, uint8 _globalBankTax) public onlyOwner {
        require(_developerTax + _regionBankTax + _globalBankTax == 100);
        developerTax = _developerTax;
        regionBankTax = _regionBankTax;
        globalBankTax = _globalBankTax;
    }

    function getFee(uint256 value) internal view returns (uint256) {
        return developerTax * value / 100;
    }

    function regionOwner(uint16 regionId) external returns (address){
        return regionContract.getOwner(regionId);
    }

    function transferCallback(int64 x, int64 y, uint16 regionId, address from, address to) external {
        require(msg.sender == address(landContract));

        influenceContract.moveToken(x, y, regionId, from, to);
    }

    function () public payable {
        if(msg.sender != address(landContract) && msg.sender != address(regionContract)) {
            influenceContract.addGlobalShareBank(int(msg.value));
        }
    }


    event LandBuy(uint256 indexed tokenId, int64 x, int64 y, uint256 buyPrice);
    event InfluencePayout(address user, uint256 value);
}
