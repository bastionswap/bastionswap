import { createConfig, http } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { defineChain } from "viem";
import { getDefaultConfig } from "connectkit";

const anvilBaseFork = defineChain({
  id: 31337,
  name: "Base Fork (Local)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});

export const config = createConfig(
  getDefaultConfig({
    chains: [baseSepolia, anvilBaseFork],
    transports: {
      [baseSepolia.id]: http(),
      [anvilBaseFork.id]: http(),
    },
    walletConnectProjectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID || "",
    appName: "BastionSwap",
    appDescription: "Protected token swaps on Uniswap V4",
    appUrl: "https://bastionswap-frontend.vercel.app",
  })
);
