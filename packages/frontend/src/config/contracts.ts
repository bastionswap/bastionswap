import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x9eEc4B1e209094BBf7989C63bf9b8f8339098Ac8",
    EscrowVault: "0xb355E5FA75BAD5BB356dEbaea13c35D509cc26bE",
    InsurancePool: "0x4aa0D8bb534F398eFF2a7cbFe96938970f147509",
    TriggerOracle: "0xF66FfAbcD505BDA046CcC0Fcc139fa3aE8c933eD",
    ReputationEngine: "0xff222eF342a3430842D3c205E299294EA6395071",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xEa529B6813355d8054fbF5Ef9a136696Db71b325",
    BastionPositionRouter: "0xec8cA718a00a461F97066b75C551bc2C493dCBEb",
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
