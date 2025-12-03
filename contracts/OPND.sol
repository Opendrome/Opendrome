// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract OPND is ERC20 {
    // Max supply = 1 000 000 000 OPND (10^9 * 10^18 pour les décimales)
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Opendrome", "OPND") {
        // On mint toute la supply une seule fois au déploiement
        _mint(msg.sender, MAX_SUPPLY);
    }
}

