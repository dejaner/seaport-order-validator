// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import { ItemType } from "./ConsiderationEnums.sol";
import {
    Order,
    OrderParameters,
    BasicOrderParameters,
    OfferItem,
    ConsiderationItem
} from "./ConsiderationStructs.sol";
import { ConsiderationTypeHashes } from "./ConsiderationTypeHashes.sol";
import {
    ConsiderationInterface
} from "../interfaces/ConsiderationInterface.sol";
import {
    ConduitControllerInterface
} from "../interfaces/ConduitControllerInterface.sol";
import { ZoneInterface } from "../interfaces/ZoneInterface.sol";
import { IERC721 } from "@openzeppelin/contracts/interfaces/IERC721.sol";
import { IERC1155 } from "@openzeppelin/contracts/interfaces/IERC1155.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC165 } from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {
    ErrorsAndWarnings,
    ErrorsAndWarningsLib
} from "./ErrorsAndWarnings.sol";
import { SafeStaticCall } from "./SafeStaticCall.sol";
import { Murky } from "./Murky.sol";
import {
    RoyaltyEngineInterface
} from "../interfaces/RoyaltyEngineInterface.sol";
import {
    IssueParser,
    ValidationConfiguration,
    TimeIssue,
    StatusIssue,
    OfferIssue,
    ConsiderationIssue,
    ProtocolFeeIssue,
    ERC721Issue,
    ERC1155Issue,
    ERC20Issue,
    NativeIssue,
    ZoneIssue,
    ConduitIssue,
    RoyaltyFeeIssue,
    SignatureIssue,
    GenericIssue
} from "./SeaportValidatorTypes.sol";
import { SignatureVerification } from "./SignatureVerification.sol";

/**
 * @title SeaportValidator
 * @notice SeaportValidator provides advanced validation to seaport orders.
 */
contract SeaportValidator is
    ConsiderationTypeHashes,
    SignatureVerification,
    Murky
{
    using ErrorsAndWarningsLib for ErrorsAndWarnings;
    using SafeStaticCall for address;
    using IssueParser for *;

    /// @notice Cross-chain seaport address
    ConsiderationInterface public constant seaport =
        ConsiderationInterface(0x00000000006c3852cbEf3e08E8dF289169EdE581);
    /// @notice Cross-chain conduit controller Address
    ConduitControllerInterface public constant conduitController =
        ConduitControllerInterface(0x00000000F9490004C11Cef243f5400493c00Ad63);
    /// @notice Ethereum royalty engine address
    RoyaltyEngineInterface public immutable royaltyEngine;

    constructor() {
        address royaltyEngineAddress;
        if (block.chainid == 1) {
            royaltyEngineAddress = 0x0385603ab55642cb4Dd5De3aE9e306809991804f;
        } else if (block.chainid == 3) {
            // Ropsten
            royaltyEngineAddress = 0xFf5A6F7f36764aAD301B7C9E85A5277614Df5E26;
        } else if (block.chainid == 4) {
            // Rinkeby
            royaltyEngineAddress = 0x8d17687ea9a6bb6efA24ec11DcFab01661b2ddcd;
        } else if (block.chainid == 5) {
            // Goerli
            royaltyEngineAddress = 0xe7c9Cb6D966f76f3B5142167088927Bf34966a1f;
        } else if (block.chainid == 42) {
            // Kovan
            royaltyEngineAddress = 0x54D88324cBedfFe1e62c9A59eBb310A11C295198;
        } else if (block.chainid == 137) {
            // Polygon
            royaltyEngineAddress = 0x28EdFcF0Be7E86b07493466e7631a213bDe8eEF2;
        } else if (block.chainid == 80001) {
            // Mumbai
            royaltyEngineAddress = 0x0a01E11887f727D1b1Cd81251eeEE9BEE4262D07;
        } else {
            // No royalty engine for this chain
            royaltyEngineAddress = address(0);
        }

        royaltyEngine = RoyaltyEngineInterface(royaltyEngineAddress);
    }

    /**
     * @notice Conduct a comprehensive validation of the given order.
     *    `isValidOrder` validates simple orders that adhere to a set of rules defined below:
     *    - The order is either a bid or an ask order (one NFT to buy or one NFT to sell).
     *    - The first consideration is the primary consideration.
     *    - The order pays up to two fees in the fungible token currency. First fee is protocol fee, second is royalty fee.
     *    - In private orders, the last consideration specifies a recipient for the offer item.
     *    - Offer items must be owned and properly approved by the offerer.
     *    - There must be one offer item
     *    - Consideration items must exist.
     *    - The signature must be valid, or the order must be already validated on chain
     * @param order The order to validate.
     * @return errorsAndWarnings The errors and warnings found in the order.
     */
    function isValidOrder(Order calldata order)
        external
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        return
            isValidOrderWithConfiguration(
                ValidationConfiguration(address(0), 0, false, false),
                order
            );
    }

    /**
     * @notice Same as `isValidOrder` but allows for more configuration related to fee validation.
     *    If `skipStrictValidation` is set order logic validation is not carried out: fees are not
     *       checked and there may be more than one offer item as well as any number of consideration items.
     */
    function isValidOrderWithConfiguration(
        ValidationConfiguration memory validationConfiguration,
        Order memory order
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Concatenates errorsAndWarnings with the returns errorsAndWarnings of `validateTime`
        errorsAndWarnings.concat(validateTime(order.parameters));
        errorsAndWarnings.concat(validateOrderStatus(order.parameters));
        errorsAndWarnings.concat(validateOfferItems(order.parameters));
        errorsAndWarnings.concat(validateConsiderationItems(order.parameters));
        errorsAndWarnings.concat(isValidZone(order.parameters));
        errorsAndWarnings.concat(validateSignature(order));

        // Skip strict validation if requested
        if (!validationConfiguration.skipStrictValidation) {
            errorsAndWarnings.concat(
                validateStrictLogic(
                    order.parameters,
                    validationConfiguration.protocolFeeRecipient,
                    validationConfiguration.protocolFeeBips,
                    validationConfiguration.checkRoyaltyFee
                )
            );
        }
    }

    /**
     * @notice Checks if a conduit key is valid.
     * @param conduitKey The conduit key to check.
     * @return errorsAndWarnings The errors and warnings
     */
    function isValidConduit(bytes32 conduitKey)
        external
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        (, errorsAndWarnings) = getApprovalAddress(conduitKey);
    }

    /**
     * @notice Gets the approval address for the given conduit key
     * @param conduitKey Conduit key to get approval address for
     * @return errorsAndWarnings An ErrorsAndWarnings structs with results
     */
    function getApprovalAddress(bytes32 conduitKey)
        public
        view
        returns (address, ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Zero conduit key corresponds to seaport
        if (conduitKey == 0) return (address(seaport), errorsAndWarnings);

        // Pull conduit info from conduitController
        (address conduitAddress, bool exists) = conduitController.getConduit(
            conduitKey
        );

        // Conduit does not exist
        if (!exists) {
            errorsAndWarnings.addError(ConduitIssue.KeyInvalid.parseInt());
            conduitAddress = address(0); // Don't return invalid conduit
        }

        return (conduitAddress, errorsAndWarnings);
    }

    /**
     * @notice Validates the signature for the order using the offerer's current counter
     * @dev Will also check if order is validated on chain.
     */
    function validateSignature(Order memory order)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        // Pull current counter from seaport
        uint256 currentCounter = seaport.getCounter(order.parameters.offerer);

        return validateSignatureWithCounter(order, currentCounter);
    }

    /**
     * @notice Validates the signature for the order using the given counter
     * @dev Will also check if order is validated on chain.
     */
    function validateSignatureWithCounter(Order memory order, uint256 counter)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Get current counter for context
        uint256 currentCounter = seaport.getCounter(order.parameters.offerer);

        if (currentCounter > counter) {
            // Counter strictly increases
            errorsAndWarnings.addError(SignatureIssue.LowCounter.parseInt());
            return errorsAndWarnings;
        } else if (counter > 2 && currentCounter < counter - 2) {
            // Will require significant input from offerer to validate, warn
            errorsAndWarnings.addWarning(SignatureIssue.HighCounter.parseInt());
        }

        bytes32 orderHash = _deriveOrderHash(order.parameters, counter);

        // Check if order is validated on chain
        (bool isValid, , , ) = seaport.getOrderStatus(orderHash);

        if (isValid) {
            // Shortcut success, valid on chain
            return errorsAndWarnings;
        }

        // Get signed digest
        bytes32 eip712Digest = _deriveEIP712Digest(orderHash);
        if (
            // Checks EIP712 and EIP1271
            !_isValidSignature(
                order.parameters.offerer,
                eip712Digest,
                order.signature
            )
        ) {
            if (
                order.parameters.consideration.length !=
                order.parameters.totalOriginalConsiderationItems
            ) {
                // May help diagnose signature issues
                errorsAndWarnings.addWarning(
                    SignatureIssue.OriginalConsiderationItems.parseInt()
                );
            }

            // Signature is invalid
            errorsAndWarnings.addError(SignatureIssue.Invalid.parseInt());
        }
    }

    /**
     * @notice Check the time validity of an order
     * @param orderParameters The parameters for the order to validate
     * @return errorsAndWarnings The Issues and warnings
     */
    function validateTime(OrderParameters memory orderParameters)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        if (orderParameters.endTime <= orderParameters.startTime) {
            // Order duration is zero
            errorsAndWarnings.addError(
                TimeIssue.EndTimeBeforeStartTime.parseInt()
            );
            return errorsAndWarnings;
        }

        if (orderParameters.endTime < block.timestamp) {
            // Order is expired
            errorsAndWarnings.addError(TimeIssue.Expired.parseInt());
            return errorsAndWarnings;
        } else if (orderParameters.endTime > block.timestamp + (30 weeks)) {
            // Order expires in a long time
            errorsAndWarnings.addWarning(
                TimeIssue.DistantExpiration.parseInt()
            );
        }

        if (orderParameters.startTime > block.timestamp) {
            // Order is not active
            errorsAndWarnings.addWarning(TimeIssue.NotActive.parseInt());
        }

        if (
            orderParameters.endTime -
                (
                    orderParameters.startTime > block.timestamp
                        ? orderParameters.startTime
                        : block.timestamp
                ) <
            30 minutes
        ) {
            // Order has a short duration
            errorsAndWarnings.addWarning(TimeIssue.ShortOrder.parseInt());
        }
    }

    /**
     * @notice Validate the status of an order
     * @param orderParameters The parameters for the order to validate
     * @return errorsAndWarnings  The errors and warnings
     */
    function validateOrderStatus(OrderParameters memory orderParameters)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Pull current counter from seaport
        uint256 currentOffererCounter = seaport.getCounter(
            orderParameters.offerer
        );
        // Derive order hash using orderParameters and currentOffererCounter
        bytes32 orderHash = _deriveOrderHash(
            orderParameters,
            currentOffererCounter
        );
        // Get order status from seaport
        (, bool isCancelled, uint256 totalFilled, uint256 totalSize) = seaport
            .getOrderStatus(orderHash);

        if (isCancelled) {
            // Order is cancelled
            errorsAndWarnings.addError(StatusIssue.Cancelled.parseInt());
        }

        if (totalSize > 0 && totalFilled == totalSize) {
            // Order is fully filled
            errorsAndWarnings.addError(StatusIssue.FullyFilled.parseInt());
        }
    }

    /**
     * @notice Validate all offer items for an order. Ensures that
     *    offerer has sufficient balance and approval for each item.
     * @dev Amounts are not summed and verified, just the individual amounts.
     * @param orderParameters The parameters for the order to validate
     * @return errorsAndWarnings  The errors and warnings
     */
    function validateOfferItems(OrderParameters memory orderParameters)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Iterate over each offer item and validate it
        for (uint256 i = 0; i < orderParameters.offer.length; i++) {
            errorsAndWarnings.concat(validateOfferItem(orderParameters, i));
        }

        // You must have an offer item
        if (orderParameters.offer.length == 0) {
            errorsAndWarnings.addError(OfferIssue.ZeroItems.parseInt());
        }

        // Warning if there is more than one offer item
        if (orderParameters.offer.length > 1) {
            errorsAndWarnings.addWarning(OfferIssue.MoreThanOneItem.parseInt());
        }

        // Check for duplicate offer items
        for (uint256 i = 0; i < orderParameters.offer.length; i++) {
            // Iterate over each offer item
            OfferItem memory offerItem1 = orderParameters.offer[i];

            for (uint256 j = i + 1; j < orderParameters.offer.length; j++) {
                // Iterate over each remaining offer item
                // (previous items already check with this item)
                OfferItem memory offerItem2 = orderParameters.offer[j];

                // Check if token and id are the same
                if (
                    offerItem1.token == offerItem2.token &&
                    offerItem1.identifierOrCriteria ==
                    offerItem2.identifierOrCriteria
                ) {
                    errorsAndWarnings.addError(
                        OfferIssue.DuplicateItem.parseInt()
                    );
                }
            }
        }
    }

    /**
     * @notice Validates an offer item
     * @param orderParameters The parameters for the order to validate
     * @param offerItemIndex The index of the offerItem in offer array to validate
     * @return errorsAndWarnings An ErrorsAndWarnings structs with results
     */
    function validateOfferItem(
        OrderParameters memory orderParameters,
        uint256 offerItemIndex
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        // First validate the parameters (correct amount, contract, etc)
        errorsAndWarnings = validateOfferItemParameters(
            orderParameters,
            offerItemIndex
        );
        if (errorsAndWarnings.hasErrors()) {
            // Only validate approvals and balances if parameters are valid
            return errorsAndWarnings;
        }

        // Validate approvals and balances for the offer item
        errorsAndWarnings.concat(
            validateOfferItemApprovalAndBalance(orderParameters, offerItemIndex)
        );
    }

    /**
     * @notice Validates the OfferItem parameters. This includes token contract validation
     * @dev OfferItems with criteria are currently not allowed
     * @param orderParameters The parameters for the order to validate
     * @param offerItemIndex The index of the offerItem in offer array to validate
     * @return errorsAndWarnings An ErrorsAndWarnings structs with results
     */
    function validateOfferItemParameters(
        OrderParameters memory orderParameters,
        uint256 offerItemIndex
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        OfferItem memory offerItem = orderParameters.offer[offerItemIndex];

        // Check if start amount and end amount are zero
        if (offerItem.startAmount == 0 && offerItem.endAmount == 0) {
            errorsAndWarnings.addError(OfferIssue.AmountZero.parseInt());
        }

        if (offerItem.itemType == ItemType.ERC721) {
            // ERC721 type requires amounts to be 1
            if (offerItem.startAmount != 1 || offerItem.endAmount != 1) {
                errorsAndWarnings.addError(ERC721Issue.AmountNotOne.parseInt());
            }

            // Check the EIP165 token interface
            if (!checkInterface(offerItem.token, type(IERC721).interfaceId)) {
                errorsAndWarnings.addError(ERC721Issue.InvalidToken.parseInt());
            }
        } else if (offerItem.itemType == ItemType.ERC1155) {
            // Check the EIP165 token interface
            if (!checkInterface(offerItem.token, type(IERC1155).interfaceId)) {
                errorsAndWarnings.addError(
                    ERC1155Issue.InvalidToken.parseInt()
                );
            }
        } else if (offerItem.itemType == ItemType.ERC20) {
            // ERC20 must have `identifierOrCriteria` be zero
            if (offerItem.identifierOrCriteria != 0) {
                errorsAndWarnings.addError(
                    ERC20Issue.IdentifierNonZero.parseInt()
                );
            }

            // Validate contract, should return an uint256 if its an ERC20
            if (
                !offerItem.token.safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC20.allowance.selector,
                        address(seaport),
                        address(seaport)
                    ),
                    0
                )
            ) {
                errorsAndWarnings.addError(ERC20Issue.InvalidToken.parseInt());
            }
        } else if (offerItem.itemType == ItemType.NATIVE) {
            // NATIVE must have `token` be zero address
            if (offerItem.token != address(0)) {
                errorsAndWarnings.addError(NativeIssue.TokenAddress.parseInt());
            }

            // NATIVE must have `identifierOrCriteria` be zero
            if (offerItem.identifierOrCriteria != 0) {
                errorsAndWarnings.addError(
                    NativeIssue.IdentifierNonZero.parseInt()
                );
            }
        } else {
            // Unsupported offer item type
            errorsAndWarnings.addError(GenericIssue.InvalidItemType.parseInt());
        }
    }

    /**
     * @notice Validates the OfferItem approvals and balances
     * @param orderParameters The parameters for the order to validate
     * @param offerItemIndex The index of the offerItem in offer array to validate
     * @return errorsAndWarnings An ErrorsAndWarnings structs with results
     */
    function validateOfferItemApprovalAndBalance(
        OrderParameters memory orderParameters,
        uint256 offerItemIndex
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        // Note: If multiple items are of the same token, token amounts are not summed for validation

        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Get the approval address for the given conduit key
        (
            address approvalAddress,
            ErrorsAndWarnings memory ew
        ) = getApprovalAddress(orderParameters.conduitKey);

        errorsAndWarnings.concat(ew);

        if (ew.hasErrors()) {
            // Approval address is invalid
            return errorsAndWarnings;
        }

        OfferItem memory offerItem = orderParameters.offer[offerItemIndex];

        if (offerItem.itemType == ItemType.ERC721) {
            IERC721 token = IERC721(offerItem.token);

            // Check that offerer owns token
            if (
                !address(token).safeStaticCallAddress(
                    abi.encodeWithSelector(
                        IERC721.ownerOf.selector,
                        offerItem.identifierOrCriteria
                    ),
                    orderParameters.offerer
                )
            ) {
                errorsAndWarnings.addError(ERC721Issue.NotOwner.parseInt());
            }

            // Check for approval via `getApproved`
            if (
                !address(token).safeStaticCallAddress(
                    abi.encodeWithSelector(
                        IERC721.getApproved.selector,
                        offerItem.identifierOrCriteria
                    ),
                    approvalAddress
                )
            ) {
                // Fallback to `isApprovalForAll`
                if (
                    !address(token).safeStaticCallBool(
                        abi.encodeWithSelector(
                            IERC721.isApprovedForAll.selector,
                            orderParameters.offerer,
                            approvalAddress
                        ),
                        true
                    )
                ) {
                    // Not approved
                    errorsAndWarnings.addError(
                        ERC721Issue.NotApproved.parseInt()
                    );
                }
            }
        } else if (offerItem.itemType == ItemType.ERC1155) {
            IERC1155 token = IERC1155(offerItem.token);

            // Check for approval
            if (
                !address(token).safeStaticCallBool(
                    abi.encodeWithSelector(
                        IERC721.isApprovedForAll.selector,
                        orderParameters.offerer,
                        approvalAddress
                    ),
                    true
                )
            ) {
                errorsAndWarnings.addError(ERC1155Issue.NotApproved.parseInt());
            }

            // Get min required balance (max(startAmount, endAmount))
            uint256 minBalance = offerItem.startAmount < offerItem.endAmount
                ? offerItem.startAmount
                : offerItem.endAmount;

            // Check for sufficient balance
            if (
                !address(token).safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC1155.balanceOf.selector,
                        orderParameters.offerer,
                        offerItem.identifierOrCriteria
                    ),
                    minBalance
                )
            ) {
                // Insufficient balance
                errorsAndWarnings.addError(
                    ERC1155Issue.InsufficientBalance.parseInt()
                );
            }
        } else if (offerItem.itemType == ItemType.ERC20) {
            IERC20 token = IERC20(offerItem.token);

            // Get min required balance and approval (max(startAmount, endAmount))
            uint256 minBalanceAndAllowance = offerItem.startAmount <
                offerItem.endAmount
                ? offerItem.startAmount
                : offerItem.endAmount;

            // Check allowance
            if (
                !address(token).safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC20.allowance.selector,
                        orderParameters.offerer,
                        approvalAddress
                    ),
                    minBalanceAndAllowance
                )
            ) {
                errorsAndWarnings.addError(
                    ERC20Issue.InsufficientAllowance.parseInt()
                );
            }

            // Check balance
            if (
                !address(token).safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC20.balanceOf.selector,
                        orderParameters.offerer
                    ),
                    minBalanceAndAllowance
                )
            ) {
                errorsAndWarnings.addError(
                    ERC20Issue.InsufficientBalance.parseInt()
                );
            }
        } else if (offerItem.itemType == ItemType.NATIVE) {
            // Get min required balance (max(startAmount, endAmount))
            uint256 minBalance = offerItem.startAmount < offerItem.endAmount
                ? offerItem.startAmount
                : offerItem.endAmount;

            // Check for sufficient balance
            if (orderParameters.offerer.balance < minBalance) {
                errorsAndWarnings.addError(
                    NativeIssue.InsufficientBalance.parseInt()
                );
            }

            // Native items can not be pulled so warn
            errorsAndWarnings.addWarning(OfferIssue.NativeItem.parseInt());
        } else {
            // Unsupported offer item type
            errorsAndWarnings.addError(GenericIssue.InvalidItemType.parseInt());
        }
    }

    /**
     * @notice Validate all consideration items for an order
     * @param orderParameters The parameters for the order to validate
     * @return errorsAndWarnings  The errors and warnings
     */
    function validateConsiderationItems(OrderParameters memory orderParameters)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        if (orderParameters.consideration.length == 0) {
            errorsAndWarnings.addWarning(
                ConsiderationIssue.ZeroItems.parseInt()
            );
            return errorsAndWarnings;
        }

        for (uint256 i = 0; i < orderParameters.consideration.length; i++) {
            errorsAndWarnings.concat(
                validateConsiderationItem(orderParameters, i)
            );
        }
    }

    /**
     * @notice Validate a consideration item
     * @param orderParameters The parameters for the order to validate
     * @param considerationItemIndex The index of the consideration item to validate
     * @return errorsAndWarnings  The errors and warnings
     */
    function validateConsiderationItem(
        OrderParameters memory orderParameters,
        uint256 considerationItemIndex
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        errorsAndWarnings.concat(
            validateConsiderationItemParameters(
                orderParameters,
                considerationItemIndex
            )
        );
    }

    /**
     * @notice Validates the parameters of a consideration item including contract validation
     * @param orderParameters The parameters for the order to validate
     * @param considerationItemIndex The index of the consideration item to validate
     * @return errorsAndWarnings  The errors and warnings
     */
    function validateConsiderationItemParameters(
        OrderParameters memory orderParameters,
        uint256 considerationItemIndex
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        ConsiderationItem memory considerationItem = orderParameters
            .consideration[considerationItemIndex];

        // Check if startAmount and endAmount are zero
        if (
            considerationItem.startAmount == 0 &&
            considerationItem.endAmount == 0
        ) {
            errorsAndWarnings.addError(
                ConsiderationIssue.AmountZero.parseInt()
            );
        }

        // Check if the recipient is the null address
        if (considerationItem.recipient == address(0)) {
            errorsAndWarnings.addError(
                ConsiderationIssue.NullRecipient.parseInt()
            );
        }

        if (considerationItem.itemType == ItemType.ERC721) {
            // ERC721 type requires amounts to be 1
            if (
                considerationItem.startAmount != 1 ||
                considerationItem.endAmount != 1
            ) {
                errorsAndWarnings.addError(ERC721Issue.AmountNotOne.parseInt());
            }

            // Check EIP165 interface
            if (
                !checkInterface(
                    considerationItem.token,
                    type(IERC721).interfaceId
                )
            ) {
                errorsAndWarnings.addError(ERC721Issue.InvalidToken.parseInt());
                return errorsAndWarnings;
            }

            // Check that token exists
            if (
                !considerationItem.token.safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC721.ownerOf.selector,
                        considerationItem.identifierOrCriteria
                    ),
                    1
                )
            ) {
                // Token does not exist
                errorsAndWarnings.addError(
                    ERC721Issue.IdentifierDNE.parseInt()
                );
            }
        } else if (
            considerationItem.itemType == ItemType.ERC721_WITH_CRITERIA
        ) {
            // Check EIP165 interface
            if (
                !checkInterface(
                    considerationItem.token,
                    type(IERC721).interfaceId
                )
            ) {
                // Does not implement required interface
                errorsAndWarnings.addError(ERC721Issue.InvalidToken.parseInt());
            }
        } else if (
            considerationItem.itemType == ItemType.ERC1155 ||
            considerationItem.itemType == ItemType.ERC1155_WITH_CRITERIA
        ) {
            // Check EIP165 interface
            if (
                !checkInterface(
                    considerationItem.token,
                    type(IERC1155).interfaceId
                )
            ) {
                // Does not implement required interface
                errorsAndWarnings.addError(
                    ERC1155Issue.InvalidToken.parseInt()
                );
            }
        } else if (considerationItem.itemType == ItemType.ERC20) {
            // ERC20 must have `identifierOrCriteria` be zero
            if (considerationItem.identifierOrCriteria != 0) {
                errorsAndWarnings.addError(
                    ERC20Issue.IdentifierNonZero.parseInt()
                );
            }

            // Check that it is an ERC20 token. ERC20 will return a uint256
            if (
                !considerationItem.token.safeStaticCallUint256(
                    abi.encodeWithSelector(
                        IERC20.allowance.selector,
                        address(seaport),
                        address(seaport)
                    ),
                    0
                )
            ) {
                // Not an ERC20 token
                errorsAndWarnings.addError(ERC20Issue.InvalidToken.parseInt());
            }
        } else if (considerationItem.itemType == ItemType.NATIVE) {
            // NATIVE must have `token` be zero address
            if (considerationItem.token != address(0)) {
                errorsAndWarnings.addError(NativeIssue.TokenAddress.parseInt());
            }
            // NATIVE must have `identifierOrCriteria` be zero
            if (considerationItem.identifierOrCriteria != 0) {
                errorsAndWarnings.addError(
                    NativeIssue.IdentifierNonZero.parseInt()
                );
            }
        } else {
            // Unsupported consideration item type
            errorsAndWarnings.addError(GenericIssue.InvalidItemType.parseInt());
        }
    }

    /**
     * @notice Strict validation operates under tight assumptions. It validates protocol
     *    fee, royalty fee, private sale consideration, and overall order format.
     * @dev Only checks first fee recipient provided by RoyaltyEngine.
     *    Order of consideration items must be as follows:
     *    1. Primary consideration
     *    2. Protocol fee
     *    3. Royalty Fee
     *    4. Private sale consideration
     * @param orderParameters The parameters for the order to validate.
     * @param protocolFeeRecipient The protocol fee recipient. Set to null address for no protocol fee.
     * @param protocolFeeBips The protocol fee in BIPs.
     * @param checkRoyaltyFee Should check for royalty fee. If true, royalty fee must be present as
     *    according to royalty engine. If false, must not have royalty fee.
     * @return errorsAndWarnings The errors and warnings.
     */
    function validateStrictLogic(
        OrderParameters memory orderParameters,
        address protocolFeeRecipient,
        uint256 protocolFeeBips,
        bool checkRoyaltyFee
    ) public view returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // Check that order matches the required format (bid or ask)
        {
            bool canCheckFee = true;
            // Single offer item and at least one consideration
            if (
                orderParameters.offer.length != 1 ||
                orderParameters.consideration.length == 0
            ) {
                // Not bid or ask, can't check fees
                canCheckFee = false;
            } else if (
                // Can't have both items be fungible
                isPaymentToken(orderParameters.offer[0].itemType) &&
                isPaymentToken(orderParameters.consideration[0].itemType)
            ) {
                // Not bid or ask, can't check fees
                canCheckFee = false;
            } else if (
                // Can't have both items be non-fungible
                !isPaymentToken(orderParameters.offer[0].itemType) &&
                !isPaymentToken(orderParameters.consideration[0].itemType)
            ) {
                // Not bid or ask, can't check fees
                canCheckFee = false;
            }
            if (!canCheckFee) {
                // Does not match required format
                errorsAndWarnings.addError(
                    GenericIssue.InvalidOrderFormat.parseInt()
                );
                return errorsAndWarnings;
            }
        }

        // Validate secondary consideration items (fees)
        (
            uint256 tertiaryConsiderationIndex,
            ErrorsAndWarnings memory errorsAndWarningsLocal
        ) = _validateSecondaryConsiderationItems(
                orderParameters,
                protocolFeeRecipient,
                protocolFeeBips,
                checkRoyaltyFee
            );

        errorsAndWarnings.concat(errorsAndWarningsLocal);

        // Validate tertiary consideration items if not 0 (0 indicates error).
        // Only if no prior errors
        if (tertiaryConsiderationIndex != 0) {
            errorsAndWarnings.concat(
                _validateTertiaryConsiderationItems(
                    orderParameters,
                    tertiaryConsiderationIndex
                )
            );
        }
    }

    function _validateSecondaryConsiderationItems(
        OrderParameters memory orderParameters,
        address protocolFeeRecipient,
        uint256 protocolFeeBips,
        bool checkRoyaltyFee
    )
        internal
        view
        returns (
            uint256 tertiaryConsiderationIndex,
            ErrorsAndWarnings memory errorsAndWarnings
        )
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        // non-fungible item address
        address assetAddress;
        // non-fungible item identifier
        uint256 assetIdentifier;
        // fungible item start amount
        uint256 transactionAmountStart;
        // fungible item end amount
        uint256 transactionAmountEnd;

        // Consideration item to hold expected royalty fee info
        ConsiderationItem memory royaltyFeeConsideration;

        if (isPaymentToken(orderParameters.offer[0].itemType)) {
            // Offer is a bid. oOffer item is fungible and used for fees
            royaltyFeeConsideration.itemType = orderParameters
                .offer[0]
                .itemType;
            royaltyFeeConsideration.token = orderParameters.offer[0].token;
            transactionAmountStart = orderParameters.offer[0].startAmount;
            transactionAmountEnd = orderParameters.offer[0].endAmount;

            // Set non-fungible information for calculating royalties
            assetAddress = orderParameters.consideration[0].token;
            assetIdentifier = orderParameters
                .consideration[0]
                .identifierOrCriteria;
        } else {
            // Offer is a bid. Consideration item is fungible and used for fees
            royaltyFeeConsideration.itemType = orderParameters
                .consideration[0]
                .itemType;
            royaltyFeeConsideration.token = orderParameters
                .consideration[0]
                .token;
            transactionAmountStart = orderParameters
                .consideration[0]
                .startAmount;
            transactionAmountEnd = orderParameters.consideration[0].endAmount;

            // Set non-fungible information for calculating royalties
            assetAddress = orderParameters.offer[0].token;
            assetIdentifier = orderParameters.offer[0].identifierOrCriteria;
        }

        // Store flag if protocol fee is present
        bool protocolFeePresent = false;
        {
            // Calculate protocol fee start and end amounts
            uint256 protocolFeeStartAmount = (transactionAmountStart *
                protocolFeeBips) / 10000;
            uint256 protocolFeeEndAmount = (transactionAmountEnd *
                protocolFeeBips) / 10000;

            // Check if protocol fee check is desired. Skip if calculated amount is zero.
            if (
                protocolFeeRecipient != address(0) &&
                (protocolFeeStartAmount > 0 || protocolFeeEndAmount > 0)
            ) {
                // Ensure protocol fee is present
                if (orderParameters.consideration.length < 2) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.Missing.parseInt()
                    );
                    return (0, errorsAndWarnings);
                }
                protocolFeePresent = true;

                ConsiderationItem memory protocolFeeItem = orderParameters
                    .consideration[1];

                // Check item type
                if (
                    protocolFeeItem.itemType != royaltyFeeConsideration.itemType
                ) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.ItemType.parseInt()
                    );
                    return (0, errorsAndWarnings);
                }
                // Check token
                if (protocolFeeItem.token != royaltyFeeConsideration.token) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.Token.parseInt()
                    );
                }
                // Check start amount
                if (protocolFeeItem.startAmount < protocolFeeStartAmount) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.StartAmount.parseInt()
                    );
                }
                // Check end amount
                if (protocolFeeItem.endAmount < protocolFeeEndAmount) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.EndAmount.parseInt()
                    );
                }
                // Check recipient
                if (protocolFeeItem.recipient != protocolFeeRecipient) {
                    errorsAndWarnings.addError(
                        ProtocolFeeIssue.Recipient.parseInt()
                    );
                }
            }
        }

        // Check royalty fee
        {
            try
                royaltyEngine.getRoyaltyView(
                    assetAddress,
                    assetIdentifier,
                    transactionAmountStart
                )
            returns (
                address payable[] memory royaltyRecipients,
                uint256[] memory royaltyAmountsStart
            ) {
                if (royaltyRecipients.length != 0) {
                    royaltyFeeConsideration.recipient = royaltyRecipients[0];
                    royaltyFeeConsideration.startAmount = royaltyAmountsStart[
                        0
                    ];
                }
            } catch {
                // Royalty not found
            }

            if (royaltyFeeConsideration.recipient != address(0)) {
                try
                    royaltyEngine.getRoyaltyView(
                        assetAddress,
                        assetIdentifier,
                        transactionAmountEnd
                    )
                returns (
                    address payable[] memory,
                    uint256[] memory royaltyAmountsEnd
                ) {
                    royaltyFeeConsideration.endAmount = royaltyAmountsEnd[0];
                } catch {}
            }
        }

        bool royaltyFeePresent = false;

        if (
            royaltyFeeConsideration.recipient != address(0) &&
            checkRoyaltyFee &&
            (royaltyFeeConsideration.startAmount > 0 ||
                royaltyFeeConsideration.endAmount > 0)
        ) {
            uint16 royaltyConsiderationIndex = protocolFeePresent ? 2 : 1; // 2 if protocol fee, ow 1

            // Check that royalty consideration item exists
            if (
                orderParameters.consideration.length - 1 <
                royaltyConsiderationIndex
            ) {
                errorsAndWarnings.addError(RoyaltyFeeIssue.Missing.parseInt());
                return (0, errorsAndWarnings);
            }

            ConsiderationItem memory royaltyFeeItem = orderParameters
                .consideration[royaltyConsiderationIndex];
            royaltyFeePresent = true;

            if (royaltyFeeItem.itemType != royaltyFeeConsideration.itemType) {
                errorsAndWarnings.addError(RoyaltyFeeIssue.ItemType.parseInt());
                return (0, errorsAndWarnings);
            }
            if (royaltyFeeItem.token != royaltyFeeConsideration.token) {
                errorsAndWarnings.addError(RoyaltyFeeIssue.Token.parseInt());
            }
            if (
                royaltyFeeItem.startAmount < royaltyFeeConsideration.startAmount
            ) {
                errorsAndWarnings.addError(
                    RoyaltyFeeIssue.StartAmount.parseInt()
                );
            }
            if (royaltyFeeItem.endAmount < royaltyFeeConsideration.endAmount) {
                errorsAndWarnings.addError(
                    RoyaltyFeeIssue.EndAmount.parseInt()
                );
            }
            if (royaltyFeeItem.recipient != royaltyFeeConsideration.recipient) {
                errorsAndWarnings.addError(
                    RoyaltyFeeIssue.Recipient.parseInt()
                );
            }
        }

        // Check additional consideration items
        tertiaryConsiderationIndex =
            1 +
            (protocolFeePresent ? 1 : 0) +
            (royaltyFeePresent ? 1 : 0);
    }

    function _validateTertiaryConsiderationItems(
        OrderParameters memory orderParameters,
        uint256 considerationItemIndex
    ) internal pure returns (ErrorsAndWarnings memory errorsAndWarnings) {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        if (orderParameters.consideration.length <= considerationItemIndex) {
            // Not a private sale
            return errorsAndWarnings;
        }

        ConsiderationItem memory privateSaleConsideration = orderParameters
            .consideration[considerationItemIndex];

        if (isPaymentToken(orderParameters.offer[0].itemType)) {
            errorsAndWarnings.addError(
                ConsiderationIssue.ExtraItems.parseInt()
            );
            return errorsAndWarnings;
        }

        if (privateSaleConsideration.recipient == orderParameters.offerer) {
            errorsAndWarnings.addError(
                ConsiderationIssue.PrivateSaleToSelf.parseInt()
            );
            return errorsAndWarnings;
        }

        if (
            privateSaleConsideration.itemType !=
            orderParameters.offer[0].itemType ||
            privateSaleConsideration.token != orderParameters.offer[0].token ||
            orderParameters.offer[0].startAmount !=
            privateSaleConsideration.startAmount ||
            orderParameters.offer[0].endAmount !=
            privateSaleConsideration.endAmount ||
            orderParameters.offer[0].identifierOrCriteria !=
            privateSaleConsideration.identifierOrCriteria
        ) {
            // Invalid private sale, say extra consideration item
            errorsAndWarnings.addError(
                ConsiderationIssue.ExtraItems.parseInt()
            );
            return errorsAndWarnings;
        }

        if (orderParameters.consideration.length - 1 > considerationItemIndex) {
            // Extra consideration items
            errorsAndWarnings.addError(
                ConsiderationIssue.ExtraItems.parseInt()
            );
            return errorsAndWarnings;
        }
    }

    /**
     * @notice Validates the zone call for an order
     * @param orderParameters The parameters for the order to validate
     * @return errorsAndWarnings An ErrorsAndWarnings structs with results
     */
    function isValidZone(OrderParameters memory orderParameters)
        public
        view
        returns (ErrorsAndWarnings memory errorsAndWarnings)
    {
        errorsAndWarnings = ErrorsAndWarnings(new uint16[](0), new uint16[](0));

        if (address(orderParameters.zone).code.length == 0) {
            // Address is EOA. Valid order
            return errorsAndWarnings;
        }

        uint256 currentOffererCounter = seaport.getCounter(
            orderParameters.offerer
        );

        if (
            !orderParameters.zone.safeStaticCallBytes4(
                abi.encodeWithSelector(
                    ZoneInterface.isValidOrder.selector,
                    _deriveOrderHash(orderParameters, currentOffererCounter),
                    msg.sender, /* who should be caller? */
                    orderParameters.offerer,
                    orderParameters.zoneHash
                ),
                ZoneInterface.isValidOrder.selector
            )
        ) {
            errorsAndWarnings.addError(ZoneIssue.RejectedOrder.parseInt());
        }
    }

    /**
     * @notice Safely check that a contract implements an interface
     * @param token The token address to check
     * @param interfaceHash The interface hash to check
     */
    function checkInterface(address token, bytes4 interfaceHash)
        public
        view
        returns (bool)
    {
        return
            token.safeStaticCallBool(
                abi.encodeWithSelector(
                    IERC165.supportsInterface.selector,
                    interfaceHash
                ),
                true
            );
    }

    function isPaymentToken(ItemType itemType) public pure returns (bool) {
        return itemType == ItemType.NATIVE || itemType == ItemType.ERC20;
    }

    /*//////////////////////////////////////////////////////////////
                        Merkle Helpers
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Sorts an array of token ids by the keccak256 hash of the id. Required ordering of ids
     *    for other merkle operations.
     * @param includedTokens An array of included token ids.
     * @return sortedTokens The sorted `includedTokens` array.
     */
    function sortMerkleTokens(uint256[] memory includedTokens)
        public
        pure
        returns (uint256[] memory sortedTokens)
    {
        return _sortUint256ByHash(includedTokens);
    }

    /**
     * @notice Creates a merkle root for includedTokens.
     * @dev `includedTokens` must be sorting in strictly ascending order according to the keccak256 hash of the value.
     * @return merkleRoot The merkle root
     * @return errorsAndWarnings Errors and warnings from the operation
     */
    function getMerkleRoot(uint256[] memory includedTokens)
        public
        pure
        returns (bytes32 merkleRoot, ErrorsAndWarnings memory errorsAndWarnings)
    {
        (merkleRoot, errorsAndWarnings) = _getRoot(includedTokens);
    }

    /**
     * @notice Creates a merkle proof for the the targetIndex contained in includedTokens.
     * @dev `targetIndex` is referring to the index of an element in `includedTokens`.
     *    `includedTokens` must be sorting in ascending order according to the keccak256 hash of the value.
     * @return merkleProof The merkle proof
     * @return errorsAndWarnings Errors and warnings from the operation
     */
    function getMerkleProof(
        uint256[] memory includedTokens,
        uint256 targetIndex
    )
        public
        pure
        returns (
            bytes32[] memory merkleProof,
            ErrorsAndWarnings memory errorsAndWarnings
        )
    {
        (merkleProof, errorsAndWarnings) = _getProof(
            includedTokens,
            targetIndex
        );
    }

    function verifyMerkleProof(
        bytes32 merkleRoot,
        bytes32[] memory merkleProof,
        uint256 valueToProve
    ) public pure returns (bool) {
        bytes32 hashedValue = keccak256(abi.encode(valueToProve));

        return _verifyProof(merkleRoot, merkleProof, hashedValue);
    }
}
