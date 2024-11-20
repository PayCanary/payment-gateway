// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "../token/ERC20/IERC20.sol";

// @title Represents wrapped (e.g. wETH) currencies
interface IWrappedNativeCurrency is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}
