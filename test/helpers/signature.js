const ethers = require("ethers");
const ethSigUtil =  require("@metamask/eth-sig-util");


const CONTRACT_NAME = "LynxDirectStaking";
const CONTRACT_VERSION = "1.0.0";

const exampleParams = {
  extraData: 0,
  claimaddr: "0xe22Ad784B77673b28d6E1a57Fd66Bbae282CF9ce",
  withdrawaddr: "0xe22Ad784B77673b28d6E1a57Fd66Bbae282CF9ce",
  pubkeys: ["0x97fcc13e1b381e18850c506147b4ad107fae44521f6e71a35f4d9ae1ff15a22e4baa5b0ebc2a2b490f43e972a1eb9803", "0x82d7ebbbbab73b9e6abfc1a8af47ba6e9848c6cc32c2f6e0a81e29f1b09a4539c2e7f6381fde25a9428219d8a8d47d08"],
  signatures: ["0xa5fc67f1a9f2c512c021fc37fdb8fa85e734dbfa5fab393a2aebf03ec617cc2a3b00587846584781beb0daea56a581be18bd5d4298bebf1b71d8c0a6bc0940477b5db399ccb4392ebfd984255bb104449f92b6d38846f49a70dd055bb5340f5b", "0x8103c1836b3ce836a2868cd6ac4c31ef541442ccfd0252c6c9998bea4aa583a24921b6aabe6a1325dcf0c2a1a4635c840628f163263a7a709142b1239cb83f1e4986ad89349c2b901fd901fa86bcef8287e12d3d62db9ab5b068767903224887"],
};


const eip712ParamsStruct = {
  name: "StakeParams",
  fields: [
    { name: "extraData", type: "uint256" },
    { name: "claimaddr", type: "address" },
    { name: "withdrawaddr", type: "address" },
    { name: "pubkeys", type: "bytes[]" },
    { name: "signatures", type: "bytes[]" },
  ]
};


function buildDomain(name, version, chainId, verifyingContract) {
  return {
    name: name,
    version: version,
    chainId: chainId,
    verifyingContract: verifyingContract
  };
}

function domainSeparator(domain) {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["bytes32", "bytes32", "bytes32", "uint256", "address"],
      [
        ethers.id(
          "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        ),
        ethers.id(domain.name),
        ethers.id(domain.version),
        domain.chainId,
        domain.verifyingContract,
      ]
    )
  );
}

function hashStruct(data) {
  return ethers.TypedDataEncoder.hashStruct(
    eip712ParamsStruct.name,
    { [eip712ParamsStruct.name]: eip712ParamsStruct.fields },
    data
  )
}

async function signParams(params, signer, domain) {
  // signature = await signer._signTypedData(domain, types, value);
  const signature = await signer.signTypedData(
    domain,
    { [eip712ParamsStruct.name]: eip712ParamsStruct.fields },
    params
  );

  return signature;
}


module.exports = { buildDomain, domainSeparator, signParams, hashStruct, exampleParams };