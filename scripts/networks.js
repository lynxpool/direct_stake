function getDepositContractAddress(chainId) {
  console.log("chainId: ", chainId);
  if (chainId === 1) {
    return "0x00000000219ab540356cbb839cbe05303d7705fa";
  } else if (chainId === 17000) {
    return "0x4242424242424242424242424242424242424242";
  } else if (chainId === 31337) {
    return "0x4242424242424242424242424242424242424242";
  }else{
    throw new Error("Unsupported chainId");
  }
}

module.exports = {
  getDepositContractAddress
};