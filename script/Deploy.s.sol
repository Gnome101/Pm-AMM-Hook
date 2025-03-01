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
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_HEX");
        // Retrieve the deployer's private key from the environment.
        // Make sure to set the PRIVATE_KEY environment variable.
        vm.startBroadcast(deployerPrivateKey);
        MockERC20 mockERC20 = new MockERC20("Real Cash Money", "USDC");
        console.log("MockERC20 deployed to:", address(mockERC20));
        vm.stopBroadcast();

        IPoolManager pm = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG);
        (, bytes32 salt) = HookMiner.find(
            0x4e59b44847b379578588920cA78FbF26c0B4956C, flags, type(Hook).creationCode, abi.encode(pm, mockERC20)
        );
        // Begin broadcasting transactions using the deployer key.
        vm.startBroadcast(deployerPrivateKey);

        console.log(address(this));
        // Deploy MockERC20. Add any constructor arguments if needed.

        // Deploy Hook. Add any constructor arguments if needed.
        Hook hook = new Hook{salt: salt}(pm, mockERC20);

        console.log("Hook deployed to:", address(hook));

        // Deploy DynamicPoolBasedMinter.
        // In this example, we assume its constructor requires the addresses of MockERC20 and Hook.
        DynamicPoolBasedMinter dpMinter = new DynamicPoolBasedMinter(address(hook), mockERC20);
        /*, other constructor args if any */
        console.log("DynamicPoolBasedMinter deployed to:", address(dpMinter));
        // hook.setMinter(dpMinter);

        // End broadcasting transactions.
        vm.stopBroadcast();
    }
}
