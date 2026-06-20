const { ethers } = require("hardhat");

async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying with wallet:", deployer.address);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("Balance:", ethers.formatEther(balance), "MATIC");

  // ── Already deployed ────────────────────────────────────────────────────
  const tokenAddr   = "0xbd11376e2Eaa66B6CA11d249181C471b890803A1";
  const factoryAddr = "0x9F85d6ed462219d5a9A03e0254C83d0a422cf490";
  console.log("\n✅ KametiToken (already deployed):   ", tokenAddr);
  console.log("✅ KametiFactory (already deployed): ", factoryAddr);

  // ── Deploy KametiYield ──────────────────────────────────────────────────
  const USDC_ADDRESS  = "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582";
  const AAVE_POOL     = "0xcC6114B983E4Ed2737E9BD3961c9924e6216c704";
  const AUSDC_ADDRESS = "0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582";

  console.log("\nDeploying KametiYield...");
  const KametiYield = await ethers.getContractFactory("KametiYield");
  const yieldContract = await KametiYield.deploy(
    USDC_ADDRESS,
    AAVE_POOL,
    AUSDC_ADDRESS
  );
  await yieldContract.waitForDeployment();
  const yieldAddr = await yieldContract.getAddress();
  console.log("✅ KametiYield:", yieldAddr);

  // ── Final Summary ───────────────────────────────────────────────────────
  console.log("\n════════════════════════════════════════");
  console.log("      ALL CONTRACTS DEPLOYED");
  console.log("════════════════════════════════════════");
  console.log("KametiToken:   ", tokenAddr);
  console.log("KametiFactory: ", factoryAddr);
  console.log("KametiYield:   ", yieldAddr);
  console.log("════════════════════════════════════════");
  console.log("Copy all 3 addresses into your frontend!");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});