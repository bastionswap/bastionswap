import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x124854b2535239b5644D748089A31f968e50CAC8",
    EscrowVault: "0x1502559d2ee4174697fd713b7E782405B1eeAd0A",
    InsurancePool: "0x04a6BD3f98502934177D756bd04e28D19Fd7C93c",
    TriggerOracle: "0x09dD72c65A2c477AD58A158f2E6ABbC227611481",
    ReputationEngine: "0x62D09C1DF1980DdC6F427EF0E8368e4fe86bfA2d",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xC6Fb57dE6DBD8B45864d1a183EB686a007115135",
    BastionPositionRouter: "0x2601FEB47f2BE23fcaF2eEa4562a0D0577C30B2C",
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
