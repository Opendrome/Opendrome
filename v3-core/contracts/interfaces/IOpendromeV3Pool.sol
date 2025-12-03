// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import './pool/IOpendromeV3PoolImmutables.sol';
import './pool/IOpendromeV3PoolState.sol';
import './pool/IOpendromeV3PoolDerivedState.sol';
import './pool/IOpendromeV3PoolActions.sol';
import './pool/IOpendromeV3PoolOwnerActions.sol';
import './pool/IOpendromeV3PoolEvents.sol';

/// @title The interface for a Opendrome V3 Pool
/// @notice A Opendrome pool facilitates swapping and automated market making between any two assets that strictly conform
/// to the ERC20 specification
/// @dev The pool interface is broken up into many smaller pieces
interface IOpendromeV3Pool is
    IOpendromeV3PoolImmutables,
    IOpendromeV3PoolState,
    IOpendromeV3PoolDerivedState,
    IOpendromeV3PoolActions,
    IOpendromeV3PoolOwnerActions,
    IOpendromeV3PoolEvents
{

}
