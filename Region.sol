pragma solidity 0.4.25;

import "./Manageable.sol";
import "./UserBalance.sol";
import "./MainInterface.sol";
import "./Auction.sol";


contract Region is Manageable, Auction {

    struct RegionToken {
        uint16 regionId;
        address owner;
        uint8 tax;
        string regionName;
        bool isCanSale;
    }

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
        isRegularAuctionAllowed = true;
        isFixedAuctionAllowed = true;

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
        emit AuctionRegularTransfer(subjectId, address(0), startPrice, newAuction.activeTill, buyer, currentBid, bidCount);
    }


    function setOnAuctionByGameManager(
        uint16 regionId, uint256 startPrice, uint256 minimalRaise
    ) public onlyManager {
        uint256 tokenId = regionMap[regionId];
        require(tokens[tokenId].owner == address(0));
        require(!_isOnAuction(tokenId));

        _setOnRegularAuction(tokenId, startPrice, minimalRaise, address(0));
    }

    function setOnFixedAuction(uint16 regionId, uint256 startPrice) public onlyTokenOwner(regionMap[regionId]) {
        _setOnFixedAuction(regionMap[regionId], startPrice, msg.sender);
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

        tokens[regionMap[regionId]].isCanSale = true;
        emit RegionOpen(regionId);
    }

    function canSaleLands(uint16 regionId) external view returns (bool) {
        return tokens[regionMap[regionId]].isCanSale;
    }

    function payout(uint16 regionId, uint256 value) public onlyManager {
        RegionToken memory region = tokens[regionMap[regionId]];
        if(region.owner != address(0)) {
            userBalanceContract.addBalance(region.owner, value, 1);
            emit RegionPayout(regionId, value);
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

    function transferFrom(address _from, address _to, uint256 _tokenId) public {
        require(approved[_tokenId] == _to, "Address not in approved list");
        _transfer(_from, _to, _tokenId);
    }

    function transfer(address _to, uint256 _tokenId) public onlyTokenOwner(_tokenId) {
        _transfer(msg.sender, _to, _tokenId);
    }

    function _transfer(address _from, address _to, uint256 _tokenId) internal {
        require(tokens[_tokenId].owner == _from,"Owner not correct");
        require(activeAuctions[_tokenId].activeTill == 0);

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

    function _toRegionShareBank(uint256 _tokenId, int256 _value) internal {
        mainContract.addToRegionShareBank(tokens[_tokenId].regionId, _value);
    }


    function _addToBalance(address _to, uint256 _value, uint8 _reason) internal {
        userBalanceContract.addBalance(_to, _value, _reason);
    }

    event AuctionRegularTransfer(uint256 indexed subjectId, address indexed seller, uint256 startPrice, uint256 activeTill, address indexed buyer, uint256 bid, uint256 bidCount);
    event RegionChanged(uint256 tokenId, address owner, string regionName, uint8 tax, uint16 regionId, bool isCanSale);
    event RegionOpen(uint16 regionId);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event RegionPayout(uint16 regionId, uint256 value);
    event RegionTaxUpdate(uint16 regionId, uint8 tax);
}
