// SPDX-License-Identifier: MIT
//website: https://joyclub.tech/
pragma solidity 0.8.16;

import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/GSN/Context.sol";
import "../access/Governable.sol";

enum GasMode {
    VOID,
    CLAIMABLE 
}

interface IBlast {
  function configureClaimableYield() external;
  function configureClaimableGas() external;
  
  function readClaimableYield(address contractAddress) external view returns (uint256);
  function claimAllYield(address contractAddress, address recipient) external returns (uint256);
  
  function readGasParams(address contractAddress) external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode);
  function claimAllGas(address contractAddress, address recipient) external returns (uint256);
}

contract FriendClubSharesV2 is Context, ReentrancyGuard, Governable {
  IBlast public constant BLAST = IBlast(0x4300000000000000000000000000000000000002);

  // @dev Event emitted when a trade is executed
  event Trade(
    address indexed trader,
    address indexed subject,
    bool isBuy,
    uint256 amount,
    uint256 price,
    uint256 supply,
    SubjectType subjectType,
    uint256 ts,
    uint256 totalProtocolFees
  );
  event KeyFixedPriceUpdate(address subject, SubjectType subjectType, uint256 price, uint256 ts);

  event WishCreated(address wisher, uint256 reservedQuantity);
  event WishBound(address indexed sharesSubject, address indexed wisher);
  event ProtocolFeeDestinationUpdated(address protocolFeeDestination);
  event ProtocolFeePercentUpdated(uint256 protocolFeePercent);
  event SubjectFeePercentUpdated(uint256 subjectFeePercent);
  event OperatorUpdated(address operator);
  event DAOUpdated(address dao);
  event WishClosed(address indexed sharesSubject);
  event LockCreated(address sharesSubject, address user, uint256 unlockTime, uint256 ts);
  event LockUpdated(address sharesSubject, address user, uint256 unlockTime, uint256 ts);

  error InvalidZeroAddress();
  error ExistingWish(address wisher);
  error WishAlreadyBound(address wisher);
  error WishNotFound();
  error ClaimRewardShouldBeFalse();
  error TransactionFailedDueToPrice();
  error OnlyKeysOwnerCanBuyFirstKey();
  error BoundCannotBeBuyOrSell();
  error InvalidAmount();
  error InsufficientKeys(uint256 balance);
  error CannotSellLastKey();
  error ProtocolFeeDestinationNotSet();
  error ProtocolFeePercentNotSet();
  error SubjectFeePercentNotSet();
  error SubjectDoesNotMatch(address subject);
  error UnableToSendFunds();
  error UnableToClaimReward();
  error UnableToClaimParkedFees();
  error ReserveQuantityTooLarge();
  error WrongAmount();
  error ZeroReservedQuantity();
  error InvalidWish(address wisher);
  error NotTheOperator();
  error OperatorNotSet();
  error TooManyKeys();
  error CannotMakeASubjectABind();
  error SubjectCannotBeAWish();
  error UpgradedAlreadyInitialized();
  error ExpiredWishCanOnlyBeSold();
  error Forbidden();
  error GracePeriodExpired();
  error BoundWish();
  error WishNotExpiredYet();
  error WishAlreadyClosed();
  error DAONotSetup();
  error NotCloseableOrAlreadyClosed();
  error InsufficientFunds();
  error InvalidWishedPseudoAddress();

  address public protocolFeeDestination;
  uint256 public protocolFeePercent;
  uint256 public subjectFeePercent;

  // SharesSubject => (Holder => Balance)
  mapping(address => mapping(address => uint256)) public sharesBalance;

  // SharesSubject => Supply
  mapping(address => uint256) public sharesSupply;
  mapping(address => uint256) public sharesFixedPrice;

  struct KeyLockInfo {
    bool isLocked;
    uint256 lockTime;
    uint256 unlockTime;
  }
  mapping(address => mapping(address => KeyLockInfo)) public sharesLock;

  struct FeeInfo {
    uint256 protocolFeePercent;
    uint256 subjectFeePercent;
  }
  mapping(address => FeeInfo) public sharesFeeInfo;

  // @dev Mapping of authorized wishes
  mapping(address => address) public authorizedWishes;

  // @dev Struct to track a wish pass
  struct WishPass {
    address owner;
    uint256 totalSupply;
    uint256 createdAt;
    address subject;
    bool isClaimReward;
    uint256 reservedQuantity;
    uint256 subjectReward;
    // the fees are not paid immediately, but parked until the wish is bound or expires
    uint256 parkedFees;
    uint256 fixedPricePerKey;
    uint256 protocolFeePercent;
    uint256 subjectFeePercent;    
    mapping(address => uint256) balanceOf;
    mapping(address => KeyLockInfo) sharesLock;
  }

  // @dev Mapping of wish passes
  mapping(address => WishPass) public wishPasses;

  // @dev Enum to track the type of subject
  enum SubjectType {
    WISH,
    BIND,
    KEY
  }

  address public operator;

  // the duration of the wish. If the wish subject does not join the system before the deadline, the wish expires
  // and the refund process can be started
  uint256 public constant WISH_EXPIRATION_TIME = 50 days;
  // if the owners do not sell their wishes in the 15 days grace period, the value of the shares is transferred to a DAO wallet and used for community initiatives
  uint256 public constant WISH_DEADLINE_TIME = 15 days;

  // solhint-disable-next-line var-name-mixedcase
  address public DAO;
  // solhint-disable-next-line var-name-mixedcase
  uint256 public DAOBalance;
  uint256 public protocolFees;

  // @dev Modifier to check if the caller is the operator
  modifier onlyOperator() {
    if (operator == address(0)) revert OperatorNotSet();
    if (operator != _msgSender()) revert NotTheOperator();
    _;
  }

  modifier onlyDAO() {
    if (_msgSender() != DAO) revert Forbidden();
    _;
  }

  constructor() {
    protocolFeeDestination = msg.sender;
    protocolFeePercent = 0.05 ether; // 5%
    subjectFeePercent = 0.05 ether; // 5%
    
    BLAST.configureClaimableYield();
    BLAST.configureClaimableGas();
  }

  function setOperator(address _operator) external onlyGov {
    if (_operator == address(0)) revert InvalidZeroAddress();
    operator = _operator;
    emit OperatorUpdated(_operator);
  }

  function setDAO(address _dao) external onlyGov {
    if (_dao == address(0)) revert InvalidZeroAddress();
    DAO = _dao;
    emit DAOUpdated(_dao);
  }

  function getWishBalanceOf(address sharesSubject, address user) public view returns (uint256) {
    return wishPasses[sharesSubject].balanceOf[user];
  }

  function isWishReservedQuantityClaimed(address wisher) public view returns (bool) {
    return wishPasses[wisher].reservedQuantity == 0;
  }

  function setFeeDestination(address _feeDestination) public virtual onlyDAO {
    if (_feeDestination == address(0)) revert InvalidZeroAddress();
    protocolFeeDestination = _feeDestination;
    emit ProtocolFeeDestinationUpdated(_feeDestination);
  }

  function setProtocolFeePercent(uint256 _feePercent) public virtual onlyDAO {
    protocolFeePercent = _feePercent;
    emit ProtocolFeePercentUpdated(_feePercent);
  }

  function setSubjectFeePercent(uint256 _feePercent) public virtual onlyDAO {
    subjectFeePercent = _feePercent;
    emit SubjectFeePercentUpdated(_feePercent);
  }

  function setFeeInfoForClub(address sharesSubject, uint256 _protocolFeePercent, uint256 _subjectFeePercent) external onlyOperator {
    require(_protocolFeePercent > 0 && _subjectFeePercent > 0, "protocolFeePercent and subjectFeePercent should > 0");
    require(_protocolFeePercent <= protocolFeePercent, "club protocolFee should <= global protocolFee");
    require(_subjectFeePercent <= subjectFeePercent, "club subjectFee should <= global subjectFee");

    if (wishPasses[sharesSubject].owner != address(0)) {
      wishPasses[sharesSubject].protocolFeePercent = _protocolFeePercent;
      wishPasses[sharesSubject].subjectFeePercent = _subjectFeePercent;
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      wishPasses[wisher].protocolFeePercent = _protocolFeePercent;
      wishPasses[wisher].subjectFeePercent = _subjectFeePercent;
    } else {
      sharesFeeInfo[sharesSubject].protocolFeePercent = _protocolFeePercent;
      sharesFeeInfo[sharesSubject].subjectFeePercent = _subjectFeePercent;
    }
  }

  function getPrice(address sharesSubject, uint256 supply, uint256 amount) public view virtual returns (uint256) {
    require(amount > 0, "amount should > 0");
    uint256 fixedPricePerKey = getKeyFixedPrice(sharesSubject);
    if (fixedPricePerKey > 0) {
      uint256 sum1 = supply == 0 ? 0 : fixedPricePerKey * (supply - 1);
      uint256 sum2 = supply == 0 && amount == 1 ? 0 : fixedPricePerKey * (supply + amount - 1);
      return sum2 - sum1;
    }

    uint256 sum1 = supply == 0 ? 0 : ((supply - 1) * (supply) * (2 * (supply - 1) + 1)) / 6;
    uint256 sum2 = supply == 0 && amount == 1
      ? 0
      : ((supply + amount - 1) * (supply + amount) * (2 * (supply + amount - 1) + 1)) / 6;
    uint256 summation = sum2 - sum1;
    return (summation * 1 ether) / 16000;
  }

  function getControlPrice(address sharesSubject, uint256 amount) public view virtual returns (uint256) {
      uint256 fixedPricePerKey = getKeyFixedPrice(sharesSubject);
      return fixedPricePerKey * amount;
  }

  function getKeyFixedPrice(address sharesSubject) public view virtual returns (uint256) {
    if (wishPasses[sharesSubject].owner != address(0)) {
      return wishPasses[sharesSubject].fixedPricePerKey;
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      return wishPasses[wisher].fixedPricePerKey;
    } else {
      return sharesFixedPrice[sharesSubject];
    }
  }

  function getSupply(address sharesSubject) public view virtual returns (uint256) {
    if (wishPasses[sharesSubject].owner != address(0)) {
      return wishPasses[sharesSubject].totalSupply;
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      return wishPasses[wisher].totalSupply;
    } else {
      return sharesSupply[sharesSubject];
    }
  }

  function getBalanceOf(address sharesSubject, address user) public view virtual returns (uint256) {
    if (wishPasses[sharesSubject].owner != address(0)) {
      return wishPasses[sharesSubject].balanceOf[user];
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      return wishPasses[wisher].balanceOf[user];
    } else {
      return sharesBalance[sharesSubject][user];
    }
  }

  function getBuyPrice(address sharesSubject, uint256 amount) public view virtual returns (uint256) {
    uint256 supply = getSupply(sharesSubject);
    return getPrice(sharesSubject, supply, amount);
  }

  function getSellPrice(address sharesSubject, uint256 amount) public view virtual returns (uint256) {
    uint256 supply = getSupply(sharesSubject);
    if (supply < amount) revert InvalidAmount();
    return getPrice(sharesSubject, supply - amount, amount);
  }

  function getBuyPriceAfterFee(address sharesSubject, uint256 amount) public view virtual returns (uint256) {
    uint256 price = getBuyPrice(sharesSubject, amount);
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    return price + protocolFee + subjectFee;
  }

  function getSellPriceAfterFee(address sharesSubject, uint256 amount) public view virtual returns (uint256) {
    uint256 price = getSellPrice(sharesSubject, amount);
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    return price - protocolFee - subjectFee;
  }

  function getProtocolFee(address sharesSubject, uint256 price) public view virtual returns (uint256) {
    uint256 diyProtocolFee = doGetProtocolFee(sharesSubject);
    if (diyProtocolFee > 0) {
      return (price * diyProtocolFee) / 1 ether;
    }
    return (price * protocolFeePercent) / 1 ether;
  }

  function doGetProtocolFee(address sharesSubject) internal view returns (uint256) {
    if (wishPasses[sharesSubject].owner != address(0)) {
      return wishPasses[sharesSubject].protocolFeePercent;
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      return wishPasses[wisher].protocolFeePercent;
    } else {
      return sharesFeeInfo[sharesSubject].protocolFeePercent;
    }
  }

  function getSubjectFee(address sharesSubject, uint256 price) public view virtual returns (uint256) {
    uint256 diySubjectFee = doGetSubjectFee(sharesSubject);
    if (diySubjectFee > 0) {
      return (price * diySubjectFee) / 1 ether;
    }
    return (price * subjectFeePercent) / 1 ether;
  }

  function doGetSubjectFee(address sharesSubject) internal view returns (uint256) {
    if (wishPasses[sharesSubject].owner != address(0)) {
      return wishPasses[sharesSubject].subjectFeePercent;
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      return wishPasses[wisher].subjectFeePercent;
    } else {
      return sharesFeeInfo[sharesSubject].subjectFeePercent;
    }
  }

  function createClubWithFixedPrice(address sharesSubject, uint256 amount, uint256 fixedPricePerKey) external payable nonReentrant {
    require(_msgSender() == sharesSubject, "only room owner can create room");
    require(sharesSupply[sharesSubject] == 0 && wishPasses[sharesSubject].totalSupply == 0 && authorizedWishes[sharesSubject] == address(0), "club already exist!");

    require(fixedPricePerKey > 0, "key fixed price must large than 0!");
    sharesFixedPrice[sharesSubject] = fixedPricePerKey;
    emit KeyFixedPriceUpdate(sharesSubject, SubjectType.KEY, fixedPricePerKey, block.timestamp);    
    
    (, uint256 excess) = _buyShares(sharesSubject, amount, msg.value, true);
    if (excess > 0) _sendFundsBackIfUnused(excess);
  }

  // @dev Buy shares for a given subject
  // @notice The function allows to buy 3 types of shares:
  //   - Keys: The shares of the subject
  //   - Wishes: The shares of the wisher who has not joined yet the system
  //   - Authorized Wishes: The shares of the wisher bound to the subject
  // @param sharesSubject The subject of the shares
  // @param amount The amount of shares to buy
  function buyShares(address sharesSubject, uint256 amount) external payable nonReentrant {
    (, uint256 excess) = _buyShares(sharesSubject, amount, msg.value, true);
    if (excess > 0) _sendFundsBackIfUnused(excess);
  }

  function _buyShares(
    address sharesSubject,
    uint256 amount,
    uint256 expectedPrice,
    bool revertOnPriceError
  ) internal returns (bool, uint256) {
    if (amount == 0) {
      if (revertOnPriceError) revert InvalidAmount();
      else return (false, expectedPrice);
    }
    uint256 supply = getSupply(sharesSubject);
    if (supply == 0 && sharesSubject != _msgSender()) revert OnlyKeysOwnerCanBuyFirstKey();
    uint256 price = getPrice(sharesSubject, supply, amount);
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    if (expectedPrice < price + protocolFee + subjectFee) {
      if (revertOnPriceError) revert TransactionFailedDueToPrice();
      else return (false, expectedPrice);
    }
    if (wishPasses[sharesSubject].owner != address(0)) {
      _buyWish(sharesSubject, supply, amount, price);
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      _buyBind(sharesSubject, supply, amount, price);
    } else {
      _buyKey(sharesSubject, supply, amount, price);
    }
    // It returns the excess sent by the user if any
    return (true, expectedPrice - price - protocolFee - subjectFee);
  }

  function _buyWish(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    if (wishPasses[sharesSubject].subject != address(0)) revert BoundCannotBeBuyOrSell();
    if (wishPasses[sharesSubject].createdAt + WISH_EXPIRATION_TIME < block.timestamp) revert ExpiredWishCanOnlyBeSold();
    wishPasses[sharesSubject].totalSupply += amount;
    wishPasses[sharesSubject].balanceOf[_msgSender()] += amount;
    wishPasses[sharesSubject].subjectReward += getSubjectFee(sharesSubject, price);
    wishPasses[sharesSubject].parkedFees += getProtocolFee(sharesSubject, price);
    uint256 totalProtocolFees = wishPasses[sharesSubject].parkedFees + protocolFees;
    emit Trade(_msgSender(), sharesSubject, true, amount, price, supply + amount, SubjectType.WISH, block.timestamp, totalProtocolFees);
  }

  function _buyBind(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    address wisher = authorizedWishes[sharesSubject];
    wishPasses[wisher].totalSupply += amount;
    wishPasses[wisher].balanceOf[_msgSender()] += amount;
    protocolFees += getProtocolFee(sharesSubject, price);
    emit Trade(_msgSender(), sharesSubject, true, amount, price, supply + amount, SubjectType.BIND, block.timestamp, protocolFees);
    (bool success, ) = sharesSubject.call{value: getSubjectFee(sharesSubject, price)}("");
    if (!success) revert UnableToSendFunds();
  }

  function _buyKey(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    sharesBalance[sharesSubject][_msgSender()] += amount;
    sharesSupply[sharesSubject] += amount;
    protocolFees += getProtocolFee(sharesSubject, price);
    emit Trade(_msgSender(), sharesSubject, true, amount, price, supply + amount, SubjectType.KEY, block.timestamp, protocolFees);
    (bool success, ) = sharesSubject.call{value: getSubjectFee(sharesSubject, price)}("");
    if (!success) revert UnableToSendFunds();
  }

  function _sendFundsBackIfUnused(uint256 amount) internal {
    (bool success, ) = _msgSender().call{value: amount}("");
    if (!success) revert UnableToSendFunds();
  }

  // @dev Check the balance of a given subject and revert if not correct
  // @param sharesSubject The subject of the shares
  // @param balance The balance of the subject
  // @param amount The amount to check
  function _checkBalance(address sharesSubject, uint256 balance, uint256 amount) internal view {
    if (balance < amount) revert InsufficientKeys(balance);
    if (sharesSubject == _msgSender() && balance == amount) revert CannotSellLastKey();
  }

  // @dev Sell shares for a given subject
  // @notice The function allows to sell 3 types of shares:
  //   - Keys: The shares of the subject
  //   - Wishes: The shares of the wisher who has not joined yet the system
  //   - Authorized Wishes: The shares of the wisher bound to the subject
  // @param sharesSubject The subject of the shares
  // @param amount The amount of shares to sell
  function sellShares(address sharesSubject, uint256 amount) external nonReentrant {
    if (amount == 0) revert InvalidAmount();
    uint256 supply = getSupply(sharesSubject);
    if (supply <= amount) revert CannotSellLastKey();
    bool isLocked = isKeyLocked(sharesSubject, _msgSender());
    require(isLocked == false, "key locked, can not sell now!");

    uint256 price = getPrice(sharesSubject, supply - amount, amount);
    uint256 balance = getBalanceOf(sharesSubject, _msgSender());
    _checkBalance(sharesSubject, balance, amount);
    if (wishPasses[sharesSubject].owner != address(0)) {
      _sellWish(sharesSubject, supply, amount, price);
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      _sellBind(sharesSubject, supply, amount, price);
    } else {
      _sellKey(sharesSubject, supply, amount, price);
    }
  }

  function _sellWish(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    if (wishPasses[sharesSubject].subject != address(0)) revert BoundCannotBeBuyOrSell();
    if (wishPasses[sharesSubject].createdAt + WISH_EXPIRATION_TIME + WISH_DEADLINE_TIME < block.timestamp)
      revert GracePeriodExpired();
    wishPasses[sharesSubject].totalSupply -= amount;
    wishPasses[sharesSubject].balanceOf[_msgSender()] -= amount;
    if (wishPasses[sharesSubject].createdAt + WISH_EXPIRATION_TIME < block.timestamp) {
      // since the subject did not bind the wish, the user is not charged for the sale,
      // on the opposite, the seller will have also the unused subjectFee
      // Instead the protocolFee will be collected by the DAO at the end of the grace period
      wishPasses[sharesSubject].subjectReward -= subjectFee;
      _sendSellFunds(price + subjectFee, 0, 0, address(0));
    } else {
      // silencing wrong warning
      // solhint-disable-next-line
      wishPasses[sharesSubject].subjectReward += subjectFee;
      // solhint-disable-next-line reentrancy
      wishPasses[sharesSubject].parkedFees += protocolFee;
      // solhint-disable-next-line reentrancy
      _sendSellFunds(price, protocolFee, subjectFee, address(0));
    }
    
    uint256 totalProtocolFees = wishPasses[sharesSubject].parkedFees + protocolFees;
    emit Trade(_msgSender(), sharesSubject, false, amount, price, supply - amount, SubjectType.WISH, block.timestamp, totalProtocolFees);
  }

  function _sellBind(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    address wisher = authorizedWishes[sharesSubject];
    wishPasses[wisher].totalSupply -= amount;
    wishPasses[wisher].balanceOf[_msgSender()] -= amount;
    protocolFees += protocolFee;
    emit Trade(_msgSender(), sharesSubject, false, amount, price, supply - amount, SubjectType.BIND, block.timestamp, protocolFees);
    _sendSellFunds(price, protocolFee, subjectFee, sharesSubject);
  }

  function _sellKey(address sharesSubject, uint256 supply, uint256 amount, uint256 price) internal {
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    uint256 subjectFee = getSubjectFee(sharesSubject, price);
    sharesBalance[sharesSubject][_msgSender()] -= amount;
    sharesSupply[sharesSubject] -= amount;
    protocolFees += protocolFee;
    emit Trade(_msgSender(), sharesSubject, false, amount, price, supply - amount, SubjectType.KEY, block.timestamp, protocolFees);
    _sendSellFunds(price, protocolFee, subjectFee, sharesSubject);
  }

  // @dev Internal function to send funds when selling shares or wishes
  //   It reverts if any sends fail.
  // @param price The price
  // @param protocolFee The protocol fee
  // @param subjectFee The subject fee
  // @param sharesSubject The subject of the shares
  function _sendSellFunds(uint256 price, uint256 protocolFee, uint256 subjectFee, address sharesSubject) internal {
    (bool success1, ) = _msgSender().call{value: price - protocolFee - subjectFee}("");
    bool success2 = true;
    if (sharesSubject != address(0)) {
      (success2, ) = sharesSubject.call{value: subjectFee}("");
    }
    if (!success1 || !success2) revert UnableToSendFunds();
  }

  // @dev This function is used to buy shares for multiple subjects at once
  //   Limit the elements in the array when calling this function to not
  //   risk to run out of gas
  // @param sharesSubjects The array of subjects to buy shares for
  // @param amounts The array of amounts to buy for each subject
  function batchBuyShares(
    address[] calldata sharesSubjects,
    uint256[] calldata amounts,
    uint256[] calldata expectedPrices
  ) external payable virtual nonReentrant {
    if (sharesSubjects.length != amounts.length || sharesSubjects.length != expectedPrices.length) revert WrongAmount();
    if (sharesSubjects.length > 10) {
      // avoid the risk of going out-of-gas
      revert TooManyKeys();
    }
    uint256 consumed = 0;
    for (uint256 i = 0; i < sharesSubjects.length; i++) {
      (bool success, uint256 excess) = _buyShares(
        sharesSubjects[i],
        amounts[i],
        expectedPrices[i],
        // Since prices can change, we don't revert on price error to avoid cancelling all the purchases
        false
      );
      if (success) {
        consumed += expectedPrices[i] - excess;
      }
    }
    if (msg.value < consumed) revert InsufficientFunds();
    uint256 remain = msg.value - consumed;
    _sendFundsBackIfUnused(remain);
  }

  function lockKey(address sharesSubject, uint256 unlockTime) external nonReentrant {
    require(block.timestamp < unlockTime, "unlockTime should >= current time!");
    uint256 keyBalance = getBalanceOf(sharesSubject, _msgSender());
    require(keyBalance > 0, "no key to lock!");

    KeyLockInfo storage lockInfo;
    if (wishPasses[sharesSubject].owner != address(0)) {
      lockInfo = wishPasses[sharesSubject].sharesLock[_msgSender()];
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      lockInfo = wishPasses[wisher].sharesLock[_msgSender()];
    } else {
      lockInfo = sharesLock[sharesSubject][_msgSender()];
    }

    if (lockInfo.isLocked) {
      require(lockInfo.unlockTime < unlockTime, "new unlockTime should > current unlockTime!");
      lockInfo.unlockTime = unlockTime;
      emit LockUpdated(sharesSubject, _msgSender(), unlockTime, block.timestamp);
    } else {
      lockInfo.isLocked = true;
      lockInfo.lockTime = block.timestamp;
      lockInfo.unlockTime = unlockTime;
      emit LockCreated(sharesSubject, _msgSender(), unlockTime, block.timestamp);
    }
  }

  function isKeyLocked(address sharesSubject, address user) public view returns (bool) {
    KeyLockInfo memory lockInfo;
    if (wishPasses[sharesSubject].owner != address(0)) {
      lockInfo = wishPasses[sharesSubject].sharesLock[user];
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      lockInfo = wishPasses[wisher].sharesLock[user];
    } else {
      lockInfo = sharesLock[sharesSubject][user];
    }
 
    if (lockInfo.isLocked == false) {
      return false;
    }

    //locked, check whether unlock
    if (block.timestamp > lockInfo.unlockTime) {
      //already unlocked
      return false;
    }

    return true;
  }

  function getKeyLockInfo(address sharesSubject, address user) public view returns (bool, uint256, uint256) {
    KeyLockInfo memory lockInfo;
    if (wishPasses[sharesSubject].owner != address(0)) {
      lockInfo = wishPasses[sharesSubject].sharesLock[user];
    } else if (authorizedWishes[sharesSubject] != address(0)) {
      address wisher = authorizedWishes[sharesSubject];
      lockInfo = wishPasses[wisher].sharesLock[user];
    } else {
      lockInfo = sharesLock[sharesSubject][user];
    }
    return (lockInfo.isLocked, lockInfo.lockTime, lockInfo.unlockTime);
  }

  // @dev This function is used to create a new wish
  function newWishPass(address wisher, uint256 reservedQuantity, uint256 fixedPricePerKey) external virtual onlyOperator {
    if (uint160(wisher) >= uint160(0x0000000000000100000000000000000000000000)) revert InvalidWishedPseudoAddress();
    if (reservedQuantity == 0 || reservedQuantity > 50) revert ReserveQuantityTooLarge();
    if (wisher == address(0)) revert InvalidZeroAddress();
    if (wishPasses[wisher].owner != address(0)) revert ExistingWish(wishPasses[wisher].owner);
    wishPasses[wisher].owner = wisher;
    wishPasses[wisher].reservedQuantity = reservedQuantity;
    wishPasses[wisher].totalSupply = reservedQuantity;
    wishPasses[wisher].createdAt = block.timestamp;
    emit WishCreated(wisher, reservedQuantity);

    if (fixedPricePerKey > 0) {
      wishPasses[wisher].fixedPricePerKey = fixedPricePerKey;
      emit KeyFixedPriceUpdate(wisher, SubjectType.WISH, fixedPricePerKey, block.timestamp);
    }
  }

  function bindWishPass(address sharesSubject, address wisher) external virtual onlyOperator nonReentrant {
    if (sharesSupply[sharesSubject] > 0) revert CannotMakeASubjectABind();
    if (sharesSubject == wisher) revert SubjectCannotBeAWish();
    if (sharesSubject == address(0) || wisher == address(0)) revert InvalidZeroAddress();
    if (wishPasses[wisher].owner != wisher) revert WishNotFound();
    require(wishPasses[wisher].createdAt + WISH_EXPIRATION_TIME >= block.timestamp, "wish expired!");
    if (authorizedWishes[sharesSubject] != address(0)) revert WishAlreadyBound(authorizedWishes[sharesSubject]);

    wishPasses[wisher].subject = sharesSubject;
    authorizedWishes[sharesSubject] = wisher;
    if (wishPasses[wisher].isClaimReward) revert ClaimRewardShouldBeFalse();
    wishPasses[wisher].isClaimReward = true;
    emit WishBound(sharesSubject, wisher);
    if (wishPasses[wisher].subjectReward > 0) {
      protocolFees += wishPasses[wisher].parkedFees;
      (bool success, ) = sharesSubject.call{value: wishPasses[wisher].subjectReward}("");
      if (!success) revert UnableToClaimReward();
    }
  }

  // @dev This function is used to claim the reserved wish pass
  //   Only the sharesSubject itself can call this function to make the claim
  function claimReservedWishPass() external payable virtual nonReentrant {
    address sharesSubject = _msgSender();
    if (authorizedWishes[sharesSubject] == address(0)) revert WishNotFound();
    address wisher = authorizedWishes[sharesSubject];
    if (wishPasses[wisher].owner != wisher) revert InvalidWish(wishPasses[wisher].owner);
    if (wishPasses[wisher].subject != sharesSubject) revert SubjectDoesNotMatch(wishPasses[wisher].subject);
    if (wishPasses[wisher].reservedQuantity == 0) revert ZeroReservedQuantity();
    require(wishPasses[wisher].createdAt + WISH_EXPIRATION_TIME >= block.timestamp, "wish expired!");

    uint256 amount = wishPasses[wisher].reservedQuantity;
    uint256 price = getPrice(sharesSubject, 0, amount);
    uint256 protocolFee = getProtocolFee(sharesSubject, price);
    if (msg.value < price + protocolFee) revert TransactionFailedDueToPrice();
    wishPasses[wisher].reservedQuantity = 0;
    wishPasses[wisher].balanceOf[sharesSubject] += amount;
    protocolFees += protocolFee;
    uint256 supply = wishPasses[wisher].totalSupply;
    emit Trade(_msgSender(), sharesSubject, true, amount, price, supply, SubjectType.BIND, block.timestamp, protocolFees);
    if (msg.value - (price + protocolFee) > 0) {
      _sendFundsBackIfUnused(msg.value - (price + protocolFee));
    }
  }

  // @dev This function is used withdraw the protocol fees
  function withdrawProtocolFees(uint256 amount) external nonReentrant {
    if (amount == 0) amount = protocolFees;
    if (amount > protocolFees) revert InvalidAmount();
    if (_msgSender() != protocolFeeDestination || protocolFeeDestination == address(0) || protocolFees == 0) revert Forbidden();
    protocolFees -= amount;
    (bool success, ) = protocolFeeDestination.call{value: amount}("");
    if (!success) revert UnableToSendFunds();
  }

  // @dev This function is used to close an expired wish
  function closeExpiredWish(address sharesSubject) external onlyDAO {
    if (wishPasses[sharesSubject].subject != address(0)) revert BoundWish();
    if (wishPasses[sharesSubject].createdAt + WISH_EXPIRATION_TIME + WISH_DEADLINE_TIME > block.timestamp)
      revert WishNotExpiredYet();
    if (wishPasses[sharesSubject].parkedFees == 0) revert NotCloseableOrAlreadyClosed();
    uint256 remain;
    if (wishPasses[sharesSubject].totalSupply - wishPasses[sharesSubject].reservedQuantity > 0) {
      remain = getPrice(sharesSubject, 
        wishPasses[sharesSubject].reservedQuantity,
        wishPasses[sharesSubject].totalSupply - wishPasses[sharesSubject].reservedQuantity
      );
    }
    DAOBalance += wishPasses[sharesSubject].parkedFees + wishPasses[sharesSubject].subjectReward + remain;
    wishPasses[sharesSubject].parkedFees = 0;
    emit WishClosed(sharesSubject);
  }

  // @dev This function is used to transfer unused wish fees to the DAO
  function withdrawDAOFunds(uint256 amount, address beneficiary) external onlyDAO nonReentrant {
    if (DAO == address(0)) revert DAONotSetup();
    if (DAOBalance == 0) revert InsufficientFunds();
    if (beneficiary == address(0)) beneficiary = DAO;
    if (amount == 0) amount = DAOBalance;
    if (amount > DAOBalance) revert InvalidAmount();
    if (_msgSender() != DAO) revert Forbidden();
    DAOBalance -= amount;
    (bool success, ) = beneficiary.call{value: amount}("");
    if (!success) revert UnableToSendFunds();
  }

  function readClaimableYield() external view returns (uint256) {
	  return BLAST.readClaimableYield(address(this));
  }

  function claimAllYield() external onlyDAO nonReentrant {
	  BLAST.claimAllYield(address(this), msg.sender);
  }

  function readGasParams() external view returns (uint256 etherSeconds, uint256 etherBalance, uint256 lastUpdated, GasMode) {
    return BLAST.readGasParams(address(this));
  }

  function claimMyContractsGas() external onlyDAO nonReentrant {
    BLAST.claimAllGas(address(this), msg.sender);
  }
}
