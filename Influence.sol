pragma solidity ^0.4.24;

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
        int256 oldInfluence;
        uint8[8] types;
        uint16[] regionIdsNear;
    }

    uint256 lastTotalInfluenceChange;

    mapping(uint256 => int256) public totalInfluence;
    mapping(uint16 => mapping(uint256 => int256)) public regionsInfluence;
    mapping(uint16 => uint256) public lastRegionInfluenceChange;
    mapping(address => mapping(uint16 => mapping(uint256 => int256))) public userRegionInfluence;
    mapping(address => mapping(uint16 => uint256)) public lastUserRegionInfluenceChange;

    mapping(uint256 => int256) public globalShareBank;
    mapping(uint16 => mapping(uint256 => int256)) public regionShareBank;
    mapping(uint256 => int256) public periodsIncome;

    uint256 globalBank;

    mapping(address => uint256) public lastConversion;

    mapping(int256 => mapping(int256 => MapCell)) public influenceMap;

    mapping(uint8 => InfluenceSideEffect[]) public influenceSideEffect;//buildingTypeId => side effect
    mapping(uint8 => mapping(uint8 => int256)) public baseInfluences;


    uint32 public period;
    uint256 public initialPeriod;
    uint256 MAX_LOOKUP = 180;

    uint8 sharePercent = 30;

    address serverSignatureAddress;
    string public ethereumPrefix = "\x19Ethereum Signed Message:\n32";

    constructor(uint32 _period) public {
        period = _period > 0 ? _period : 1 days;
        initialPeriod = now / period;
        globalBank = 36 ether;
    }

    function init() public  {
        initialPeriod = currentPeriod();
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

    function updateGlobalShareBank() public onlyManager {
        _updateGlobalShareBank();
    }



    function _updateGlobalShareBank() internal {
        uint256 cp = currentPeriod();

        if(globalShareBank[cp - 1] == 0) {
            for(uint256 i = cp - 2; i >= initialPeriod; i--) {
                if(globalShareBank[i] != 0) {
                    for(uint256 j = i; j < cp; j++) {
                        globalShareBank[j] = (globalShareBank[j - 1] + periodsIncome[j]) * sharePercent / 100;
                    }
                    break;
                }
            }
        }

        globalShareBank[cp] = (globalShareBank[cp - 1] + periodsIncome[cp]) * sharePercent / 100;

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
        }
    }

    function setType(int256 x, int256 y, uint8 typeId, uint16 regionId, uint8 level, address owner) external onlyManager {
        influenceMap[x][y].typeId = typeId;
        influenceMap[x][y].regionId = regionId;
        influenceMap[x][y].owner = owner;
        influenceMap[x][y].level = level;
    }

    function setBaseInfluence(uint8 buildingType, int256[] influence) external onlyManager {
        for(uint8 i = 1; i <= 7; i++) {
            baseInfluences[buildingType][i] = influence[i - 1];
        }
    }

    function setServerSignatureAddress(address _signatureAddress) public onlyManager {
        serverSignatureAddress = _signatureAddress;
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
            if(lastTotalInfluenceChange != cp) {
                lastTotalInfluenceChange = cp;
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
            totalInfluence[cp] = totalInfluence[cp] + diff;
        } else {
            totalInfluence[cp] = diff;
        }

        totalInfluence[cp] = totalInfluence[cp] <= 0 ? -1 : totalInfluence[cp];

        lastTotalInfluenceChange = cp;
    }

    function convertToBalanceValueSigned(address user, bytes influenceSignature, uint256 value, uint256 toPeriod) external onlyManager returns (uint256){
        uint256 lc = lastConversion[user];

        bytes32 message = keccak256(abi.encodePacked(ethereumPrefix, user, value, toPeriod, lc));

        require(ecverify(message, influenceSignature, serverSignatureAddress));

        lastConversion[user] = toPeriod;
        return value;
    }



    function convertToBalanceValue(address user, uint16[] regionIds) external onlyManager returns (int256) {
        uint256 cp = currentPeriod();
        lastConversion[user] = cp - 1;
        _updateGlobalShareBank();
        return getBalanceValue(user, cp - 1, regionIds);
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

    function updateCellInfluence(int256 x, int256 y) external {
        if(influenceMap[x][y].level == 0) {
            if(influenceMap[x][y].influence > 0) {

                _updateUserRegionInfluence(
                    influenceMap[x][y].owner,
                    influenceMap[x][y].regionId,
                    -influenceMap[x][y].influence
                );

                _updateRegionInfluence(
                    influenceMap[x][y].regionId,
                    -influenceMap[x][y].influence
                );

                _updateTotalInfluence(
                    -influenceMap[x][y].influence
                );
                influenceMap[x][y].oldInfluence = influenceMap[x][y].influence;
                influenceMap[x][y].influence = 0;
            }

            _updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, true);
            influenceMap[x][y].typeId = 0;
        } else {

            _updateCellInfluence(x, y);

            if(influenceMap[x][y].level == 1) {
                _updateInfluenceNearCell(x, y, influenceMap[x][y].typeId, false);
            }
        }
    }



    function _updateCellInfluence(int256 x, int256 y) internal returns (int256) {
        _updateCellInfluence(x, y, 0, false);
    }

    function _updateCellInfluence(int256 x, int256 y, uint8 typeId, bool demolition) internal returns (int256)  {
        if(influenceMap[x][y].level == 0) {
            return;
        }

        int256 lastInfluence = influenceMap[x][y].influence < 0 ? 0 : influenceMap[x][y].influence;

        int256 total = baseInfluences[influenceMap[x][y].typeId][influenceMap[x][y].level];
        if(influenceMap[x][y].level == 1 && typeId == 0) {
            influenceMap[x][y].types = _getTypes(x, y);
            _updateRegionIds(x, y);

        }
        uint8[8] storage types = influenceMap[x][y].types;

        if(typeId > 0) {
            types[typeId - 1] = demolition ? types[typeId - 1] - 1 :types[typeId - 1] + 1;
        }


        InfluenceSideEffect[] storage sideEffects = influenceSideEffect[influenceMap[x][y].typeId];

        for(uint256 i = 0; i < sideEffects.length; i++) {
            if(types[sideEffects[i].typeId - 1] > 0) {
                total = total + getSideEffectValue(types, sideEffects[i]);
            }
        }

        influenceMap[x][y].oldInfluence = influenceMap[x][y].influence;
        influenceMap[x][y].influence = total <= 0 ? -1 : total;

        if(influenceMap[x][y].influence != lastInfluence) {
            _updateUserRegionInfluence(influenceMap[x][y].owner, influenceMap[x][y].regionId, (influenceMap[x][y].influence == -1 ? 0 : influenceMap[x][y].influence) - lastInfluence);
        }
    }

    function getSideEffectValue(uint8[8] memory types, InfluenceSideEffect sideEffect) internal pure returns (int256) {
        if(sideEffect.startFrom == 0) {
            return sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
                * (sideEffect.numberAffects < types[sideEffect.typeId - 1]
                    ? sideEffect.numberAffects
                    : types[sideEffect.typeId - 1]);
        }

        return sideEffect.value * (sideEffect.penalty ? -1 : int8(1))
            * (sideEffect.startFrom < types[sideEffect.typeId - 1]
                ? (
                    types[sideEffect.typeId - 1] - sideEffect.startFrom > int(sideEffect.numberAffects)
                        ? sideEffect.numberAffects
                        : types[sideEffect.typeId - 1] - sideEffect.startFrom
                ) : 0
            );
    }

    function _updateInfluences(int256 x, int256 y) internal {
        int256 totalInflueceChange = 0;
        for(uint256 i = 0; i < influenceMap[x][y].regionIdsNear.length; i++) {
            int256 currentInfluenceValue = 0;
            int256 oldInfluenceValue = 0;
            uint16 regionId = influenceMap[x][y].regionIdsNear[i];
            for(int256 xi = x-5; xi <= x+5; xi++) {
                for(int256 yi = y-5; yi <= y+5; yi++) {
                    if(influenceMap[xi][yi].regionId != regionId) {
                        continue;
                    }

                    currentInfluenceValue = currentInfluenceValue + influenceMap[xi][yi].influence;
                    oldInfluenceValue = oldInfluenceValue + influenceMap[xi][yi].oldInfluence;
                }
            }

            if(currentInfluenceValue != oldInfluenceValue) {
                _updateRegionInfluence(regionId, oldInfluenceValue - currentInfluenceValue);
                totalInflueceChange = totalInflueceChange + (oldInfluenceValue - currentInfluenceValue);
            }

        }
        // _updateUserRegionInfluence(influenceMap[x][y].owner, influenceMap[x][y].regionId, diff);

        _updateTotalInfluence(totalInflueceChange);
    }

    function _getTypes(int256 x, int256 y) internal view returns (uint8[8] types) {
        for(int256 xi = x-5; xi <= x+5; xi++) {
            for(int256 yi = y-5; yi <= y+5; yi++) {
                if(xi == x && yi == y) {
                    continue;
                }
                if(influenceMap[xi][yi].typeId > 0) {
                    types[influenceMap[xi][yi].typeId - 1]++;
                }
            }
        }
    }

    function _updateRegionIds(int256 x, int256 y) internal {
        for(int256 xi = x-5; xi <= x+5; xi++) {
            for(int256 yi = y-5; yi <= y+5; yi++) {
                bool isAdded = false;
                for(uint8 i = 0; i < influenceMap[x][y].regionIdsNear.length; i++) {
                    if(influenceMap[xi][yi].regionId == influenceMap[x][y].regionIdsNear[i]) {
                        isAdded = true;
                        break;
                    }
                }
                if(!isAdded) {
                    influenceMap[x][y].regionIdsNear.push(influenceMap[xi][yi].regionId);
                }
            }
        }
    }

    function _updateInfluenceNearCell(int256 x, int256 y, uint8 typeId) internal {
        _updateInfluenceNearCell(x, y, typeId, false);
    }

    function getTypes(int256 x, int256 y) public view returns (uint8[8] types) {
        return influenceMap[x][y].types;
    }

    function _updateInfluenceNearCell(int256 x, int256 y, uint8 typeId, bool demolition) internal {
        for(int256 xi = x-5; xi <= x+5; xi++) {
            for(int256 yi = y-5; yi <= y+5; yi++) {
                if(xi == x && yi == y) {
                    continue;
                }

                _updateCellInfluence(xi, yi, typeId, demolition);
            }
        }
    }

//TODO: change to internal
    function currentPeriod() public view returns(uint256) {
        return now / period;
    }

    function getCellInfluence(int256 x, int256 y) public view returns (int256) {
        return influenceMap[x][y].influence;
    }

    function ecrecovery(bytes32 hash, bytes sig) internal pure returns (address) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (sig.length != 65) {
            return address(0);
        }

        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := and(mload(add(sig, 65)), 255)
        }

        if (v < 27) {
            v += 27;
        }

        if (v != 27 && v != 28) {
            return address(0);
        }

        return ecrecover(hash, v, r, s);
    }

    function ecverify(bytes32 hash, bytes sig, address signer) internal pure returns (bool) {
        return signer == ecrecovery(hash, sig);
    }

}
