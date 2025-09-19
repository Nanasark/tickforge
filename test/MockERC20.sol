//SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import { ERC20Mock } from "openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";

contract MockERC20 is ERC20Mock {
    uint8 private _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
        _mint(msg.sender, 100_000_000e18);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }
}
