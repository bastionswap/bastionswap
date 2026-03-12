import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x4bc94824a7AcB06001ECd59Bd77db518eBAA4aC8",
    EscrowVault: "0xE4A0Fd4936ADF81ED9E77DDcDe3f2654719ceC06",
    InsurancePool: "0xa3C5947CD6CE840B651479a5b98157d12B72C21e",
    TriggerOracle: "0x0F42632b02AA839F053410322B139184E25971d2",
    ReputationEngine: "0x844E1A6fbe2CD8C71C5747e8ba393a5921c7FBe0",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xf2414160c571b62aC255A9b5b4AE1786FCC3B072",
    BastionPositionRouter: "0x3d9Be7276Cf81caA430a7c005C2f23c4B4b7bfd7",
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
