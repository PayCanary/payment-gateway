// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../permit2/interfaces/IPermit2.sol";

// @title PaymentGateway Contract
// @notice Functions for making checked transfers between accounts
interface IPaymentGateway {
    struct PaymentIntent {
        uint256 amountIn; // Amount to be paid
        uint256 receiptAmount; // Final amount after conversion or fee deduction
        uint256 deadline; // Payment deadline
        address tokenIn; // Token to be used in the transaction
        address receiptToken; // Token received post-transaction
        address exchangeAddress; // Router or exchange contract address
        address payable paymentReceiver; // Recipient's address
        Permit2SignatureTransferData signatureTransferData; // Signature data for permit2 functionality
        bytes receiverCallData; // Receiver-specific call data
        bytes exchangeCallData; // Call data for exchange
        uint8 exchangeType; // Exchange type (0: wrap/unwrap or as it is, 1: involves exchange)
    }

    struct Permit2SignatureTransferData {
        bool isPermit2;
        IPermit2.PermitTransferFrom permit;
        IPermit2.SignatureTransferDetails transferDetails;
        bytes signature;
    }

    event PaymentSuccess(
        address recipient,
        uint256 receiptAmount,
        address receiptToken
    );

    event FeeChanged(uint8);

    /// @dev Custom errors for validation and error handling
    error InvalidExchangeAddress();
    error InvalidPaymentAmount();
    error InvalidNativePaymentAmount();
    error PaymentExpired();
    error ServiceFeeNativePaymentFailed();
    error ReceiverNativePaymentFailed();
    error SweepExcessNativeFailed();
    error ExchangeCallFailed();
    error InvalidTokenAddress();
    error ReceiverCallFailed();
    error InvalidServiceFeePercent();
    error InvalidAddress();
}
