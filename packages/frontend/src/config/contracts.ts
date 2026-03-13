import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0xe02eE40c15cF6e9012C9a169B3faf1faBb0fCac8",
    EscrowVault: "0x3b5dA03D8d0c6C8BF8DB9cB831705abb23CB903b",
    InsurancePool: "0x4D01FeF8ca2E9fdf2faf99eD84474Eb259B8B329",
    TriggerOracle: "0x48f5C8B1E4A8a91F5E070176266169a97bcA418a",
    ReputationEngine: "0x1DA449fC0484a88E94fD5dd3C7466F39D26F11AE",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xb069198DCA6B317D1E3E7dcFa150fF0cccD61cCF",
    BastionPositionRouter: "0xE845454848173cf9e5127dc12e566aaDa46ca918",
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
