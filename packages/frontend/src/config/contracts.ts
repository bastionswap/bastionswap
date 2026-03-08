import { LOCAL_CONTRACTS } from "./contracts.generated";

export const CONTRACTS = {
  84532: {
    BastionHook: "0xDD1B637114B55C54117437D9bA8CddA646330aC8",
    EscrowVault: "0xAE9cB890Fc31CEF63c240c37580efF85028B5cab",
    InsurancePool: "0x12d0B5406C42EF824Dc92912cFED67bC39366665",
    TriggerOracle: "0x3312eB254ddCC7d61F51e3A241A5e144662599ca",
    ReputationEngine: "0x9aDC4a819dEfD40b3096c479B31F5DCb0dff5e86",
    PoolManager: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    BastionSwapRouter: "0x1277388ef8fFb4cA3aa3c89c96965Cb3d6bEf4f2",
    BastionPositionRouter: "0x6e2B3Ba459CbB83662a83c375225F5FDd39f0F63",
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
