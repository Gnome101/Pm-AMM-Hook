// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import "forge-std/Script.sol";
import {MockERC20} from "../src/MockERC20.sol";
import {Hook} from "../src/Hook.sol";
import {DynamicPoolBasedMinter} from "../src/DynamicPoolBasedMinter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract DeployAndVerify is Script {
    function run() external {
        // Retrieve the deployer's private key from the environment.
        // Make sure to set the PRIVATE_KEY environment variable.
        Hook pm = Hook(0xa25A00a7FFA44B6D2b10a9DA0C4d9e5e883B0888);
        DynamicPoolBasedMinter dpMinter = DynamicPoolBasedMinter(0x5d693e107f7036E3c450de4032d9783fA1d850A0);
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_HEX");

        vm.startBroadcast(deployerPrivateKey);
        pm.setMinter(dpMinter);
        vm.stopBroadcast();
    }
}
