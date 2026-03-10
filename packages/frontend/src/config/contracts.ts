import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0x2fd8A3d76815f6a287544261C7A69f181cDC0aC8",
    EscrowVault: "0xCe28BcC799fA9632F8FdD3A88546Ce9B860dC83a",
    InsurancePool: "0xb0706bD693d09aFcC3cF686212B86D8D8c993E31",
    TriggerOracle: "0xF5C2034126076643B3e43E176d938CEA06ae170d",
    ReputationEngine: "0x11ADd0784cE80E135815484906E17Bef46f49a97",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0xb214598a54634B31C47921291FDB47ae3e4CE909",
    BastionPositionRouter: "0x9649345E136d2a8804B5D598ee859d18d4A2aBae",
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
