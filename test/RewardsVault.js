const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");

describe("LynxExecutionLayerRewardsVault", function () {
  async function deployRewardsVaultFixture() {

    const [owner] = await ethers.getSigners();

    const RewardsVault = await ethers.getContractFactory("LynxExecutionLayerRewardsVault");
    const rewardsVault = await upgrades.deployProxy(RewardsVault,{initializer: "initialize"});
    await rewardsVault.waitForDeployment();
    const proxyAddress = await rewardsVault.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);

    console.log("RewardsVault deployed to \nProxyAddress:", await rewardsVault.getAddress(), 
      "\nImplementation address: ", implementationAddress,
      "\nProxyAdmin address: ", adminAddress);

    return { owner, rewardsVault };
  }

  describe("Deployment", function () {
    it("Should set the right managerFeeShare", async function () {
      const { rewardsVault } = await loadFixture(deployRewardsVaultFixture);

      expect(await rewardsVault.managerFeeShare()).to.equal(200);
    });

    it("Should grant the right role", async function () {
      const { rewardsVault, owner } = await loadFixture(
        deployRewardsVaultFixture
      );

      expect(await rewardsVault.hasRole(ethers.ZeroHash, owner.address)).to.be.true;
      expect(await rewardsVault.hasRole(ethers.keccak256(ethers.toUtf8Bytes("CONTROLLER_ROLE")), owner.address)).to.be.true;
      expect(await rewardsVault.hasRole(ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE")), owner.address)).to.be.true;
      expect(await rewardsVault.hasRole(ethers.keccak256(ethers.toUtf8Bytes("MANAGER_ROLE")), owner.address)).to.be.true;
    });
  });
});
