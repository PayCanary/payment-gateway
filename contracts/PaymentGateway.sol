// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../contracts/utils/Context.sol";
import "../contracts/utils/ReentrancyGuard.sol";
import "../contracts/security/Pausable.sol";
import "../contracts/access/Ownable.sol";
import "../contracts/token/ERC20/utils/SafeERC20.sol";
import "../contracts/token/ERC20/IERC20.sol";
import "../contracts/interfaces/IPaymentGateway.sol";
import "../contracts/interfaces/IWrappedNativeCurrency.sol";
import "../contracts/permit2/interfaces/IPermit2.sol";

// @title PaymentGateway Contract
// @notice A non-custodial, decentralized payment gateway supporting ERC20 and native token transactions with on-chain swaps.
contract PaymentGateway is
    Context,
    Ownable,
    Pausable,
    ReentrancyGuard,
    IPaymentGateway
{
    using SafeERC20 for IERC20;
    using SafeERC20 for IWrappedNativeCurrency;

    /// @notice Address to receive service fees
    address private serviceFeeReceiver;
    /// @notice Service fee percentage, represented in basis points (0.8% = 80)
    uint8 public serviceFeePercent;

    /// @notice Mapping to store special fees for specific addresses, capped at 1% (100 basis points)
    mapping(address => uint8) private specialFees;

    /// @dev Address representing the native currency (e.g., ETH)
    address public constant NATIVE_CURRENCY = address(0);

    /// @dev Wrapped version of the native currency (e.g., WETH)
    IWrappedNativeCurrency private immutable wrappedNativeCurrency;
    address public immutable WRAPPED_NATIVE_CURRENCY;

    /// @notice Permit2 contract
    IPermit2 public immutable permit2;

    /// @notice Contract constructor to initialize essential addresses
    /// @param _PERMIT2 Address of the Permit2 contract
    /// @param _wrappedNativeCurrency Address of the wrapped native currency contract
    /// @param _serviceFeeReceiver Address to receive service fees
    /// @param _serviceFeePercent Service fee percentage in basis points (e.g., 80 for 0.8%)
    constructor(
        address _PERMIT2,
        address _wrappedNativeCurrency,
        address _serviceFeeReceiver,
        uint8 _serviceFeePercent
    ) Ownable(_msgSender()) {
        // Check for non-zero addresses
        if (_PERMIT2 == address(0)) {
            revert InvalidAddress();
        }
        if (_wrappedNativeCurrency == address(0)) {
            revert InvalidAddress();
        }
        if (_serviceFeeReceiver == address(0)) {
            revert InvalidAddress();
        }

        // Check that the service fee is within a reasonable range
        // fees are capped at 1% max which is 100 points out of 10000 basis points
        if (_serviceFeePercent > 100) {
            revert InvalidServiceFeePercent();
        }

        WRAPPED_NATIVE_CURRENCY = _wrappedNativeCurrency;
        permit2 = IPermit2(_PERMIT2);
        wrappedNativeCurrency = IWrappedNativeCurrency(WRAPPED_NATIVE_CURRENCY);

        serviceFeeReceiver = _serviceFeeReceiver;
        serviceFeePercent = _serviceFeePercent;
    }

    /// @dev Function to receive native currency directly
    receive() external payable {}

    /// @dev Internal function to handle token exchange via external call
    /// @param tokenIn Address of the input token
    /// @param exchangeAddress Address of the exchange/router
    /// @param amountIn Amount of the input token to exchange
    /// @param exchangeCallData Call data for the exchange function
    /// @return excessTokens Amount of excess tokens after the swap
    function _exchange(
        address tokenIn,
        address exchangeAddress,
        uint256 amountIn,
        bytes calldata exchangeCallData
    ) internal returns (uint256 excessTokens) {
        // Validate `exchangeAddress`
        if (exchangeAddress == address(0)) {
            revert InvalidExchangeAddress();
        }

        uint256 contractBalanceBeforeSwap = IERC20(tokenIn).balanceOf(
            address(this)
        );

        IERC20(tokenIn).safeIncreaseAllowance(exchangeAddress, amountIn);

        (bool success, ) = exchangeAddress.call(exchangeCallData);
        if (!success) {
            revert ExchangeCallFailed();
        }

        uint256 contractBalanceAfterSwap = IERC20(tokenIn).balanceOf(
            address(this)
        );
        uint256 actualSpentAmount = contractBalanceBeforeSwap -
            contractBalanceAfterSwap;
        excessTokens = amountIn - actualSpentAmount;
    }

    /// @notice Public function to process a payment intent
    /// @param payment Struct containing payment intent data
    function pay(
        PaymentIntent calldata payment
    ) external payable nonReentrant whenNotPaused {
        // handle the actual payment logic
        _pay(payment);
    }

    /**
     * @notice Validates the payment details such as amount and deadline.
     * @param payment The payment intent structure containing all details.
     */
    function _validatePayment(PaymentIntent calldata payment) internal view {
        // Validate payment amount
        if (payment.amountIn == 0) {
            revert InvalidPaymentAmount();
        }

        if (
            payment.tokenIn == NATIVE_CURRENCY && payment.amountIn != msg.value
        ) {
            revert InvalidNativePaymentAmount();
        }

        // Check if the payment is within the valid deadline
        if (payment.deadline < block.timestamp) {
            revert PaymentExpired();
        }
    }

    /// @notice Main function to process a payment intent
    /// @param payment Struct containing payment intent data
    function _pay(PaymentIntent calldata payment) internal {
        _validatePayment(payment);

        uint256 totalReceivedAmount = payment.receiptAmount;
        address _tokenIn = payment.tokenIn;
        address receiptToken = payment.receiptToken;

        // Handle native currency wrapping if necessary
        if (_tokenIn == NATIVE_CURRENCY && receiptToken != NATIVE_CURRENCY) {
            wrappedNativeCurrency.deposit{value: payment.amountIn}();
            _tokenIn = WRAPPED_NATIVE_CURRENCY;
        } else if (payment.signatureTransferData.isPermit2) {
            // Handle transfers using Permit2
            permit2.permitTransferFrom(
                payment.signatureTransferData.permit,
                payment.signatureTransferData.transferDetails,
                _msgSender(),
                payment.signatureTransferData.signature
            );
        } else {
            IERC20(_tokenIn).safeTransferFrom(
                _msgSender(),
                address(this),
                payment.amountIn
            );
        }

        // Handle token exchange if needed
        if (payment.exchangeType == 1) {
            uint256 excessTokens = _exchange(
                _tokenIn,
                payment.exchangeAddress,
                payment.amountIn,
                payment.exchangeCallData
            );

            if (excessTokens > 0) {
                if (payment.tokenIn == NATIVE_CURRENCY) {
                    wrappedNativeCurrency.withdraw(excessTokens);
                    _sweepExcessNative(excessTokens);
                } else {
                    _sweepExcessTokens(_tokenIn, excessTokens);
                }
            }
        }

        // Handle payment in native currency if necessary
        if (receiptToken == NATIVE_CURRENCY) {
            // Check _tokenIn
            if (_tokenIn != NATIVE_CURRENCY) {
                // Unwrap the wrapped native currency to native currency
                wrappedNativeCurrency.withdraw(totalReceivedAmount);
            }

            // Perform the payment to the receiver in native currency
            _performPaymentNative(
                payment.paymentReceiver,
                totalReceivedAmount,
                payment.receiverCallData
            );
        } else {
            // Handle ERC20 payment
            _performPayment(
                receiptToken,
                payment.paymentReceiver,
                totalReceivedAmount,
                payment.receiverCallData
            );
        }

        emit PaymentSuccess(
            payment.paymentReceiver,
            totalReceivedAmount,
            receiptToken
        );
    }

    /// @dev Internal function to handle native currency service fee payment
    /// @param feeAmount Amount of the native currency to pay as the service fee
    function _payServiceFeeNative(uint256 feeAmount) internal {
        (bool success, ) = serviceFeeReceiver.call{value: feeAmount}(
            new bytes(0)
        );
        if (!success) {
            revert ServiceFeeNativePaymentFailed();
        }
    }

    /// @dev Internal function to handle ERC20 service fee payment
    /// @param receiptToken Address of the ERC20 token
    /// @param feeAmount Amount of the ERC20 token to pay as the service fee
    function _payServiceFeeTokens(
        address receiptToken,
        uint256 feeAmount
    ) internal {
        IERC20(receiptToken).safeTransfer(serviceFeeReceiver, feeAmount);
    }

    /// @dev Internal function to pay a receiver with native currency
    /// @param paymentReceiver Address of the receiver
    /// @param receiptAmountAfterFees Amount to send after deducting fees
    /// @param receiverCallData Additional data to send to the payment receiver
    function _payReceiverNative(
        address paymentReceiver,
        uint256 receiptAmountAfterFees,
        bytes calldata receiverCallData
    ) internal {
        (bool success, ) = paymentReceiver.call{value: receiptAmountAfterFees}(
            receiverCallData
        );
        if (!success) {
            revert ReceiverNativePaymentFailed();
        }
    }

    /// @dev Internal function to pay a receiver with ERC20 tokens
    /// @param receiptToken Address of the ERC20 token
    /// @param paymentReceiver Address of the receiver
    /// @param receiptAmountAfterFees Amount to send after deducting fees
    function _payReceiverTokens(
        address receiptToken,
        address paymentReceiver,
        uint256 receiptAmountAfterFees,
        bytes calldata receiverCallData
    ) internal {
        // Transfer ERC20 tokens to the receiver
        IERC20(receiptToken).safeTransfer(
            paymentReceiver,
            receiptAmountAfterFees
        );

        // If there is additional data to pass, call the receiver contract with the data
        if (receiverCallData.length > 0) {
            (bool success, ) = paymentReceiver.call(receiverCallData);
            if (!success) {
                revert ReceiverCallFailed();
            }
        }
    }

    /// @dev Internal function to sweep excess native currency to the caller
    /// @param excessAmount Amount of native currency to sweep
    function _sweepExcessNative(uint256 excessAmount) internal {
        (bool success, ) = _msgSender().call{value: excessAmount}(new bytes(0));
        if (!success) {
            revert SweepExcessNativeFailed();
        }
    }

    /// @dev Internal function to sweep excess ERC20 tokens to the caller
    /// @param tokenAddress Address of the ERC20 token
    /// @param excessAmount Amount of the ERC20 token to sweep
    function _sweepExcessTokens(
        address tokenAddress,
        uint256 excessAmount
    ) internal {
        IERC20(tokenAddress).safeTransfer(_msgSender(), excessAmount);
    }

    /// @dev Internal function to perform a payment in native currency
    /// @param paymentReceiver Address of the receiver
    /// @param totalReceivedAmount Total amount received to send
    function _performPaymentNative(
        address paymentReceiver,
        uint256 totalReceivedAmount,
        bytes calldata receiverCallData
    ) internal {
        uint8 applicableFeePercent = getServiceFee(paymentReceiver);
        uint256 feeAmount = (totalReceivedAmount * applicableFeePercent) /
            10000;
        uint256 receiptAmountAfterFees = totalReceivedAmount - feeAmount;

        _payServiceFeeNative(feeAmount);
        _payReceiverNative(
            paymentReceiver,
            receiptAmountAfterFees,
            receiverCallData
        );
    }

    /// @dev Internal function to perform a payment in ERC20 tokens
    /// @param receiptToken Address of the ERC20 token
    /// @param paymentReceiver Address of the receiver
    /// @param totalReceivedAmount Total amount received to send
    function _performPayment(
        address receiptToken,
        address paymentReceiver,
        uint256 totalReceivedAmount,
        bytes calldata receiverCallData
    ) internal {
        uint8 applicableFeePercent = getServiceFee(paymentReceiver);
        uint256 feeAmount = (totalReceivedAmount * applicableFeePercent) /
            10000;
        uint256 receiptAmountAfterFees = totalReceivedAmount - feeAmount;

        _payServiceFeeTokens(receiptToken, feeAmount);
        _payReceiverTokens(
            receiptToken,
            paymentReceiver,
            receiptAmountAfterFees,
            receiverCallData
        );
    }

    /// @notice Sets the standard service fee percentage (capped at 1%)
    /// @param _serviceFeePercent The new service fee percentage in basis points (e.g., 80 for 0.8%)
    function setServiceFeePercent(uint8 _serviceFeePercent) external onlyOwner {
        // Check that the new service fee is within the allowed cap (1%)
        if (_serviceFeePercent > 100) {
            revert InvalidServiceFeePercent();
        }
        serviceFeePercent = _serviceFeePercent;
        emit FeeChanged(_serviceFeePercent);
    }

    /// @notice Sets a special service fee for a specific address (capped at 1%)
    /// @param account The address for which the special fee is being set
    /// @param _specialFeePercent The special service fee in basis points (e.g., 50 for 0.5%)
    function setSpecialFee(
        address account,
        uint8 _specialFeePercent
    ) external onlyOwner {
        // Check for a valid address
        if (account == address(0)) {
            revert InvalidAddress();
        }

        // Check that the special fee is within the allowed cap (1%)
        if (_specialFeePercent > 100) {
            revert InvalidServiceFeePercent();
        }

        // Set the special fee for the given address
        specialFees[account] = _specialFeePercent;
    }

    /// @notice Gets the applicable service fee for an address
    /// @param account The address to check for a special fee
    /// @return The service fee percentage in basis points
    function getServiceFee(address account) public view returns (uint8) {
        // Return the special fee if set; otherwise, return the standard service fee
        return
            specialFees[account] > 0 ? specialFees[account] : serviceFeePercent;
    }

    // owner function to pause the contract
    function pause() external onlyOwner {
        _pause();
    }

    // owner function to unpause the contract
    function unpause() external onlyOwner {
        _unpause();
    }
}
