// scripts/deploy_and_verify.ts
import { ethers, run } from "hardhat";
import dotenv from "dotenv";
dotenv.config();

async function main(): Promise<void> {
  // Get the deployer account from the Hardhat environment.
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.target);

  // Deploy MockERC20
  const MockERC20Factory = await ethers.getContractFactory("MockERC20");
  // Pass any constructor arguments if required
  const mockERC20 =
    await MockERC20Factory.deploy(/* constructor arguments if any */);
  await mockERC20.deployed();
  console.log("MockERC20 deployed to:", mockERC20.target);

  // Deploy Hook
  const HookFactory = await ethers.getContractFactory("Hook");
  // Pass any constructor arguments if required
  const hook = await HookFactory.deploy(/* constructor arguments if any */);
  await hook.deployed();
  console.log("Hook deployed to:", hook.target);

  // Deploy DynamicPoolBasedMinter
  const DynamicPoolBasedMinterFactory = await ethers.getContractFactory(
    "DynamicPoolBasedMinter"
  );
  // In this example, we pass the addresses of MockERC20 and Hook to the constructor.
  // Modify the constructor arguments as required.
  const dynamicPoolBasedMinter = await DynamicPoolBasedMinterFactory.deploy(
    mockERC20.target,
    hook.target
    /*, other constructor arguments if any */
  );
  await dynamicPoolBasedMinter.deployed();
  console.log(
    "DynamicPoolBasedMinter deployed to:",
    dynamicPoolBasedMinter.target
  );

  // Optional: Wait for block confirmations to ensure the deployment is recognized by the network.
  console.log("Waiting for 5 seconds for block confirmations...");
  await new Promise((resolve) => setTimeout(resolve, 5000));

  // Verify contracts on Etherscan
  try {
    await run("verify:verify", {
      address: mockERC20.target,
      constructorArguments: [
        /* constructor arguments for MockERC20 */
      ],
    });
    console.log("MockERC20 verified successfully!");
  } catch (error) {
    console.error("Verification of MockERC20 failed:", error);
  }

  try {
    await run("verify:verify", {
      address: hook.target,
      constructorArguments: [
        /* constructor arguments for Hook */
      ],
    });
    console.log("Hook verified successfully!");
  } catch (error) {
    console.error("Verification of Hook failed:", error);
  }

  try {
    await run("verify:verify", {
      address: dynamicPoolBasedMinter.target,
      constructorArguments: [
        mockERC20.target,
        hook.target,
        /*, other constructor arguments for DynamicPoolBasedMinter if any */
      ],
    });
    console.log("DynamicPoolBasedMinter verified successfully!");
  } catch (error) {
    console.error("Verification of DynamicPoolBasedMinter failed:", error);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error: Error) => {
    console.error("Error during deployment:", error);
    process.exit(1);
  });
