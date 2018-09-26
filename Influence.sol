pragma solidity 0.4.25;

import "./Manageable.sol";


contract Influence is Manageable {

    struct InfluenceSideEffect {
        uint8 typeId;
        bool penalty;
        uint8 numberAffects;
        uint8 startFrom;
        int64 value;
    }

    struct MapCell {
        uint8 typeId;
        uint8 level;
        uint16 regionId;
        address owner;
        int256 influence;
        uint256 types;//Building types in 5 cell radius (8 bit for each type)
    }

    uint256 lastTotalInfluenceChange;

    mapping(uint256 => int256) public totalInfluence; // period => influence
    mapping(uint16 => mapping(uint256 => int256)) public regionsInfluence;// regionId => period => influence
    mapping(uint16 => uint256) public lastRegionInfluenceChange; //regionId => period
    mapping(address => mapping(uint16 => mapping(uint256 => int256))) public userRegionInfluence; // user => regionId => period => influence
    mapping(address => mapping(uint16 => uint256)) public lastUserRegionInfluenceChange; // user => regionId => period

    mapping(uint256 => int256) public globalShareBank; // period => ether
    mapping(uint16 => mapping(uint256 => int256)) public regionShareBank; // region => period => ether
    mapping(uint256 => int256) public periodsIncome; // period => ether

    mapping(address => uint256) public lastConversion; // user => conversion period

    mapping(int256 => mapping(int256 => MapCell)) public influenceMap; // x => y => cell

    mapping(uint8 => InfluenceSideEffect[]) public influenceSideEffect;//buildingTypeId => side effect [max 10]
    mapping(uint8 => mapping(uint8 => int256)) public multipliers; //building type => level => influence
    mapping(uint8 => int256) public baseInfluences; //building type => level => influence
    mapping(uint8 => mapping(uint8 => bool)) public isAffected;


    uint32 public period; // period size, default 1 day
    uint256 public initialPeriod; // period when game starts
    uint256 MAX_LOOKUP = 180; // max period to collect influence

    uint8 sharePercent = 3; // share percent from global bank

    int256 public totalShare;

    constructor(uint32 _period) public {
        period = _period > 0 ? _period : 1 days;
        initialPeriod = now / period;
    }

    function init() public  {
        initialPeriod = currentPeriod();
        totalShare = 36 ether;
        globalShareBank[initialPeriod] = totalShare * sharePercent / 100;
        totalShare = totalShare - globalShareBank[initialPeriod];
    }


    function getSideEffects(uint8 targetTypeId) public view returns (
        uint8[10] typeId, bool[10] penalty, uint8[10] numberAffects, uint8[10] startFrom, int64[10] value
    ) {
        InfluenceSideEffect[] storage se = influenceSideEffect[targetTypeId];
        for(uint256 i = 0; i < se.length; i++) {
            typeId[i] = se[i].typeId;
            penalty[i] = se[i].penalty;
            numberAffects[i] = se[i].numberAffects;
            startFrom[i] = se[i].startFrom;
            value[i] = se[i].value;
        }
    }

    function addRegionShareBank(int256 value, uint16 regionId) external onlyManager {
        uint256 cp = currentPeriod();
        regionShareBank[regionId][cp] = regionShareBank[regionId][cp] + value;
    }

    function addGlobalShareBank(int256 value) external onlyManager {
        uint256 cp = currentPeriod();
        periodsIncome[cp] = periodsIncome[cp] + value;

        _updateGlobalShareBank();
    }

    function updateGlobalShareBank() public {
        _updateGlobalShareBank();
    }


    function _updateGlobalShareBank() internal {
        uint256 cp = currentPeriod();

        if(globalShareBank[cp - 1] == 0) {
            int256 share = totalShare;

            for(uint256 i = cp - 2; i >= initialPeriod; i--) {
                if(globalShareBank[i] != 0) {
                    for(uint256 j = i; j < cp; j++) {
                        share = share + periodsIncome[j];
                        globalShareBank[j] = share * sharePercent / 100;
                        share = share - globalShareBank[j];
                    }
                    break;
                }
            }

            totalShare = share;
        }

    }

    function addSideEffects(
        uint8 typeId, uint8[] targetTypeId,
        bool[] penalty, uint8[] numberAffects, uint8[] startFrom, int64[] value
    ) public onlyManager {

        InfluenceSideEffect[] storage sideEffects = influenceSideEffect[typeId];

        for (uint256 i = 0; i < targetTypeId.length; i++) {
            sideEffects.push(InfluenceSideEffect({
                typeId : targetTypeId[i],
                penalty : penalty[i],
                numberAffects : numberAffects[i],
                startFrom: startFrom[i],
                value : value[i]
            }));

            isAffected[typeId][targetTypeId[i]] = true;
        }
    }

    function setType(int256 x, int256 y, uint8 typeId, uint16 regionId, uint8 level, address owner) external onlyManager {
        influenceMap[x][y].typeId = typeId;
        influenceMap[x][y].regionId = regionId;
        influenceMap[x][y].owner = owner;
        influenceMap[x][y].level = level;
    }

    function setTypeAndUpdate(int256 x, int256 y, uint8 typeId, uint16 regionId, uint8 level, address owner) external onlyManager {
        influenceMap[x][y].typeId = typeId;
        influenceMap[x][y].regionId = regionId;
        influenceMap[x][y].owner = owner;
        influenceMap[x][y].level = level;
        _updateCellInfluenceCallable(x, y);
    }


    function setLevel(int256 x, int256 y, uint8 level) external onlyManager {
        influenceMap[x][y].level = level;
    }

    function setLevelAndUpdate(int256 x, int256 y, uint8 level) external onlyManager {
        influenceMap[x][y].level = level;
        _updateCellInfluenceCallable(x, y);
    }

    function markForDemolition(int256 x, int256 y) external onlyManager {
        influenceMap[x][y].level = 0;
    }

    function markForDemolitionAndUpdate(int256 x, int256 y) external onlyManager {
        influenceMap[x][y].level = 0;
        _updateCellInfluenceCallable(x, y);
    }

    function setBaseInfluenceAndMultiplier(uint8 _buildingType, int256 _influence, int256[7] _multipliers) external onlyManager {
        baseInfluences[_buildingType] = _influence;
        for(uint8 i = 1; i <= 7; i++) {
            multipliers[_buildingType][i] = _multipliers[i - 1];
        }
    }

    function moveToken(int256 x, int256 y, uint16 regionId, address from, address to) external onlyManager {
        if(influenceMap[x][y].influence == 0 || lastUserRegionInfluenceChange[from][regionId] == 0) {
            return;
        }

        uint256 cp = currentPeriod();

        int256 lastValue = userRegionInfluence[from][regionId][lastUserRegionInfluenceChange[from][regionId]];
        if(lastValue == -1) {
            lastValue = 0;
        }

        userRegionInfluence[from][regionId][cp] = lastValue <= influenceMap[x][y].influence
            ? int(-1)
            : lastValue - influenceMap[x][y].influence ;

        lastUserRegionInfluenceChange[from][regionId] = cp;

        if(to == address(0)) {
            totalInfluence[cp] = totalInfluence[lastTotalInfluenceChange] - influenceMap[x][y].influence;
            if(totalInfluence[cp] == 0) {
                totalInfluence[cp] = -1;
            }

            if(lastTotalInfluenceChange != cp) {
                lastTotalInfluenceChange = cp;
            }

            regionsInfluence[regionId][cp] = regionsInfluence[regionId][cp] - influenceMap[x][y].influence;

            if(regionsInfluence[regionId][cp] == 0) {
                regionsInfluence[regionId][cp] = -1;
            }

            if(lastRegionInfluenceChange[regionId] != cp) {
                lastRegionInfluenceChange[regionId] = cp;
            }

            return;
        }

        lastValue = 0;
        if(lastUserRegionInfluenceChange[to][regionId] > 0) {
            lastValue = userRegionInfluence[to][regionId][lastUserRegionInfluenceChange[to][regionId]];
            lastValue = lastValue < 0 ? 0 : lastValue;
        }

        userRegionInfluence[to][regionId][cp] = lastValue - influenceMap[x][y].influence;

        lastUserRegionInfluenceChange[to][regionId] = cp;

    }

    function _updateUserRegionInfluence(address user, uint16 regionId, int256 diff) internal {
        uint256 cp = currentPeriod();
        if(lastUserRegionInfluenceChange[user][regionId] > 0) {
            userRegionInfluence[user][regionId][cp] = userRegionInfluence[user][regionId][lastUserRegionInfluenceChange[user][regionId]] + diff;
        } else {
            userRegionInfluence[user][regionId][cp] = diff;
        }

        userRegionInfluence[user][regionId][cp] = userRegionInfluence[user][regionId][cp] <= 0 ? -1 : userRegionInfluence[user][regionId][cp];

        lastUserRegionInfluenceChange[user][regionId] = cp;

    }

    function _updateRegionInfluence(uint16 regionId, int256 diff) internal {
        uint256 cp = currentPeriod();
        if(lastRegionInfluenceChange[regionId] > 0) {
            regionsInfluence[regionId][cp] = regionsInfluence[regionId][lastRegionInfluenceChange[regionId]] + diff;
        } else {
            regionsInfluence[regionId][cp] = diff;
        }

        regionsInfluence[regionId][cp] = regionsInfluence[regionId][cp] <= 0 ? -1 : regionsInfluence[regionId][cp];

        lastRegionInfluenceChange[regionId] = cp;
    }

    function _updateTotalInfluence(int256 diff) internal {
        uint256 cp = currentPeriod();
        if(lastTotalInfluenceChange > 0) {
            totalInfluence[cp] = totalInfluence[lastTotalInfluenceChange] + diff;
        } else {
            totalInfluence[cp] = diff;
        }

        totalInfluence[cp] = totalInfluence[cp] <= 0 ? -1 : totalInfluence[cp];

        lastTotalInfluenceChange = cp;
    }



    function convertToBalanceValue(address user, uint16[] regionIds) external onlyManager returns (int256) {
        uint256 cp = currentPeriod();
        _updateGlobalShareBank();

        int256 value = getBalanceValue(user, cp - 1, regionIds);

        lastConversion[user] = cp - 1;
        return value;
    }

    function getLastUserRegionInfluenceValue(uint16 regionId, address user, uint256 fromPeriod) internal view returns (int256){
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(userRegionInfluence[user][regionId][i] == 0) {
                continue;
            }

            return userRegionInfluence[user][regionId][i] == -1 ? 0 : userRegionInfluence[user][regionId][i];
        }

        return 0;
    }

    function getLastTotalInfluenceValue(uint256 fromPeriod) internal view returns (int256){
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(totalInfluence[i] != 0) {
                return totalInfluence[i];
            }
        }

        return 0;
    }

    function getRegionLastInfluenceValue(uint16 regionId, uint256 fromPeriod) internal view returns (int256) {
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(regionsInfluence[regionId][i] == 0) {
                continue;
            }

            return regionsInfluence[regionId][i] == -1 ? 0 : regionsInfluence[regionId][i];
        }

        return 0;
    }

    function getCurrentBalanceValue(address user, uint16[] memory regionIds) public view returns (int256) {
        return getBalanceValue(user, currentPeriod() - 1, regionIds);
    }

//TODO: optimize
    function getBalanceValue(address user, uint256 toPeriod, uint16[] memory regionIds) public view returns (int256) {
        if(toPeriod <= lastConversion[user]) {
            return 0;
        }

        int256 tInf = getLastTotalInfluenceValue(lastConversion[user] == 0 ? initialPeriod : lastConversion[user]);
        int256[] memory regionUserInfluenceData = new int256[](regionIds.length);
        int256[] memory regionInfluenceData = new int256[](regionIds.length);
        for(uint256 i = 0; i < regionIds.length; i++) {
             regionUserInfluenceData[i] = getLastUserRegionInfluenceValue(regionIds[i], user, lastConversion[user] == 0 ? initialPeriod : lastConversion[user]);
             regionInfluenceData[i] = getRegionLastInfluenceValue(regionIds[i], lastConversion[user] == 0 ? initialPeriod : lastConversion[user]);
        }

        int256 totalUserBalanceValue = 0;

        for(i = lastConversion[user] == 0 ? initialPeriod : lastConversion[user]; i <= toPeriod; i++) {
            tInf = totalInfluence[i] == 0
                ? tInf
                : (totalInfluence[i] == -1 ? 0 : totalInfluence[i]);
            int256 totalUserInfluence = 0;
            for(uint256 j = 0; j < regionIds.length; j++) {
                regionUserInfluenceData[j] = userRegionInfluence[user][regionIds[j]][i] == 0
                    ? regionUserInfluenceData[j]
                    : (userRegionInfluence[user][regionIds[j]][i] == -1 ? 0 : userRegionInfluence[user][regionIds[j]][i]);

                regionInfluenceData[j] = regionsInfluence[regionIds[j]][i] == 0
                    ? regionInfluenceData[j]
                    : (regionsInfluence[regionIds[j]][i] == -1 ? 0 : regionsInfluence[regionIds[j]][i]);

                totalUserInfluence = totalUserInfluence + regionUserInfluenceData[j];
                if(regionInfluenceData[j] > 0 && regionShareBank[regionIds[j]][i] > 0) {
                    totalUserBalanceValue = totalUserBalanceValue + regionShareBank[regionIds[j]][i] * regionUserInfluenceData[j] / regionInfluenceData[j];
                }
            }

            if(tInf > 0 && globalShareBank[i] > 0) {
                totalUserBalanceValue = totalUserBalanceValue + globalShareBank[i] * totalUserInfluence / tInf;
            }

        }

        return totalUserBalanceValue;
    }

    function updateCellInfluence(int256 x, int256 y) external onlyManager {
        _updateCellInfluenceCallable(x, y);
    }


    function _updateCellInfluenceCallable(int256 x, int256 y) internal {
        int256 diff;
        if(influenceMap[x][y].level == 0) {
            if(influenceMap[x][y].influence > 0) {

                diff = -influenceMap[x][y].influence;

                _updateUserRegionInfluence(
                    influenceMap[x][y].owner,
                    influenceMap[x][y].regionId,
                    diff
                );

                _updateRegionInfluence(
                    influenceMap[x][y].regionId,
                    diff
                );

                influenceMap[x][y].influence = 0;
            }

            _updateTotalInfluence(_updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, true));
            influenceMap[x][y].typeId = 0;
        } else {
            diff = _updateCellInfluence(x, y);


            if(influenceMap[x][y].level == 1) {
                diff = diff  + _updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, false);
            }
        }

        _updateTotalInfluence(diff);

    }



    function _updateCellInfluence(int256 x, int256 y) internal returns (int256) {
        return _updateCellInfluence(x, y, 0, false);
    }

    function _updateCellInfluence(int256 x, int256 y, uint8 typeId, bool demolition) internal returns (int256)  {
        if(influenceMap[x][y].level == 0 || (typeId > 0 && !isAffected[influenceMap[x][y].typeId][typeId])) {
            return 0;
        }

        int256 lastInfluence = influenceMap[x][y].influence < 0 ? 0 : influenceMap[x][y].influence;

        int256 total = baseInfluences[influenceMap[x][y].typeId];
        if(influenceMap[x][y].level == 1 && typeId == 0) {
            influenceMap[x][y].types = _getTypes(x, y);
        }

        if(typeId > 0) {
            influenceMap[x][y].types = demolition ? getDecType(typeId, influenceMap[x][y].types) : getIncType(typeId, influenceMap[x][y].types);
        }

        InfluenceSideEffect[] storage sideEffects = influenceSideEffect[influenceMap[x][y].typeId];

        for(uint256 i = 0; i < sideEffects.length; i++) {
            if( getType(sideEffects[i].typeId, influenceMap[x][y].types) > 0) {
                total = total + getSideEffectValue(influenceMap[x][y].types, sideEffects[i]);
            }
        }

        total = total <= 0 ? -1 : (total * multipliers[influenceMap[x][y].typeId][influenceMap[x][y].level]);

        influenceMap[x][y].influence = total;

        int256 diff = (influenceMap[x][y].influence == -1 ? 0 : influenceMap[x][y].influence) - lastInfluence;

        if(influenceMap[x][y].influence != lastInfluence) {
            _updateUserRegionInfluence(influenceMap[x][y].owner, influenceMap[x][y].regionId, diff);
            _updateRegionInfluence(influenceMap[x][y].regionId, diff);
        }

        return diff;
    }

    function getSideEffectValue(uint256 types, InfluenceSideEffect sideEffect) internal pure returns (int256) {
        uint8 typeCount = getType(sideEffect.typeId, types);
        if(sideEffect.startFrom == 0) {
            return sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
                * (sideEffect.numberAffects < typeCount
                    ? sideEffect.numberAffects
                    : typeCount);
        }

        return sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
            * (sideEffect.startFrom < typeCount
                ? (
                    typeCount - sideEffect.startFrom > int(sideEffect.numberAffects)
                        ? sideEffect.numberAffects
                        : typeCount - sideEffect.startFrom
                ) : 0
            );
    }

    function _getTypes(int256 x, int256 y) internal view returns (uint256 types) {
        for(int256 xi = x-5; xi <= x+5; xi++) {
            for(int256 yi = y-5; yi <= y+5; yi++) {
                if((xi == x && yi == y)) {
                    continue;
                }
                if(influenceMap[xi][yi].typeId > 0) {
                    types = getIncType(influenceMap[xi][yi].typeId, types);
                }
            }
        }
    }

    function _updateInfluenceNearCell(int256 x, int256 y, uint8 typeId) internal returns (int256) {
        return _updateInfluenceNearCell(x, y, typeId, false);
    }

    function _updateInfluenceNearCell(int256 x, int256 y, uint8 typeId, bool demolition) internal returns (int256 diff) {
        for(int256 xi = x-5; xi <= x+5; xi++) {
            for(int256 yi = y-5; yi <= y+5; yi++) {
                if(xi == x && yi == y) {
                    continue;
                }

                diff = diff + _updateCellInfluence(xi, yi, typeId, demolition);
            }
        }
    }

    function _getTypeShift(uint8 typeId) pure internal returns (uint256){
        return uint(typeId - 1) * 8;
    }

    function _clearType(uint8 typeId, uint256 currentTypes) pure internal returns (uint256) {
        return currentTypes & ~_shiftLeft(0xFF, _getTypeShift(typeId));
    }

    function getUpdatedTypes(uint8 typeId, uint8 value, uint256 currentTypes) pure internal returns (uint256) {
        return _clearType(typeId, currentTypes) | _shiftLeft(value, _getTypeShift(typeId));
    }

    function getIncType(uint8 typeId, uint256 currentTypes) pure internal returns (uint256) {
        return _shiftLeft((getType(typeId, currentTypes) + 1),  _getTypeShift(typeId)) | _clearType(typeId, currentTypes);
    }

    function getType(uint8 typeId, uint256 currentTypes) pure internal returns (uint8) {
        uint256 shift = _getTypeShift(typeId);
        return uint8(_shiftRight(currentTypes & _shiftLeft(0xFF, shift), shift));
    }

    function getDecType(uint8 typeId, uint256 currentTypes) pure internal returns (uint256) {
        return _shiftLeft((getType(typeId, currentTypes) - 1), _getTypeShift(typeId)) | _clearType(typeId, currentTypes);
    }

    function _shiftLeft(uint value, uint shift) pure internal returns (uint256) {
        return value * (2 ** shift);
    }

    function _shiftRight(uint value, uint shift) pure internal returns (uint256) {
        return value / (2 ** shift);
    }

    function currentPeriod() internal view returns(uint256) {
        return now / period;
    }

    function getCurrentPeriod() public view returns(uint256) {
        return currentPeriod();
    }

    function getCellInfluence(int256 x, int256 y) public view returns (int256) {
        return influenceMap[x][y].influence;
    }

    function getCurrentInfluence(address user, uint16[] memory regionIds) public view returns (int256 _userInfluence, int256 _totalInfluence) {
        for(uint256 i = 0; i < regionIds.length; i++) {
            _userInfluence = _userInfluence + getLastUserRegionInfluenceValue(regionIds[i], user, currentPeriod());
        }
        _totalInfluence = getLastTotalInfluenceValue(currentPeriod());
    }

    function getTypesNear(int256 x, int256 y) public view returns (uint8[8] types) {
        for(uint8 i = 0; i < 8; i++) {
            types[i] = getType(i + 1, influenceMap[x][y].types);
        }
    }

    function getBaseInfluenceAfterUpgrade(int256 x, int256 y) public view returns (int256 currentBaseInfluence, int256 upgradedInfluence) {
        return (baseInfluences[influenceMap[x][y].typeId] * multipliers[influenceMap[x][y].typeId][influenceMap[x][y].level], baseInfluences[influenceMap[x][y].typeId] * multipliers[influenceMap[x][y].typeId][influenceMap[x][y].level + 1]);
    }

    function getLastShareBankValues(uint16[] memory regionIds) public view returns (int256 globalShareBankSum, int256 regionShareBankSum) {
        uint256 cp = currentPeriod();

        globalShareBankSum = globalShareBank[cp - 1];

        regionShareBankSum = 0;
        for(uint256 i = 0; i < regionIds.length; i++) {
            regionShareBankSum = regionShareBankSum + regionShareBank[regionIds[i]][cp];
        }
    }
}
