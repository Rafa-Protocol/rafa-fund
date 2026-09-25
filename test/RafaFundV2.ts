import { expect } from "chai";
import { network } from "hardhat";

const { ethers } = await network.create();

const DAY = 24 * 60 * 60;
const WAD = 10n ** 18n;

async function latestTimestamp() {
  const block = await ethers.provider.getBlock("latest");
  if (block === null) throw new Error("Missing latest block");
  return block.timestamp;
}

async function deploySystem(overrides: Record<string, unknown> = {}) {
  const [owner, trader, guardian, feeRecipient, investor, other] = await ethers.getSigners();

  const usdc = await ethers.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
  const weth = await ethers.deployContract("MockERC20", ["Wrapped Ether", "WETH", 18]);
  const unsupported = await ethers.deployContract("MockERC20", ["Unsupported", "NOPE", 18]);
  const router = await ethers.deployContract("MockAerodromeRouter");
  const adapter = await ethers.deployContract("AerodromeAdapter", [
    owner.address,
    await usdc.getAddress(),
    await router.getAddress(),
  ]);
  const registry = await ethers.deployContract("RafaAssetRegistry", [owner.address, await usdc.getAddress()]);
  const timestamp = await latestTimestamp();
  const wethOracle = await ethers.deployContract("MockPriceOracle", [2_000n * WAD, timestamp]);

  await adapter.configureRoute(await weth.getAddress(), false, ethers.ZeroAddress);
  await registry.configureAsset(
    await weth.getAddress(),
    18,
    await wethOracle.getAddress(),
    DAY,
    DAY,
    7_000,
    await adapter.getAddress(),
    ethers.encodeBytes32String("CRYPTO"),
    ethers.encodeBytes32String("WETH"),
  );

  const params = {
    name: "RAFA Balanced Fund",
    symbol: "rBAL",
    metadataURI: "ipfs://rafa-balanced",
    accountingAsset: await usdc.getAddress(),
    assetRegistry: await registry.getAddress(),
    admin: owner.address,
    trader: trader.address,
    guardian: guardian.address,
    feeRecipient: feeRecipient.address,
    performanceFeeBps: 2_000,
    maxTradeSlippageBps: 500,
    maxTradeValueBps: 5_000,
    adminTransferDelay: 0,
    depositCap: ethers.parseUnits("1000000", 6),
    ...overrides,
  };

  const fund = await ethers.deployContract("RafaFundV2", [params]);
  await fund.addAsset(await weth.getAddress(), 7_000);

  await usdc.mint(investor.address, ethers.parseUnits("1000000", 6));
  await usdc.connect(investor).approve(await fund.getAddress(), ethers.MaxUint256);

  await usdc.mint(await router.getAddress(), ethers.parseUnits("10000000", 6));
  await weth.mint(await router.getAddress(), ethers.parseUnits("10000", 18));
  await router.setRate(
    await usdc.getAddress(),
    await weth.getAddress(),
    false,
    ethers.parseUnits("1", 18),
    ethers.parseUnits("2000", 6),
  );
  await router.setRate(
    await weth.getAddress(),
    await usdc.getAddress(),
    false,
    ethers.parseUnits("2000", 6),
    ethers.parseUnits("1", 18),
  );

  return {
    owner,
    trader,
    guardian,
    feeRecipient,
    investor,
    other,
    usdc,
    weth,
    unsupported,
    router,
    adapter,
    registry,
    wethOracle,
    fund,
  };
}

describe("RafaFundV2", function () {
  it("admits only protocol-listed assets and keeps fund owners out of allowlist administration", async function () {
    const { owner, trader, other, fund, usdc, unsupported, router, adapter, registry, wethOracle } =
      await deploySystem();

    await expect(fund.connect(trader).addAsset(await unsupported.getAddress(), 1_000)).to.be.revertedWithCustomError(
      fund,
      "AccessControlUnauthorizedAccount",
    );
    await expect(fund.connect(owner).addAsset(await unsupported.getAddress(), 1_000)).to.be.revertedWithCustomError(
      fund,
      "AssetPolicyNotConfigured",
    );

    const otherAccountingAsset = await ethers.deployContract("MockERC20", ["Other USD", "oUSD", 6]);
    const mismatchedAdapter = await ethers.deployContract("AerodromeAdapter", [
      owner.address,
      await otherAccountingAsset.getAddress(),
      await router.getAddress(),
    ]);
    await expect(
      registry.configureAsset(
        await unsupported.getAddress(),
        18,
        await wethOracle.getAddress(),
        DAY,
        DAY,
        1_000,
        await mismatchedAdapter.getAddress(),
        ethers.encodeBytes32String("EQUITY"),
        ethers.encodeBytes32String("ISSUER"),
      ),
    ).to.be.revertedWithCustomError(registry, "InvalidAddress");
    expect(await registry.accountingAsset()).to.equal(await usdc.getAddress());

    expect(await ethers.provider.getCode(other.address)).to.equal("0x");
    await registry.configureAsset(
      other.address,
      18,
      await wethOracle.getAddress(),
      DAY,
      DAY,
      1_000,
      await adapter.getAddress(),
      ethers.encodeBytes32String("EQUITY"),
      ethers.encodeBytes32String("COINBASE"),
    );

    await expect(fund.connect(owner).addAsset(other.address, 1_000))
      .to.emit(fund, "AssetAdded")
      .withArgs(other.address, await wethOracle.getAddress(), await adapter.getAddress(), 1_000);
  });
  it("lets the protocol halt buys while preserving an orderly sell-only unwind", async function () {
    const { trader, investor, other, fund, usdc, weth, registry } = await deploySystem();
    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);

    await expect(
      registry.connect(other).setAssetStatus(await weth.getAddress(), false, false, true),
    ).to.be.revertedWithCustomError(registry, "OwnableUnauthorizedAccount");

    await fund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("2000", 6),
      ethers.parseUnits("0.99", 18),
      (await latestTimestamp()) + 600,
    );

    await registry.setAssetStatus(await weth.getAddress(), false, false, true);
    await expect(
      fund.connect(trader).trade(
        await usdc.getAddress(),
        await weth.getAddress(),
        ethers.parseUnits("100", 6),
        ethers.parseUnits("0.049", 18),
        (await latestTimestamp()) + 600,
      ),
    ).to.be.revertedWithCustomError(fund, "AssetBuyingDisabled");

    await expect(
      fund.connect(trader).trade(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseUnits("0.5", 18),
        ethers.parseUnits("990", 6),
        (await latestTimestamp()) + 600,
      ),
    ).to.emit(fund, "TradeExecuted");

    await registry.setAssetStatus(await weth.getAddress(), false, false, false);
    await expect(
      fund.connect(trader).trade(
        await weth.getAddress(),
        await usdc.getAddress(),
        ethers.parseUnits("0.1", 18),
        ethers.parseUnits("190", 6),
        (await latestTimestamp()) + 600,
      ),
    ).to.be.revertedWithCustomError(fund, "AssetSellingDisabled");
  });

  it("applies protocol exposure reductions to funds that already admitted the asset", async function () {
    const { trader, investor, fund, usdc, weth, adapter, registry, wethOracle } = await deploySystem();
    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);

    await registry.configureAsset(
      await weth.getAddress(),
      18,
      await wethOracle.getAddress(),
      DAY,
      DAY,
      1_000,
      await adapter.getAddress(),
      ethers.encodeBytes32String("CRYPTO"),
      ethers.encodeBytes32String("WETH"),
    );

    await expect(
      fund.connect(trader).trade(
        await usdc.getAddress(),
        await weth.getAddress(),
        ethers.parseUnits("2000", 6),
        ethers.parseUnits("0.99", 18),
        (await latestTimestamp()) + 600,
      ),
    ).to.be.revertedWithCustomError(fund, "AssetExposureAboveLimit");
  });

  it("uses stricter settlement freshness while retaining longer-lived read-only NAV", async function () {
    const { investor, fund, weth, adapter, registry, wethOracle } = await deploySystem();
    const shares = ethers.parseUnits("1000", 18);
    await fund.connect(investor).deposit(ethers.parseUnits("1000", 6), investor.address);
    await weth.mint(await fund.getAddress(), ethers.parseUnits("1", 18));

    await registry.configureAsset(
      await weth.getAddress(),
      18,
      await wethOracle.getAddress(),
      DAY,
      60,
      7_000,
      await adapter.getAddress(),
      ethers.encodeBytes32String("CRYPTO"),
      ethers.encodeBytes32String("WETH"),
    );
    await wethOracle.setPrice(2_000n * WAD, (await latestTimestamp()) - 120);

    expect(await fund.totalAssets()).to.equal(ethers.parseUnits("3000", 6));
    await expect(fund.settlementTotalAssets()).to.be.revertedWithCustomError(fund, "StaleOraclePrice");
    await expect(fund.connect(investor).deposit(1n, investor.address)).to.be.revertedWithCustomError(
      fund,
      "StaleOraclePrice",
    );
    await expect(fund.connect(investor).redeemInKind(shares, investor.address, investor.address)).to.emit(
      fund,
      "PerformanceFeeAccrualSkipped",
    );
  });

  it("mints 18-decimal fund shares for USDC deposits and enforces user slippage", async function () {
    const { investor, fund } = await deploySystem();
    const assets = ethers.parseUnits("10000", 6);
    const expectedShares = ethers.parseUnits("10000", 18);

    await expect(fund.connect(investor).depositWithSlippage(assets, investor.address, expectedShares))
      .to.emit(fund, "Deposit")
      .withArgs(investor.address, investor.address, assets, expectedShares);

    expect(await fund.balanceOf(investor.address)).to.equal(expectedShares);
    expect(await fund.totalAssets()).to.equal(assets);

    await expect(
      fund.connect(investor).depositWithSlippage(ethers.parseUnits("1", 6), investor.address, ethers.parseUnits("2", 18)),
    ).to.be.revertedWithCustomError(fund, "InsufficientShares");
  });

  it("enforces deposit caps and guardian-controlled emergency pauses", async function () {
    const { owner, trader, guardian, investor, other, fund, usdc, weth } = await deploySystem({
      depositCap: ethers.parseUnits("15000", 6),
    });

    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);
    await expect(fund.connect(investor).deposit(ethers.parseUnits("6000", 6), investor.address))
      .to.be.revertedWithCustomError(fund, "DepositCapExceeded");

    await expect(fund.connect(other).pauseDeposits()).to.be.revertedWithCustomError(
      fund,
      "AccessControlUnauthorizedAccount",
    );
    await fund.connect(guardian).pauseDeposits();
    expect(await fund.maxDeposit(investor.address)).to.equal(0n);
    await expect(fund.connect(investor).deposit(1n, investor.address)).to.be.revertedWithCustomError(
      fund,
      "DepositsArePaused",
    );
    await expect(fund.connect(guardian).unpauseDeposits()).to.be.revertedWithCustomError(
      fund,
      "AccessControlUnauthorizedAccount",
    );
    await fund.connect(owner).unpauseDeposits();
    expect(await fund.depositsPaused()).to.equal(false);

    await fund.connect(guardian).pauseTrading();
    await expect(
      fund
        .connect(trader)
        .trade(await usdc.getAddress(), await weth.getAddress(), 1n, 1n, (await latestTimestamp()) + 600),
    ).to.be.revertedWithCustomError(fund, "TradingIsPaused");
    await expect(fund.connect(guardian).unpauseTrading()).to.be.revertedWithCustomError(
      fund,
      "AccessControlUnauthorizedAccount",
    );
    await fund.connect(owner).unpauseTrading();
    expect(await fund.tradingPaused()).to.equal(false);
  });

  it("prices the full portfolio with fresh oracles and records actual trade output", async function () {
    const { trader, investor, fund, weth } = await deploySystem();
    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);

    const amountIn = ethers.parseUnits("2000", 6);
    const expectedOut = ethers.parseUnits("1", 18);
    const minOut = ethers.parseUnits("0.99", 18);
    const deadline = (await latestTimestamp()) + 600;

    await expect(fund.connect(trader).trade(await fund.asset(), await weth.getAddress(), amountIn, minOut, deadline))
      .to.emit(fund, "TradeExecuted")
      .withArgs(trader.address, await fund.asset(), await weth.getAddress(), amountIn, expectedOut);

    expect(await weth.balanceOf(await fund.getAddress())).to.equal(expectedOut);
    expect(await fund.totalAssets()).to.equal(ethers.parseUnits("10000", 6));
  });

  it("blocks untrusted traders, unsafe slippage, oversized trades and concentration breaches", async function () {
    const { owner, trader, investor, other, fund, usdc, weth } = await deploySystem();
    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);
    const deadline = (await latestTimestamp()) + 600;

    await expect(
      fund.connect(other).trade(await usdc.getAddress(), await weth.getAddress(), 1n, 1n, deadline),
    ).to.be.revertedWithCustomError(fund, "AccessControlUnauthorizedAccount");

    await expect(
      fund
        .connect(trader)
        .trade(await usdc.getAddress(), await weth.getAddress(), ethers.parseUnits("1000", 6), 0n, deadline),
    ).to.be.revertedWithCustomError(fund, "TradeSlippageTooHigh");

    await expect(
      fund.connect(trader).trade(
        await usdc.getAddress(),
        await weth.getAddress(),
        ethers.parseUnits("6000", 6),
        ethers.parseUnits("2.9", 18),
        deadline,
      ),
    ).to.be.revertedWithCustomError(fund, "TradeValueAboveLimit");

    await fund.connect(owner).updateAssetExposure(await weth.getAddress(), 1_000);

    await expect(
      fund.connect(trader).trade(
        await usdc.getAddress(),
        await weth.getAddress(),
        ethers.parseUnits("2000", 6),
        ethers.parseUnits("0.99", 18),
        deadline,
      ),
    ).to.be.revertedWithCustomError(fund, "AssetExposureAboveLimit");

    expect(await usdc.balanceOf(await fund.getAddress())).to.equal(ethers.parseUnits("10000", 6));
    expect(await weth.balanceOf(await fund.getAddress())).to.equal(0n);
  });

  it("limits standard redemption to idle USDC and always permits a proportional in-kind exit", async function () {
    const { trader, investor, fund, usdc, weth } = await deploySystem();
    const shares = ethers.parseUnits("10000", 18);
    await fund.connect(investor).deposit(ethers.parseUnits("10000", 6), investor.address);

    await fund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("2000", 6),
      ethers.parseUnits("0.99", 18),
      (await latestTimestamp()) + 600,
    );

    expect(await fund.maxWithdraw(investor.address)).to.equal(ethers.parseUnits("8000", 6));
    expect(await fund.maxRedeem(investor.address)).to.be.lessThan(shares);
    await expect(
      fund.connect(investor).withdraw(ethers.parseUnits("8001", 6), investor.address, investor.address),
    ).to.be.revertedWithCustomError(fund, "InsufficientLiquidity");
    await expect(
      fund
        .connect(investor)
        .redeemWithSlippage(
          ethers.parseUnits("1000", 18),
          investor.address,
          investor.address,
          ethers.parseUnits("1001", 6),
        ),
    ).to.be.revertedWithCustomError(fund, "InsufficientAssets");
    await expect(fund.connect(investor).redeem(shares, investor.address, investor.address))
      .to.be.revertedWithCustomError(fund, "InsufficientLiquidity");

    const usdcBefore = await usdc.balanceOf(investor.address);
    const wethBefore = await weth.balanceOf(investor.address);
    await fund.connect(investor).redeemInKind(shares, investor.address, investor.address);

    expect((await usdc.balanceOf(investor.address)) - usdcBefore).to.equal(ethers.parseUnits("8000", 6));
    expect((await weth.balanceOf(investor.address)) - wethBefore).to.equal(ethers.parseUnits("1", 18));
    expect(await fund.totalSupply()).to.equal(0n);
  });

  it("keeps in-kind exits available when an oracle becomes stale", async function () {
    const { investor, fund, weth, wethOracle } = await deploySystem();
    const shares = ethers.parseUnits("1000", 18);
    await fund.connect(investor).deposit(ethers.parseUnits("1000", 6), investor.address);
    await weth.mint(await fund.getAddress(), ethers.parseUnits("1", 18));
    await wethOracle.setPrice(2_000n * WAD, (await latestTimestamp()) - 2 * DAY);

    await expect(fund.totalAssets()).to.be.revertedWithCustomError(fund, "StaleOraclePrice");
    await expect(fund.connect(investor).deposit(1n, investor.address)).to.be.revertedWithCustomError(
      fund,
      "StaleOraclePrice",
    );

    await expect(fund.connect(investor).redeemInKind(shares, investor.address, investor.address)).to.emit(
      fund,
      "PerformanceFeeAccrualSkipped",
    );
    expect(await fund.totalSupply()).to.equal(0n);
    expect(await weth.balanceOf(investor.address)).to.equal(ethers.parseUnits("1", 18));
  });

  it("crystallizes performance fees above a per-share high-water mark", async function () {
    const { feeRecipient, investor, fund, usdc } = await deploySystem();
    const depositAssets = ethers.parseUnits("1000", 6);
    const initialSupply = ethers.parseUnits("1000", 18);
    await fund.connect(investor).deposit(depositAssets, investor.address);

    await usdc.mint(await fund.getAddress(), ethers.parseUnits("100", 6));
    const managedAssetsWad = ethers.parseUnits("1100", 18);
    const feeAssetsWad = ethers.parseUnits("20", 18);
    const expectedFeeShares = (feeAssetsWad * initialSupply) / (managedAssetsWad - feeAssetsWad);
    const expectedHighWaterMark = (managedAssetsWad * WAD) / (initialSupply + expectedFeeShares);

    await expect(fund.accruePerformanceFee())
      .to.emit(fund, "PerformanceFeeAccrued")
      .withArgs(feeRecipient.address, feeAssetsWad, expectedFeeShares, expectedHighWaterMark);

    expect(await fund.balanceOf(feeRecipient.address)).to.equal(expectedFeeShares);
    expect(await fund.highWaterMarkWad()).to.equal(expectedHighWaterMark);
    expect(await fund.accruePerformanceFee.staticCall()).to.equal(0n);
  });

  it("only recovers unsupported tokens and requires supported assets to be empty before removal", async function () {
    const { owner, other, fund, weth, unsupported } = await deploySystem();
    await unsupported.mint(await fund.getAddress(), WAD);
    await fund.connect(owner).recoverUnsupportedToken(await unsupported.getAddress(), other.address, WAD);
    expect(await unsupported.balanceOf(other.address)).to.equal(WAD);

    await expect(
      fund.connect(owner).recoverUnsupportedToken(await weth.getAddress(), other.address, 1n),
    ).to.be.revertedWithCustomError(fund, "CannotRecoverSupportedAsset");

    await weth.mint(await fund.getAddress(), WAD);
    await expect(fund.connect(owner).removeAsset(await weth.getAddress())).to.be.revertedWithCustomError(
      fund,
      "AssetBalanceNotZero",
    );
  });

  it("isolates a restricted RWA transfer as a claim without blocking the rest of an in-kind exit", async function () {
    const { owner, investor, other, fund, usdc, adapter, registry } = await deploySystem({
      performanceFeeBps: 0,
    });
    const restrictedRwa = await ethers.deployContract("MockRestrictedERC20");
    const rwaOracle = await ethers.deployContract("MockPriceOracle", [WAD, await latestTimestamp()]);

    await registry.configureAsset(
      await restrictedRwa.getAddress(),
      18,
      await rwaOracle.getAddress(),
      DAY,
      DAY,
      10_000,
      await adapter.getAddress(),
      ethers.encodeBytes32String("RWA"),
      ethers.encodeBytes32String("RESTRICTED"),
    );
    await fund.connect(owner).addAsset(await restrictedRwa.getAddress(), 10_000);

    const deposit = ethers.parseUnits("1000", 6);
    const rwaBalance = ethers.parseUnits("100", 18);
    await fund.connect(investor).deposit(deposit, investor.address);
    await restrictedRwa.mint(await fund.getAddress(), rwaBalance);
    await restrictedRwa.setBlocked(investor.address, true);

    const shares = await fund.balanceOf(investor.address);
    await expect(fund.connect(investor).redeemInKind(shares, investor.address, investor.address))
      .to.emit(fund, "PendingClaimCreated")
      .withArgs(investor.address, await restrictedRwa.getAddress(), rwaBalance);

    expect(await usdc.balanceOf(await fund.getAddress())).to.equal(0n);
    expect(await usdc.balanceOf(investor.address)).to.equal(ethers.parseUnits("1000000", 6));
    expect(await fund.pendingClaims(investor.address, await restrictedRwa.getAddress())).to.equal(rwaBalance);
    expect(await fund.totalPendingClaims(await restrictedRwa.getAddress())).to.equal(rwaBalance);
    expect(await fund.totalAssets()).to.equal(0n);
    expect(await fund.totalSupply()).to.equal(0n);

    await expect(
      fund.connect(other).claimPending(await restrictedRwa.getAddress(), other.address),
    ).to.be.revertedWithCustomError(fund, "NoPendingClaim");
    await expect(
      fund.connect(investor).claimPending(await restrictedRwa.getAddress(), other.address),
    )
      .to.emit(fund, "PendingClaimPaid")
      .withArgs(investor.address, await restrictedRwa.getAddress(), other.address, rwaBalance);
    expect(await restrictedRwa.balanceOf(other.address)).to.equal(rwaBalance);
    expect(await fund.totalPendingClaims(await restrictedRwa.getAddress())).to.equal(0n);

    await expect(
      fund.connect(investor).deliverInKindAsset(await usdc.getAddress(), investor.address, 1n),
    ).to.be.revertedWithCustomError(fund, "UnauthorizedSelfCall");
  });

  it("prevents a compromised adapter from over-pulling input or faking trade output", async function () {
    const { trader, investor, fund, usdc, weth, registry, wethOracle } = await deploySystem({
      performanceFeeBps: 0,
    });
    const adversarialAdapter = await ethers.deployContract("AdversarialTradeAdapter", [await usdc.getAddress()]);
    await registry.configureAsset(
      await weth.getAddress(),
      18,
      await wethOracle.getAddress(),
      DAY,
      DAY,
      7_000,
      await adversarialAdapter.getAddress(),
      ethers.encodeBytes32String("CRYPTO"),
      ethers.encodeBytes32String("WETH"),
    );

    const deposit = ethers.parseUnits("10000", 6);
    const amountIn = ethers.parseUnits("1000", 6);
    const minimumOut = ethers.parseUnits("0.49", 18);
    const fundAddress = await fund.getAddress();
    await fund.connect(investor).deposit(deposit, investor.address);

    await expect(
      fund
        .connect(trader)
        .trade(await usdc.getAddress(), await weth.getAddress(), amountIn, minimumOut, (await latestTimestamp()) + 600),
    ).to.be.revertedWithCustomError(usdc, "ERC20InsufficientAllowance");
    expect(await usdc.balanceOf(fundAddress)).to.equal(deposit);
    expect(await usdc.balanceOf(await adversarialAdapter.getAddress())).to.equal(0n);

    await adversarialAdapter.setAttack(1);
    await expect(
      fund
        .connect(trader)
        .trade(await usdc.getAddress(), await weth.getAddress(), amountIn, minimumOut, (await latestTimestamp()) + 600),
    ).to.be.revertedWithCustomError(fund, "InsufficientAssets");
    expect(await usdc.balanceOf(fundAddress)).to.equal(deposit);
    expect(await usdc.balanceOf(await adversarialAdapter.getAddress())).to.equal(0n);

    await weth.mint(await adversarialAdapter.getAddress(), minimumOut);
    await adversarialAdapter.setAttack(2);
    await expect(
      fund
        .connect(trader)
        .trade(await usdc.getAddress(), await weth.getAddress(), amountIn, minimumOut, (await latestTimestamp()) + 600),
    ).to.emit(fund, "TradeExecuted");
    expect(await usdc.balanceOf(fundAddress)).to.equal(deposit - amountIn);
    expect(await weth.balanceOf(fundAddress)).to.equal(minimumOut);
  });

  it("resists first-depositor donation attacks with virtual shares", async function () {
    const { investor, other: attacker, fund, usdc } = await deploySystem({
      performanceFeeBps: 0,
      depositCap: ethers.parseUnits("2000000", 6),
    });
    const attackerDeposit = 1n;
    const donation = ethers.parseUnits("1000000", 6);
    const victimDeposit = ethers.parseUnits("10000", 6);

    await usdc.mint(attacker.address, donation + attackerDeposit);
    await usdc.connect(attacker).approve(await fund.getAddress(), ethers.MaxUint256);
    await fund.connect(attacker).deposit(attackerDeposit, attacker.address);
    await usdc.connect(attacker).transfer(await fund.getAddress(), donation);

    await fund.connect(investor).deposit(victimDeposit, investor.address);
    const victimShares = await fund.balanceOf(investor.address);
    expect(victimShares).to.be.greaterThan(0n);
    expect(await fund.previewRedeem(victimShares)).to.be.greaterThanOrEqual(victimDeposit - 1n);

    const attackerShares = await fund.balanceOf(attacker.address);
    const attackerBalanceBeforeExit = await usdc.balanceOf(attacker.address);
    await fund.connect(attacker).redeemInKind(attackerShares, attacker.address, attacker.address);
    const attackerRecovered = (await usdc.balanceOf(attacker.address)) - attackerBalanceBeforeExit;
    expect(attackerRecovered).to.be.lessThan(donation + attackerDeposit);

    await fund.connect(investor).redeemInKind(victimShares, investor.address, investor.address);
    expect(await fund.totalSupply()).to.equal(0n);
    expect(await usdc.balanceOf(await fund.getAddress())).to.equal(0n);
  });

  it("blocks new deposits after a direct token donation breaches exposure limits", async function () {
    const { owner, trader, investor, fund, usdc, weth } = await deploySystem({ performanceFeeBps: 0 });
    await fund.connect(owner).updateAssetExposure(await weth.getAddress(), 3_000);
    await fund.connect(investor).deposit(ethers.parseUnits("1000", 6), investor.address);

    await weth.mint(await fund.getAddress(), ethers.parseUnits("1", 18));
    expect(await fund.exposuresCompliant()).to.equal(false);
    expect(await fund.maxDeposit(investor.address)).to.equal(0n);
    await expect(fund.connect(investor).deposit(1n, investor.address))
      .to.be.revertedWithCustomError(fund, "DepositCapExceeded")
      .withArgs(1n, 0n);

    await fund.connect(trader).trade(
      await weth.getAddress(),
      await usdc.getAddress(),
      ethers.parseUnits("0.7", 18),
      ethers.parseUnits("1330", 6),
      (await latestTimestamp()) + 600,
    );
    expect(await fund.exposuresCompliant()).to.equal(true);
    expect(await fund.maxDeposit(investor.address)).to.be.greaterThan(0n);
  });

  it("preserves accounting invariants through a deterministic multi-user operation sequence", async function () {
    const { investor, other, feeRecipient, fund, usdc } = await deploySystem({ performanceFeeBps: 0 });
    await usdc.mint(other.address, ethers.parseUnits("200000", 6));
    await usdc.connect(other).approve(await fund.getAddress(), ethers.MaxUint256);

    const actors = [investor, other];
    let state = 0x5eedn;
    for (let i = 0; i < 64; i += 1) {
      state = (state * 1_103_515_245n + 12_345n) % (2n ** 31n);
      const actor = actors[Number(state % 2n)];
      const shouldDeposit = state % 3n !== 0n;

      if (shouldDeposit) {
        const amount = ((state % 1_000n) + 1n) * 10n ** 6n;
        await fund.connect(actor).deposit(amount, actor.address);
      } else {
        const shares = await fund.balanceOf(actor.address);
        if (shares > 0n) {
          const sharesToRedeem = shares / ((state % 4n) + 2n);
          if (sharesToRedeem > 0n) {
            await fund.connect(actor).redeem(sharesToRedeem, actor.address, actor.address);
          }
        }
      }

      const supply = await fund.totalSupply();
      const summedBalances =
        (await fund.balanceOf(investor.address)) +
        (await fund.balanceOf(other.address)) +
        (await fund.balanceOf(feeRecipient.address));
      const managedAssets = await fund.totalAssets();
      expect(summedBalances).to.equal(supply);
      expect(managedAssets).to.equal(await usdc.balanceOf(await fund.getAddress()));
      expect(await fund.convertToAssets(supply)).to.be.lessThanOrEqual(managedAssets);
    }
  });

  it("does not silently re-enable an asset when the protocol updates its policy", async function () {
    const { weth, adapter, registry, wethOracle } = await deploySystem();
    await registry.setAssetStatus(await weth.getAddress(), false, false, true);
    await registry.configureAsset(
      await weth.getAddress(),
      18,
      await wethOracle.getAddress(),
      DAY,
      DAY,
      6_000,
      await adapter.getAddress(),
      ethers.encodeBytes32String("CRYPTO"),
      ethers.encodeBytes32String("WETH"),
    );

    const policy = await registry.getAssetPolicy(await weth.getAddress());
    expect(policy.admissionEnabled).to.equal(false);
    expect(policy.buyEnabled).to.equal(false);
    expect(policy.sellEnabled).to.equal(true);
    expect(policy.maxExposureBps).to.equal(6_000n);
  });

  it("validates safety-critical constructor bounds", async function () {
    const { owner, trader, guardian, feeRecipient, usdc, registry } = await deploySystem();
    const baseParams = {
      name: "Bounds",
      symbol: "BND",
      metadataURI: "ipfs://bounds",
      accountingAsset: await usdc.getAddress(),
      assetRegistry: await registry.getAddress(),
      admin: owner.address,
      trader: trader.address,
      guardian: guardian.address,
      feeRecipient: feeRecipient.address,
      performanceFeeBps: 0,
      maxTradeSlippageBps: 500,
      maxTradeValueBps: 5_000,
      adminTransferDelay: 0,
      depositCap: ethers.parseUnits("1000", 6),
    };

    await expect(
      ethers.deployContract("RafaFundV2", [{ ...baseParams, performanceFeeBps: 3_001 }]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("RafaFundV2"), "InvalidFee");
    await expect(
      ethers.deployContract("RafaFundV2", [{ ...baseParams, maxTradeSlippageBps: 2_001 }]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("RafaFundV2"), "InvalidSlippage");
    await expect(
      ethers.deployContract("RafaFundV2", [{ ...baseParams, maxTradeValueBps: 0 }]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("RafaFundV2"), "InvalidRiskLimit");
    await expect(
      ethers.deployContract("RafaFundV2", [{ ...baseParams, depositCap: 0 }]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("RafaFundV2"), "InvalidAmount");

    const highDecimalsAsset = await ethers.deployContract("MockERC20", ["High Decimals", "HIGH", 19]);
    const highDecimalsRegistry = await ethers.deployContract("RafaAssetRegistry", [
      owner.address,
      await highDecimalsAsset.getAddress(),
    ]);
    await expect(
      ethers.deployContract("RafaFundV2", [
        {
          ...baseParams,
          accountingAsset: await highDecimalsAsset.getAddress(),
          assetRegistry: await highDecimalsRegistry.getAddress(),
        },
      ]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("RafaFundV2"), "UnsupportedDecimals");
  });

  it("enforces delegated exits and administrator update boundaries", async function () {
    const { owner, investor, other, fund, usdc, weth } = await deploySystem({ performanceFeeBps: 0 });
    const mintedShares = ethers.parseUnits("1000", 18);
    await fund.connect(investor).mint(mintedShares, investor.address);
    expect(await fund.maxRedeem(other.address)).to.equal(0n);
    expect(await fund.pricePerShareWad()).to.equal(WAD);

    const delegatedAssets = ethers.parseUnits("100", 6);
    const delegatedShares = await fund.previewWithdraw(delegatedAssets);
    await fund.connect(investor).approve(other.address, delegatedShares);
    await fund.connect(other).withdraw(delegatedAssets, other.address, investor.address);
    expect(await usdc.balanceOf(other.address)).to.equal(delegatedAssets);
    expect(await fund.allowance(investor.address, other.address)).to.equal(0n);

    await expect(fund.connect(other).setDepositCap(1n)).to.be.revertedWithCustomError(
      fund,
      "AccessControlUnauthorizedAccount",
    );
    await expect(fund.connect(owner).setDepositCap(0n)).to.be.revertedWithCustomError(fund, "InvalidAmount");
    await fund.connect(owner).setDepositCap(ethers.parseUnits("2000000", 6));
    await expect(fund.connect(owner).setMaxTradeValueBps(0)).to.be.revertedWithCustomError(
      fund,
      "InvalidRiskLimit",
    );
    await fund.connect(owner).setMaxTradeValueBps(2_500);
    await expect(fund.connect(owner).setFeeRecipient(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      fund,
      "InvalidAddress",
    );
    await fund.connect(owner).setFeeRecipient(other.address);
    await fund.connect(owner).setMetadataURI("ipfs://updated");
    expect(await fund.metadataURI()).to.equal("ipfs://updated");

    await fund.connect(owner).removeAsset(await weth.getAddress());
    expect(await fund.getActiveAssets()).to.deep.equal([]);
    await expect(fund.connect(owner).removeAsset(await weth.getAddress())).to.be.revertedWithCustomError(
      fund,
      "AssetNotSupported",
    );
    await expect(fund.connect(investor).redeemInKind(0n, investor.address, investor.address)).to.be.revertedWithCustomError(
      fund,
      "InvalidAmount",
    );
  });
});

describe("FundFactoryV2", function () {
  it("only lets the RAFA owner register configuration-matched official funds", async function () {
    const { owner, other, fund, usdc, registry } = await deploySystem();
    const factory = await ethers.deployContract("FundFactoryV2", [
      owner.address,
      await usdc.getAddress(),
      await registry.getAddress(),
      2_000,
    ]);

    await expect(factory.connect(other).registerFund(await fund.getAddress())).to.be.revertedWithCustomError(
      factory,
      "OwnableUnauthorizedAccount",
    );
    await expect(factory.connect(owner).registerFund(await fund.getAddress())).to.emit(factory, "FundCreated");

    expect(await factory.fundsLength()).to.equal(1n);
    expect(await factory.fundAt(0)).to.equal(await fund.getAddress());
    expect(await factory.isFund(await fund.getAddress())).to.equal(true);
    expect(await factory.isActiveFund(await fund.getAddress())).to.equal(true);
    expect(await fund.IMPLEMENTATION_ID()).to.equal(ethers.keccak256(ethers.toUtf8Bytes("RAFA_FUND_V2")));
    expect(await factory.getFunds(0, ethers.MaxUint256)).to.deep.equal([await fund.getAddress()]);

    await expect(factory.connect(owner).setFundActive(await fund.getAddress(), false))
      .to.emit(factory, "FundStatusUpdated")
      .withArgs(await fund.getAddress(), false);
    expect(await factory.isActiveFund(await fund.getAddress())).to.equal(false);

    await expect(factory.connect(owner).registerFund(await fund.getAddress())).to.be.revertedWithCustomError(
      factory,
      "FundAlreadyRegistered",
    );
  });

  it("creates, registers, funds and allocates a four-fund catalog", async function () {
    const { owner, trader, guardian, feeRecipient, investor, fund: balancedFund, usdc, weth, registry } =
      await deploySystem({ performanceFeeBps: 0 });
    const commonParams = {
      metadataURI: "https://rafa.ai/docs",
      accountingAsset: await usdc.getAddress(),
      assetRegistry: await registry.getAddress(),
      admin: owner.address,
      trader: trader.address,
      guardian: guardian.address,
      feeRecipient: feeRecipient.address,
      performanceFeeBps: 0,
      maxTradeSlippageBps: 500,
      maxTradeValueBps: 5_000,
      adminTransferDelay: 0,
      depositCap: ethers.parseUnits("1000000", 6),
    };
    const cashFund = await ethers.deployContract("RafaFundV2", [
      { ...commonParams, name: "RAFA Cash", symbol: "rCASH" },
    ]);
    const conservativeFund = await ethers.deployContract("RafaFundV2", [
      { ...commonParams, name: "RAFA Conservative", symbol: "rSAFE" },
    ]);
    const growthFund = await ethers.deployContract("RafaFundV2", [
      { ...commonParams, name: "RAFA Growth", symbol: "rGROW" },
    ]);
    await conservativeFund.addAsset(await weth.getAddress(), 3_000);
    await growthFund.addAsset(await weth.getAddress(), 7_000);

    const factory = await ethers.deployContract("FundFactoryV2", [
      owner.address,
      await usdc.getAddress(),
      await registry.getAddress(),
      2_000,
    ]);
    const funds = [cashFund, conservativeFund, balancedFund, growthFund];
    for (const catalogFund of funds) {
      await factory.registerFund(await catalogFund.getAddress());
      await usdc.connect(investor).approve(await catalogFund.getAddress(), ethers.MaxUint256);
      await catalogFund.connect(investor).deposit(ethers.parseUnits("1000", 6), investor.address);
    }

    const deadline = (await latestTimestamp()) + 600;
    await conservativeFund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("100", 6),
      ethers.parseUnits("0.048", 18),
      deadline,
    );
    await balancedFund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("200", 6),
      ethers.parseUnits("0.095", 18),
      deadline,
    );
    await growthFund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("500", 6),
      ethers.parseUnits("0.24", 18),
      deadline,
    );
    await growthFund.connect(trader).trade(
      await usdc.getAddress(),
      await weth.getAddress(),
      ethers.parseUnits("100", 6),
      ethers.parseUnits("0.048", 18),
      deadline,
    );

    expect(await factory.fundsLength()).to.equal(4n);
    expect(await factory.getFunds(1, 2)).to.deep.equal([
      await conservativeFund.getAddress(),
      await balancedFund.getAddress(),
    ]);
    expect(await cashFund.totalAssets()).to.equal(ethers.parseUnits("1000", 6));
    expect(await conservativeFund.totalAssets()).to.equal(ethers.parseUnits("1000", 6));
    expect(await balancedFund.totalAssets()).to.equal(ethers.parseUnits("1000", 6));
    expect(await growthFund.totalAssets()).to.equal(ethers.parseUnits("1000", 6));
    expect(await weth.balanceOf(await cashFund.getAddress())).to.equal(0n);
    expect(await weth.balanceOf(await conservativeFund.getAddress())).to.equal(ethers.parseUnits("0.05", 18));
    expect(await weth.balanceOf(await balancedFund.getAddress())).to.equal(ethers.parseUnits("0.1", 18));
    expect(await weth.balanceOf(await growthFund.getAddress())).to.equal(ethers.parseUnits("0.3", 18));
  });

  it("rejects funds with a different accounting asset, registry or excessive performance fee", async function () {
    const { owner, trader, guardian, feeRecipient, usdc, registry } = await deploySystem();
    const alternateUsdc = await ethers.deployContract("MockERC20", ["Other USD", "oUSD", 6]);
    const alternateRegistry = await ethers.deployContract("RafaAssetRegistry", [
      owner.address,
      await alternateUsdc.getAddress(),
    ]);
    const mismatchedFund = await ethers.deployContract("RafaFundV2", [
      {
        name: "Mismatched",
        symbol: "MIS",
        metadataURI: "ipfs://mismatch",
        accountingAsset: await alternateUsdc.getAddress(),
        assetRegistry: await alternateRegistry.getAddress(),
        admin: owner.address,
        trader: trader.address,
        guardian: guardian.address,
        feeRecipient: feeRecipient.address,
        performanceFeeBps: 2_000,
        maxTradeSlippageBps: 500,
        maxTradeValueBps: 5_000,
        adminTransferDelay: 0,
        depositCap: ethers.parseUnits("1000000", 6),
      },
    ]);
    const highFeeFund = await ethers.deployContract("RafaFundV2", [
      {
        name: "High Fee",
        symbol: "HIGH",
        metadataURI: "ipfs://high-fee",
        accountingAsset: await usdc.getAddress(),
        assetRegistry: await registry.getAddress(),
        admin: owner.address,
        trader: trader.address,
        guardian: guardian.address,
        feeRecipient: feeRecipient.address,
        performanceFeeBps: 2_500,
        maxTradeSlippageBps: 500,
        maxTradeValueBps: 5_000,
        adminTransferDelay: 0,
        depositCap: ethers.parseUnits("1000000", 6),
      },
    ]);
    const factory = await ethers.deployContract("FundFactoryV2", [
      owner.address,
      await usdc.getAddress(),
      await registry.getAddress(),
      2_000,
    ]);

    await expect(factory.registerFund(await mismatchedFund.getAddress())).to.be.revertedWithCustomError(
      factory,
      "InvalidFundConfiguration",
    );
    await expect(factory.registerFund(await highFeeFund.getAddress())).to.be.revertedWithCustomError(
      factory,
      "PerformanceFeeAboveMaximum",
    );
  });
});

describe("Chain execution adapters", function () {
  it("executes an owner-approved Ethereum Uniswap V3 pool and rejects other assets", async function () {
    const [owner, trader] = await ethers.getSigners();
    const usdc = await ethers.deployContract("MockERC20", ["USD Coin", "USDC", 6]);
    const equity = await ethers.deployContract("MockERC20", ["Tokenized Equity", "EQTY", 18]);
    const other = await ethers.deployContract("MockERC20", ["Other", "OTHER", 18]);
    const router = await ethers.deployContract("MockUniswapV3SwapRouter");
    const adapter = await ethers.deployContract("UniswapV3Adapter", [
      owner.address,
      await usdc.getAddress(),
      await router.getAddress(),
    ]);

    await expect(adapter.connect(trader).configurePool(await equity.getAddress(), 500)).to.be.revertedWithCustomError(
      adapter,
      "OwnableUnauthorizedAccount",
    );
    await adapter.configurePool(await equity.getAddress(), 500);
    await router.setRate(
      await usdc.getAddress(),
      await equity.getAddress(),
      500,
      ethers.parseUnits("1", 18),
      ethers.parseUnits("100", 6),
    );

    await usdc.mint(trader.address, ethers.parseUnits("1000", 6));
    await equity.mint(await router.getAddress(), ethers.parseUnits("100", 18));
    await usdc.connect(trader).approve(await adapter.getAddress(), ethers.MaxUint256);

    await adapter.connect(trader).swapExactInput(
      await usdc.getAddress(),
      await equity.getAddress(),
      ethers.parseUnits("100", 6),
      ethers.parseUnits("0.99", 18),
      trader.address,
      (await latestTimestamp()) + 600,
    );
    expect(await equity.balanceOf(trader.address)).to.equal(ethers.parseUnits("1", 18));

    await expect(
      adapter.connect(trader).swapExactInput(
        await usdc.getAddress(),
        await other.getAddress(),
        ethers.parseUnits("1", 6),
        1,
        trader.address,
        (await latestTimestamp()) + 600,
      ),
    ).to.be.revertedWithCustomError(adapter, "PoolNotConfigured");
  });
});

describe("ChainlinkPriceOracle", function () {
  it("normalizes feed decimals and enforces Base sequencer status", async function () {
    const assetFeed = await ethers.deployContract("MockAggregatorV3", [8]);
    const accountingFeed = await ethers.deployContract("MockAggregatorV3", [8]);
    const sequencerFeed = await ethers.deployContract("MockAggregatorV3", [0]);
    const timestamp = await latestTimestamp();

    await assetFeed.setRoundData(10, 2000n * 10n ** 8n, timestamp - 20, timestamp - 10, 10);
    await accountingFeed.setRoundData(20, 1n * 10n ** 8n, timestamp - 20, timestamp - 5, 20);
    await sequencerFeed.setRoundData(1, 0, timestamp - 1000, timestamp - 1, 1);

    const oracle = await ethers.deployContract("ChainlinkPriceOracle", [
      await assetFeed.getAddress(),
      await accountingFeed.getAddress(),
      await sequencerFeed.getAddress(),
      300,
    ]);

    const [price, updatedAt] = await oracle.latestPrice();
    expect(price).to.equal(2000n * WAD);
    expect(updatedAt).to.equal(timestamp - 10);

    await sequencerFeed.setRoundData(2, 1, timestamp - 1000, timestamp, 2);
    await expect(oracle.latestPrice()).to.be.revertedWithCustomError(oracle, "SequencerDown");

    await sequencerFeed.setRoundData(3, 0, timestamp - 100, timestamp, 3);
    await expect(oracle.latestPrice()).to.be.revertedWithCustomError(oracle, "SequencerGracePeriodActive");

    await sequencerFeed.setRoundData(4, 0, timestamp - 1000, timestamp, 4);
    await assetFeed.setRoundData(11, 2000n * 10n ** 8n, timestamp, timestamp + 100, 11);
    await expect(oracle.latestPrice()).to.be.revertedWithCustomError(oracle, "InvalidOracleTimestamp");
  });

  it("rejects invalid answers, incomplete rounds and unsupported feed precision", async function () {
    const assetFeed = await ethers.deployContract("MockAggregatorV3", [8]);
    const accountingFeed = await ethers.deployContract("MockAggregatorV3", [8]);
    const timestamp = await latestTimestamp();
    const oracle = await ethers.deployContract("ChainlinkPriceOracle", [
      await assetFeed.getAddress(),
      await accountingFeed.getAddress(),
      ethers.ZeroAddress,
      0,
    ]);

    await accountingFeed.setRoundData(1, 10n ** 8n, timestamp, timestamp, 1);
    await assetFeed.setRoundData(1, 0, timestamp, timestamp, 1);
    await expect(oracle.latestPrice()).to.be.revertedWithCustomError(oracle, "InvalidOracleAnswer");

    await assetFeed.setRoundData(2, 2_000n * 10n ** 8n, timestamp, timestamp, 1);
    await expect(oracle.latestPrice()).to.be.revertedWithCustomError(oracle, "IncompleteOracleRound");

    const highPrecisionFeed = await ethers.deployContract("MockAggregatorV3", [19]);
    await expect(
      ethers.deployContract("ChainlinkPriceOracle", [
        await highPrecisionFeed.getAddress(),
        await accountingFeed.getAddress(),
        ethers.ZeroAddress,
        0,
      ]),
    ).to.be.revertedWithCustomError(await ethers.getContractFactory("ChainlinkPriceOracle"), "UnsupportedFeedDecimals");
  });
});
