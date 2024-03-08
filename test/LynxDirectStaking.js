const {
  time,
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { buildDomain, domainSeparator, signParams, hashStruct, exampleParams } = require("./helpers/signature");


describe("LynxDirectStaking", function () {
  // We define a fixture to reuse the same setup in every test.
  // We use loadFixture to run this setup once, snapshot that state,
  // and reset Hardhat Network to that snapshot in every test.
  async function deployDirectStakingFixture() {

    // Contracts are deployed using the first signer/account by default
    const [owner, another] = await ethers.getSigners();

    // deploy deposit contract
    const DepositContract = await ethers.getContractFactory("DepositContract");
    const depositContract = await DepositContract.deploy();
    await depositContract.waitForDeployment();

    let depositContractAddress = await depositContract.getAddress();
    console.log("DepositContract deployed to:", depositContractAddress);

    const DirestStaking = await ethers.getContractFactory("LynxDirectStaking");
    const directStaking = await upgrades.deployProxy(DirestStaking, [depositContractAddress], { initializer: "initialize" });
    await directStaking.waitForDeployment();

    const proxyAddress = await directStaking.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);

    console.log("\nDirestStaking deployed to \nProxyAddress:", proxyAddress,
      "\nImplementation address: ", implementationAddress,
      "\nProxyAdmin address: ", adminAddress);

    return { owner, another, directStaking, depositContractAddress };
  }

  async function deployAllFixture() {

    // Contracts are deployed using the first signer/account by default
    const [owner, another] = await ethers.getSigners();

    // deploy deposit contract
    const DepositContract = await ethers.getContractFactory("DepositContract");
    const depositContract = await DepositContract.deploy();
    await depositContract.waitForDeployment();

    let depositContractAddress = await depositContract.getAddress();
    console.log("DepositContract deployed to:", depositContractAddress);

    //doploy and initialize directstakeing contract with transparent proxy
    const DirectStaking = await ethers.getContractFactory("LynxDirectStaking");
    const directStaking = await upgrades.deployProxy(DirectStaking, [depositContractAddress], { initializer: "initialize" });
    await directStaking.waitForDeployment();

    // to print out the deployed details
    const proxyAddress = await directStaking.getAddress();
    const implementationAddress = await upgrades.erc1967.getImplementationAddress(proxyAddress);
    const adminAddress = await upgrades.erc1967.getAdminAddress(proxyAddress);

    console.log("\nDirestStaking deployed to \nProxyAddress:", proxyAddress,
      "\nImplementation address: ", implementationAddress,
      "\nProxyAdmin address: ", adminAddress);

    // depoloy the Rewards vault contract using openzepplin proxy plugin, transparent proxy
    const RewardsVault = await ethers.getContractFactory("LynxExecutionLayerRewardsVault");
    const rewardsVault = await upgrades.deployProxy(RewardsVault, { initializer: "initialize" });
    await rewardsVault.waitForDeployment();

    //Grant CONTROLLER_ROLE of vault contract, MUST BE DirectStaking contract's proxy address
    await rewardsVault.grantRole(ethers.keccak256(ethers.toUtf8Bytes("CONTROLLER_ROLE")), await directStaking.getAddress());
    // init the vault contract address of DirectStaking contract
    await directStaking.setRewardsVault(await rewardsVault.getAddress());
    

    return { owner, another, directStaking, depositContractAddress };
  }

  describe("Deployment2", function () {
    it("Should set the right deposit contract address", async function () {
      const { directStaking, depositContractAddress } = await loadFixture(deployDirectStakingFixture);

      expect(await directStaking.depositContract()).to.equal(depositContractAddress);
    });

    it("Should set the right DOMAIN_SEPARATOR", async function () {
      const { directStaking } = await loadFixture(deployDirectStakingFixture);
      const DOMAIN_SEPARATOR = await directStaking.DOMAIN_SEPARATOR();
      const domain = buildDomain("LynxDirectStaking", "1.0.0", 31337, await directStaking.getAddress());
      expect(DOMAIN_SEPARATOR).to.equal(domainSeparator(domain));
    });

    it("Should grant the right role", async function () {
      const { directStaking, owner } = await loadFixture(
        deployDirectStakingFixture
      );

      expect(await directStaking.hasRole(ethers.ZeroHash, owner.address)).to.be.true;
      expect(await directStaking.hasRole(ethers.keccak256(ethers.toUtf8Bytes("REGISTRY_ROLE")), owner.address)).to.be.true;
      expect(await directStaking.hasRole(ethers.keccak256(ethers.toUtf8Bytes("PAUSER_ROLE")), owner.address)).to.be.true;
    });
  });
  describe("Oracle", function () {
    it("Should sign the params", async function () {
      const { directStaking, owner } = await loadFixture(
        deployDirectStakingFixture
      );

      const domain = buildDomain("LynxDirectStaking", "1.0.0", 31337, directStaking.address);
      const params = exampleParams;
      const signature = await signParams(params, owner, domain);
      console.log("signature: ", signature);
    });

    it("Should set oracle", async function () {
      const { directStaking, owner, another } = await loadFixture(
        deployDirectStakingFixture
      );
      console.log("owner: ", owner.address, "another: ", another.address);
      await directStaking.connect(owner).setOracle(another.address);

      expect(await directStaking.oracle()).to.equal(another.address);
    });

    it("Should validate the oracle signature", async function () {
      const { directStaking, owner, another } = await loadFixture(
        deployDirectStakingFixture
      );

      await directStaking.connect(owner).setOracle(owner.getAddress());

      const domain = buildDomain("LynxDirectStaking", "1.0.0", 31337, await directStaking.getAddress());
      const params = exampleParams;
      const hash = hashStruct(params);
      console.log("hash: ", hash);
      const signature = await signParams(params, owner, domain);
      expect(await directStaking.validateOracleAuthorization(
        params.extraData,
        params.claimaddr,
        params.withdrawaddr,
        params.pubkeys,
        params.signatures,
        signature
      )).to.be.true;
    });
  });

  describe("Stake", function () {
    it("Should stake", async function () {
      const { directStaking, owner, another } = await loadFixture(
        deployAllFixture
      );

      await directStaking.connect(owner).setOracle(owner.getAddress());

      const domain = buildDomain("LynxDirectStaking", "1.0.0", 31337, await directStaking.getAddress());
      const params = exampleParams;
      const signature = await signParams(params, owner, domain);

      expect(await directStaking.connect(owner).stake(
        params.claimaddr,
        params.withdrawaddr,
        params.pubkeys,
        params.signatures,
        signature,
        params.extraData,
        0,
        { value: 64000000000000000000n }
      )).to.emit(directStaking, "Staked").withArgs(owner.address, 64000000000000000000n);
    });
  });
});
