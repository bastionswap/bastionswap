import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0xF21DdeC12b95Af7aF535c7f141eCd2640e27cAC8",
    EscrowVault: "0xdD5fd2496c693A03Dd5321ee1954D0968c314Da1",
    InsurancePool: "0x07ae2AD8615Aab1ec877774cE8705A3671294881",
    TriggerOracle: "0x81810ac92A515a4a970dF1D4D627dE8197DB0975",
    ReputationEngine: "0xD4B17124A2Df0005d40b23b95c731fB8Dc756a5c",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x20660E456a57Dd163094455e43a2bE2E1F0906a3",
    BastionPositionRouter: "0xde11FcB12ca3976D481E41490F8e529dD7e4C106",
  },
} as const;

const ALL_CONTRACTS: Record<number, Record<string, string>> = {
  ...CONTRACTS,
  ...LOCAL_CONTRACTS,
};

export type SupportedChainId = keyof typeof CONTRACTS | keyof typeof LOCAL_CONTRACTS;

export function getContracts(chainId: number) {
  return ALL_CONTRACTS[chainId];
}
