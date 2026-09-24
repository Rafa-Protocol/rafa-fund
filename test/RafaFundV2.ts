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
  const timestamp = await latestTimestamp();
  const wethOracle = await ethers.deployContract("MockPriceOracle", [2_000n * WAD, timestamp]);

  const params = {
    name: "RAFA Balanced Fund",
    symbol: "rBAL",
    metadataURI: "ipfs://rafa-balanced",
    accountingAsset: await usdc.getAddress(),
    router: await router.getAddress(),
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
  await fund.addAsset(await weth.getAddress(), await wethOracle.getAddress(), DAY, false, 7_000);

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

  return { owner, trader, guardian, feeRecipient, investor, other, usdc, weth, unsupported, router, wethOracle, fund };
}

describe("RafaFundV2", function () {
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

    await fund
      .connect(owner)
      .updateAsset(await weth.getAddress(), await (await ethers.deployContract("MockPriceOracle", [2_000n * WAD, await latestTimestamp()])).getAddress(), DAY, false, 1_000);

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
});

describe("FundFactoryV2", function () {
  it("only lets the RAFA owner register configuration-matched official funds", async function () {
    const { owner, other, fund, usdc, router } = await deploySystem();
    const factory = await ethers.deployContract("FundFactoryV2", [
      owner.address,
      await usdc.getAddress(),
      await router.getAddress(),
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

  it("rejects funds with a different accounting asset, router or excessive performance fee", async function () {
    const { owner, trader, guardian, feeRecipient, usdc, router } = await deploySystem();
    const alternateUsdc = await ethers.deployContract("MockERC20", ["Other USD", "oUSD", 6]);
    const mismatchedFund = await ethers.deployContract("RafaFundV2", [
      {
        name: "Mismatched",
        symbol: "MIS",
        metadataURI: "ipfs://mismatch",
        accountingAsset: await alternateUsdc.getAddress(),
        router: await router.getAddress(),
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
        router: await router.getAddress(),
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
      await router.getAddress(),
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
});
