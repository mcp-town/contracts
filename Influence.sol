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
        int64 influence;
        address owner;
        uint256 types;//Building types in 5 cell radius (8 bit for each type)
    }

    uint256 lastTotalInfluenceChange;

    uint256 lastTotalBankUpdate;

    mapping(uint256 => int256) public totalInfluence; // period => influence

    mapping(uint16 => mapping(uint256 => int256)) public regionsInfluence;// regionId => period => influence
    mapping(uint16 => uint256) public lastRegionInfluenceChange; //regionId => period

    mapping(address => mapping(uint16 => mapping(uint256 => int256))) public userRegionInfluence; // user => regionId => period => influence
    mapping(address => mapping(uint16 => uint256)) public lastUserRegionInfluenceChange; // user => regionId => period

    mapping(address => mapping(uint256 => int256)) public userGlobalInfluence;
    mapping(address  => uint256) public lastGlobalUserInfluenceChange; // user => period

    mapping(uint256 => int256) public globalShareBank; // period => ether
    mapping(uint16 => mapping(uint256 => int256)) public regionShareBank; // region => period => ether
    mapping(uint256 => int256) public periodsIncome; // period => ether

    mapping(address => uint256) public lastConversion; // user => conversion period

    mapping(int64 => mapping(int64 => MapCell)) public influenceMap; // x => y => cell

    mapping(uint8 => InfluenceSideEffect[]) public influenceSideEffect;//buildingTypeId => side effect [max 10]
    mapping(uint8 => mapping(uint8 => uint8)) public multipliers; //building type => level => influence
    mapping(uint8 => int64) public baseInfluences; //building type => level => influence
    mapping(uint8 => mapping(uint8 => bool)) public isAffected;

    uint32 public period; // period size, default 1 day
    uint256 public initialPeriod; // period when game starts
    uint256 MAX_LOOKUP = 180; // max period to collect influence

    uint8 sharePercent = 3; // share percent from global bank

    int256 public totalShare;

    uint8 RESOURCES_TYPE_ID = 2;

    constructor(uint32 _period) public {
        period = _period > 0 ? _period : 1 days;
        initialPeriod = now / period;
    }

    function init() public  {
        initialPeriod = _currentPeriod();
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
        uint256 cp = _currentPeriod();
        regionShareBank[regionId][cp] = regionShareBank[regionId][cp] + value;
    }

    function addGlobalShareBank(int256 value) external onlyManager {
        uint256 cp = _currentPeriod();
        periodsIncome[cp] = periodsIncome[cp] + value;

        _updateGlobalShareBank();
    }

    function updateGlobalShareBank() public {
        _updateGlobalShareBank();
    }


    function _updateGlobalShareBank() internal {
        uint256 cp = _currentPeriod();

        if(lastTotalBankUpdate >= cp - 1 || cp == initialPeriod) {
            return;
        }

        uint256 fromPeriod = lastTotalBankUpdate == 0 ? initialPeriod : (lastTotalBankUpdate + 1);

        int256 share = totalShare;

        for(uint256 j = fromPeriod; j < cp; j++) {
            share = share + periodsIncome[j];
            globalShareBank[j] = share * sharePercent / 100;
            share = share - globalShareBank[j];
        }

        totalShare = share;

        lastTotalBankUpdate = cp - 1;
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

    function setType(int64 x, int64 y, uint8 typeId, uint16 regionId, uint8 level, address owner) external onlyManager {
        influenceMap[x][y].typeId = typeId;
        influenceMap[x][y].regionId = regionId;
        influenceMap[x][y].owner = owner;
        influenceMap[x][y].level = level;
    }

    function setTypeAndUpdate(int64 x, int64 y, uint8 typeId, uint16 regionId, uint8 level, address owner) external onlyManager {
        influenceMap[x][y].typeId = typeId;
        influenceMap[x][y].regionId = regionId;
        influenceMap[x][y].owner = owner;
        influenceMap[x][y].level = level;
        _updateCellInfluenceCallable(x, y);
    }


    function setLevel(int64 x, int64 y, uint8 level) external onlyManager {
        influenceMap[x][y].level = level;
    }

    function setLevelAndUpdate(int64 x, int64 y, uint8 level) external onlyManager {
        influenceMap[x][y].level = level;
        _updateCellInfluenceCallable(x, y);
    }

    function markForDemolition(int64 x, int64 y) external onlyManager {
        influenceMap[x][y].level = 0;
    }

    function markForDemolitionAndUpdate(int64 x, int64 y) external onlyManager {
        influenceMap[x][y].level = 0;
        _updateCellInfluenceCallable(x, y);
    }

    function setBaseInfluenceAndMultiplier(uint8 _buildingType, int64 _influence, uint8[7] _multipliers) external onlyManager {
        baseInfluences[_buildingType] = _influence;
        for(uint8 i = 1; i <= 7; i++) {
            multipliers[_buildingType][i] = _multipliers[i - 1];
        }
    }

    function moveToken(int64 x, int64 y, uint16 regionId, address from, address to) external onlyManager {
        if(influenceMap[x][y].influence == 0 || lastUserRegionInfluenceChange[from][regionId] == 0) {
            return;
        }

        _updateUserRegionInfluence(from, regionId, -influenceMap[x][y].influence);

        _updateGlobalUserInfluence(from, -influenceMap[x][y].influence);

        if(to == address(0)) {
            _updateTotalInfluence(-influenceMap[x][y].influence);
            _updateRegionInfluence(regionId, -influenceMap[x][y].influence);

            return;
        }

        _updateUserRegionInfluence(to, regionId, influenceMap[x][y].influence);
        _updateGlobalUserInfluence(to, influenceMap[x][y].influence);
    }

    function _getLastGlobalUserInfluence(address user, uint256 fromPeriod) internal view returns (int256) {
        if(lastGlobalUserInfluenceChange[user] == 0) {
            return -1;
        }

        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(userGlobalInfluence[user][i] != 0) {
                return userGlobalInfluence[user][i];
            }
        }

        return -1;
    }

    function _getLastGlobalUserInfluence(address user) internal view returns (int256) {
        if(lastGlobalUserInfluenceChange[user] == 0) {
            return -1;
        }

        return userGlobalInfluence[user][lastGlobalUserInfluenceChange[user]];
    }


    function _updateGlobalUserInfluence(address user, int64 diff) internal {
        int256 lastValue = _getLastGlobalUserInfluence(user);
        uint256 cp = _currentPeriod();
        lastValue = lastValue < 0 ? 0 : lastValue;

        userGlobalInfluence[user][cp] = (lastValue + diff) <= 0 ? -1 : (lastValue + diff);
        lastGlobalUserInfluenceChange[user] = cp;
    }

    function _updateUserRegionInfluence(address user, uint16 regionId, int64 diff) internal {
        uint256 cp = _currentPeriod();
        if(lastUserRegionInfluenceChange[user][regionId] > 0) {
            userRegionInfluence[user][regionId][cp] = userRegionInfluence[user][regionId][lastUserRegionInfluenceChange[user][regionId]] + diff;
        } else {
            userRegionInfluence[user][regionId][cp] = diff;
        }

        userRegionInfluence[user][regionId][cp] = userRegionInfluence[user][regionId][cp] <= 0 ? -1 : userRegionInfluence[user][regionId][cp];

        lastUserRegionInfluenceChange[user][regionId] = cp;

    }

    function _updateRegionInfluence(uint16 regionId, int64 diff) internal {
        uint256 cp = _currentPeriod();
        if(lastRegionInfluenceChange[regionId] > 0) {
            regionsInfluence[regionId][cp] = regionsInfluence[regionId][lastRegionInfluenceChange[regionId]] + diff;
        } else {
            regionsInfluence[regionId][cp] = diff;
        }

        regionsInfluence[regionId][cp] = regionsInfluence[regionId][cp] <= 0 ? -1 : regionsInfluence[regionId][cp];

        lastRegionInfluenceChange[regionId] = cp;
    }

    function _updateTotalInfluence(int64 diff) internal {
        uint256 cp = _currentPeriod();
        if(lastTotalInfluenceChange > 0) {
            totalInfluence[cp] = totalInfluence[lastTotalInfluenceChange] + diff;
        } else {
            totalInfluence[cp] = diff;
        }

        totalInfluence[cp] = totalInfluence[cp] <= 0 ? -1 : totalInfluence[cp];

        lastTotalInfluenceChange = cp;
    }



    function convertToBalanceValue(address user, uint16[] regionIds) external onlyManager returns (int256) {
        uint256 cp = _currentPeriod();
        _updateGlobalShareBank();

        int256 value = getBalanceValue(user, cp - 1, regionIds);

        lastConversion[user] = cp - 1;
        return value;
    }

    function _getLastUserRegionInfluenceValue(uint16 regionId, address user, uint256 fromPeriod) internal view returns (int256){
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(userRegionInfluence[user][regionId][i] == 0) {
                continue;
            }

            return userRegionInfluence[user][regionId][i] < 0 ? 0 : userRegionInfluence[user][regionId][i];
        }

        return 0;
    }

    function _getLastTotalInfluenceValue(uint256 fromPeriod) internal view returns (int256){
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(totalInfluence[i] != 0) {
                return totalInfluence[i];
            }
        }

        return 0;
    }

    function _getRegionLastInfluenceValue(uint16 regionId, uint256 fromPeriod) internal view returns (int256) {
        for(uint256 i = fromPeriod; i >= initialPeriod; i--) {
            if(regionsInfluence[regionId][i] == 0) {
                continue;
            }

            return regionsInfluence[regionId][i] < 0 ? 0 : regionsInfluence[regionId][i];
        }

        return 0;
    }

    function getCurrentBalanceValue(address user, uint16[] memory regionIds) public view returns (int256) {
        return getBalanceValue(user, _currentPeriod() - 1, regionIds);
    }

//TODO: optimize
    function getBalanceValue(address user, uint256 toPeriod, uint16[] memory regionIds) public view returns (int256) {
        if(toPeriod <= lastConversion[user]) {
            return 0;
        }

        int256 tInf = _getLastTotalInfluenceValue(lastConversion[user] == 0 ? initialPeriod : lastConversion[user]);

        int256 totalUserBalanceValue = 0;

        for(uint256 i = lastConversion[user] == 0 ? initialPeriod : (lastConversion[user] + 1); i <= toPeriod; i++) {
            tInf = totalInfluence[i] == 0
                ? tInf
                : (totalInfluence[i] < 0 ? 0 : totalInfluence[i]);

            int256 totalUserInfluence = _getLastGlobalUserInfluence(user, i);
            totalUserInfluence = totalUserInfluence < 0 ? 0 : totalUserInfluence;

            for(uint256 j = 0; j < regionIds.length; j++) {
                int256 _userRegionInfluence = _getLastUserRegionInfluenceValue(regionIds[j], user, i);
                int256 _regionInfluence = _getRegionLastInfluenceValue(regionIds[j], i);
                _userRegionInfluence = _userRegionInfluence < 0 ? 0 : _userRegionInfluence;
                _regionInfluence = _regionInfluence < 0 ? 0 : _regionInfluence;

                if(_regionInfluence > 0 && regionShareBank[regionIds[j]][i] > 0) {
                    totalUserBalanceValue = totalUserBalanceValue + regionShareBank[regionIds[j]][i] * _userRegionInfluence / _regionInfluence;
                }
            }
            int256 gs = _getGlobalShareBank(i);
            if(tInf > 0 && gs > 0) {
                totalUserBalanceValue = totalUserBalanceValue + gs * totalUserInfluence / tInf;
            }

        }

        return totalUserBalanceValue;
    }

    function updateCellInfluence(int64 x, int64 y) external onlyManager {
        _updateCellInfluenceCallable(x, y);
    }


    function _updateCellInfluenceCallable(int64 x, int64 y) internal {
        int64 diff;
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

                _updateGlobalUserInfluence(influenceMap[x][y].owner, diff);

                influenceMap[x][y].influence = 0;
            }

            _updateTotalInfluence(_updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, true));

            influenceMap[x][y].typeId = 0;
        } else {
            diff = _updateCellInfluence(x, y);


            if(influenceMap[x][y].level == 1 || (influenceMap[x][y].typeId == RESOURCES_TYPE_ID && influenceMap[x][y].influence == 0)) {
                diff = diff  + _updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, false);
            }
        }

        _updateTotalInfluence(diff);

    }

    function setPoints(int64[] x, int64[] y) public onlyManager {
        for(uint256 i = 0; i < x.length; i++) {
            influenceMap[x[i]][y[i]] = MapCell({
                typeId: 0,
                level: 0,
                regionId: 0,
                influence: 0,
                owner: 0,
                types: 0
            });
        }
    }



    function _updateCellInfluence(int64 x, int64 y) internal returns (int64) {
        return _updateCellInfluence(x, y, 0, false);
    }

    function _updateCellInfluence(int64 x, int64 y, uint8 typeId, bool demolition) internal returns (int64)  {
        if(influenceMap[x][y].level == 0 || (typeId > 0 && !isAffected[influenceMap[x][y].typeId][typeId])) {
            return 0;
        }

        MapCell storage cell = influenceMap[x][y];
        int64 lastInfluence = cell.influence < 0 ? 0 : cell.influence;

        int64 total = multipliers[cell.typeId][cell.level] * baseInfluences[cell.typeId];
        if((cell.level == 1 || cell.typeId == RESOURCES_TYPE_ID) && typeId == 0) {
            cell.types = _getTypes(x, y);
        }

        if(typeId > 0) {
            cell.types = demolition ? _getDecType(typeId, cell.types) : _getIncType(typeId, cell.types);

            if(_getType(typeId, cell.types) > 20) {
                return 0;
            }
        }

        InfluenceSideEffect[] storage sideEffects = influenceSideEffect[cell.typeId];

        for(uint256 i = 0; i < sideEffects.length; i++) {
            if( _getType(sideEffects[i].typeId, cell.types) > 0) {
                total = total + _getSideEffectValue(cell.types, sideEffects[i], multipliers[cell.typeId][cell.level], cell.level);
            }
        }

        total = total <= 0 ? -1 : total;

        cell.influence = total;

        int64 diff = (cell.influence < 0 ? 0 : cell.influence) - lastInfluence;

        if(cell.influence != lastInfluence) {
            _updateUserRegionInfluence(cell.owner, cell.regionId, diff);
            _updateRegionInfluence(cell.regionId, diff);
            _updateGlobalUserInfluence(cell.owner, diff);
        }

        return diff;
    }

    function _getSideEffectValue(uint256 types, InfluenceSideEffect sideEffect, uint8 multiplier, uint8 level) internal pure returns (int64) {
        uint8 typeCount = _getType(sideEffect.typeId, types);
        int8 negativeDivider = (level <= 5 ? int8(1) : (level == 6 ? int8(2) : int8(4)));
        if(sideEffect.startFrom == 0) {
            return (multiplier * sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
                * (sideEffect.numberAffects < typeCount
                    ? sideEffect.numberAffects
                    : typeCount)) / (sideEffect.penalty ? negativeDivider : int8(1)) ;
        }

        return sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
            * (sideEffect.startFrom < typeCount
                ? (
                    typeCount - sideEffect.startFrom > int(sideEffect.numberAffects)
                        ? sideEffect.numberAffects
                        : typeCount - sideEffect.startFrom
                ) : 0
            ) / (sideEffect.penalty ? negativeDivider : int8(1));
    }

    function _getTypes(int64 x, int64 y) internal view returns (uint256 types) {
        for(int64 xi = x-5; xi <= x+5; xi++) {
            for(int64 yi = y-5; yi <= y+5; yi++) {
                if((xi == x && yi == y)) {
                    continue;
                }
                if(influenceMap[xi][yi].typeId > 0) {
                    if(influenceMap[xi][yi].typeId == RESOURCES_TYPE_ID) {
                        types = _getAddType(influenceMap[xi][yi].typeId, types, influenceMap[xi][yi].level);

                    } else {
                        types = _getIncType(influenceMap[xi][yi].typeId, types);
                    }
                }
            }
        }
    }

    function _updateInfluenceNearCell(int64 x, int64 y, uint8 typeId, bool demolition) internal returns (int64 diff) {

        for(int64 xi = x-5; xi <= x+5; xi++) {
            for(int64 yi = y-5; yi <= y+5; yi++) {
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

    function _getUpdatedTypes(uint8 typeId, uint8 value, uint256 currentTypes) pure internal returns (uint256) {
        return _clearType(typeId, currentTypes) | _shiftLeft(value, _getTypeShift(typeId));
    }

    function _getAddType(uint8 typeId, uint256 currentTypes, uint8 count) pure internal returns (uint256) {
        return _shiftLeft((_getType(typeId, currentTypes) + count),  _getTypeShift(typeId)) | _clearType(typeId, currentTypes);
    }

    function _getIncType(uint8 typeId, uint256 currentTypes) pure internal returns (uint256) {
        return _shiftLeft((_getType(typeId, currentTypes) + 1),  _getTypeShift(typeId)) | _clearType(typeId, currentTypes);
    }

    function _getType(uint8 typeId, uint256 currentTypes) pure internal returns (uint8) {
        uint256 shift = _getTypeShift(typeId);
        return uint8(_shiftRight(currentTypes & _shiftLeft(0xFF, shift), shift));
    }

    function _getDecType(uint8 typeId, uint256 currentTypes) pure internal returns (uint256) {
        return _shiftLeft((_getType(typeId, currentTypes) - 1), _getTypeShift(typeId)) | _clearType(typeId, currentTypes);
    }

    function _shiftLeft(uint value, uint shift) pure internal returns (uint256) {
        return value * (2 ** shift);
    }

    function _shiftRight(uint value, uint shift) pure internal returns (uint256) {
        return value / (2 ** shift);
    }

    function _currentPeriod() internal view returns(uint256) {
        return now / period;
    }

    function getCurrentPeriod() public view returns(uint256) {
        return _currentPeriod();
    }

    function getCellInfluence(int64 x, int64 y) public view returns (int256) {
        return influenceMap[x][y].influence;
    }

    function getCurrentInfluence(address user, uint16[] memory regionIds) public view returns (int256 _userInfluence, int256 _totalInfluence) {
        for(uint256 i = 0; i < regionIds.length; i++) {
            _userInfluence = _userInfluence + _getLastUserRegionInfluenceValue(regionIds[i], user, _currentPeriod());
        }
        _totalInfluence = _getLastTotalInfluenceValue(_currentPeriod());
    }


    function getTypesNear(int64 x, int64 y) public view returns (uint8[8] types) {
        for(uint8 i = 0; i < 8; i++) {
            types[i] = _getType(i + 1, influenceMap[x][y].types);
        }
    }

    function getBaseInfluenceAfterUpgrade(int64 x, int64 y) public view returns (int256 currentBaseInfluence, int256 upgradedInfluence) {
        return (baseInfluences[influenceMap[x][y].typeId] * int16(multipliers[influenceMap[x][y].typeId][influenceMap[x][y].level]), baseInfluences[influenceMap[x][y].typeId] * int16(multipliers[influenceMap[x][y].typeId][influenceMap[x][y].level + 1]));
    }

    function getLastShareBankValues(uint16[] memory regionIds) public view returns (int256 globalShareBankSum, int256 regionShareBankSum) {
        uint256 cp = _currentPeriod();

        globalShareBankSum = getTodayGlobalShareBank();

        regionShareBankSum = 0;
        for(uint256 i = 0; i < regionIds.length; i++) {
            regionShareBankSum = regionShareBankSum + regionShareBank[regionIds[i]][cp];
        }
    }

    function getTodayGlobalShareBank() public view returns (int256){
        return _getGlobalShareBank(_currentPeriod());
    }

    function _getGlobalShareBank(uint256 fromPeriod) internal view returns (int256) {
        if(fromPeriod <= lastTotalBankUpdate) {
            return globalShareBank[fromPeriod];
        }
        int256 share = totalShare;

        for(uint256 j = lastTotalBankUpdate == 0 ? initialPeriod : lastTotalBankUpdate + 1; j < fromPeriod; j++) {
            share = (share + periodsIncome[j]) * (100 - sharePercent) / 100;
        }

        return (share + periodsIncome[fromPeriod]) * sharePercent / 100;
    }

    function getLeftGlobalBank() public view returns (int256) {
        uint256 fromPeriod = _currentPeriod();

        int256 share = totalShare;

        for(uint256 j = lastTotalBankUpdate == 0 ? initialPeriod : lastTotalBankUpdate + 1; j < fromPeriod; j++) {
            share = share + periodsIncome[j];
            share = share * (100 - sharePercent) / 100;
        }

        return share + periodsIncome[fromPeriod];
    }

    function getInfluenceForBuilding(int64 x, int64 y, uint8 buildingType) public view returns (int256) {
        if(buildingType == 0) {
            return influenceMap[x][y].influence;
        } else if(buildingType == 1) {
            return influenceMap[x][y].influence + influenceMap[x][y - 1].influence;
        } else if (buildingType == 2) {
            return influenceMap[x][y].influence + influenceMap[x - 1][y].influence;
        } else if (buildingType == 3) {
            return influenceMap[x][y].influence + influenceMap[x - 1][y].influence + influenceMap[x][y - 1].influence + influenceMap[x - 1][y - 1].influence;
        }
    }

    function getAffectsAndInfluenceHuge(int64 x, int64 y, uint8 buildingType) public view returns (
        int256 cellInfluence, uint16[8][2] counts, int256[8][2] bonus, int256[8][2] penalty
    ) {
        (counts[0], bonus[0], penalty[0]) = getAffects(x, y);
        if(buildingType == 1) {
            cellInfluence = influenceMap[x][y].influence + influenceMap[x - 1][y].influence;
            (counts[1], bonus[1], penalty[1]) = getAffects(x - 1, y);
        } else {
            cellInfluence = influenceMap[x][y].influence + influenceMap[x][y - 1].influence ;
            (counts[1], bonus[1], penalty[1]) = getAffects(x, y - 1);
        }
    }

    function getAffectsAndInfluenceMega(int64 x, int64 y) public view returns (
        int256 cellInfluence, uint16[8][4] counts, int256[8][4] bonus, int256[8][4] penalty
    ) {
        cellInfluence = influenceMap[x][y].influence + influenceMap[x - 1][y].influence + influenceMap[x][y - 1].influence + influenceMap[x - 1][y - 1].influence;
        (counts[0], bonus[0], penalty[0]) = getAffects(x, y);
        (counts[1], bonus[1], penalty[1]) = getAffects(x - 1, y);
        (counts[2], bonus[2], penalty[2]) = getAffects(x, y - 1);
        (counts[3], bonus[3], penalty[3]) = getAffects(x - 1, y - 1);
    }

    function getAffects(int64 x, int64 y) public view returns (uint16[8] count, int256[8] bonus, int256[8] penalty) {
        if(influenceMap[x][y].typeId == 0) {
            return;
        }

        uint8[8] memory types = getTypesNear(x, y);
        MapCell storage cell = influenceMap[x][y];

        for(uint8 i = 0; i < 8; i++) {
            count[i] = uint16(types[i]);
        }

        InfluenceSideEffect[] storage sideEffects = influenceSideEffect[cell.typeId];

        for(i = 0; i < sideEffects.length; i++) {
            int64 diff = _getSideEffectValue(influenceMap[x][y].types, sideEffects[i], multipliers[cell.typeId][cell.level], cell.level);
            if(diff >= 0) {
                bonus[sideEffects[i].typeId - 1] = bonus[sideEffects[i].typeId - 1] + diff;
            } else {
                penalty[sideEffects[i].typeId - 1] = penalty[sideEffects[i].typeId - 1] + diff;
            }
        }
    }

    function getTotalAndRegionData(uint16 regionId, uint256 fromPeriod, address user)  public view returns (
        int256 totalInf, int256 regionInf, int256 userRegion, int256 userTotal, int256 regionBank, int256 globalBank
    ) {
        regionBank = regionShareBank[regionId][fromPeriod];
        globalBank = _getGlobalShareBank(fromPeriod);
        totalInf = _getLastTotalInfluenceValue(fromPeriod);
        userTotal = _getLastGlobalUserInfluence(user, fromPeriod);
        userRegion = _getLastUserRegionInfluenceValue(regionId, user, fromPeriod);
        regionInf = _getRegionLastInfluenceValue(regionId, fromPeriod);
    }
}
