// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");
const { ethers, upgrades } = require("hardhat");
const { getDepositContractAddress } = require("./networks");
const { recordTxDetails } = require("./report");

async function main() {

  const depositContractAddress = getDepositContractAddress(hre.network.config.chainId);

  const [owner] = await ethers.getSigners();

  const RewardsVault = await ethers.getContractFactory("LynxExecutionLayerRewardsVault");
  const rewardsVault = await upgrades.deployProxy(RewardsVault, { initializer: "initialize" });
  await rewardsVault.waitForDeployment();
  await recordTxDetails(rewardsVault, "LynxExecutionLayerRewardsVault");

  const proxyAddress = await rewardsVault.getAddress();
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
  const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);

  console.log(
    "RewardsVault deployed to \nProxyAddress:", await rewardsVault.getAddress(),
    "\nImplementation address: ", implementationAddress,
    "\nProxyAdmin address: ", adminAddress);

  const DirestStaking = await ethers.getContractFactory("LynxDirectStaking");
  const directStaking = await upgrades.deployProxy(DirestStaking, [depositContractAddress], { initializer: "initialize" });
  await directStaking.waitForDeployment();
  await recordTxDetails(directStaking, "LynxDirectStaking");

  await directStaking.setRewardsVault(await rewardsVault.getAddress());
  await rewardsVault.grantRole(ethers.keccak256(ethers.toUtf8Bytes("CONTROLLER_ROLE")), await directStaking.getAddress());

}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
