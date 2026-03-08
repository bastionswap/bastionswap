import { createConnector, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { baseSepolia } from "wagmi/chains";
import { defineChain } from "viem";
import {
  getDefaultConfig,
  getWalletConnectConnector,
  type Wallet,
} from "@rainbow-me/rainbowkit";
import {
  metaMaskWallet,
  coinbaseWallet,
  walletConnectWallet,
  rainbowWallet,
  braveWallet,
} from "@rainbow-me/rainbowkit/wallets";

const anvilBaseFork = defineChain({
  id: 31337,
  name: "Base Fork (Local)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: ["http://127.0.0.1:8545"] },
  },
});

function getPhantomProvider() {
  if (typeof window === "undefined") return undefined;
  // eslint-disable-next-line
  return (window as any).phantom?.ethereum;
}

const phantomWalletCustom = ({
  projectId,
  walletConnectParameters,
}: {
  projectId: string;
  walletConnectParameters?: object;
}): Wallet => {
  const isInstalled = !!getPhantomProvider();

  return {
    id: "phantom",
    name: "Phantom",
    rdns: "app.phantom",
    iconUrl:
      "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='28' height='28' fill='none'%3E%3Cg clip-path='url(%23a)'%3E%3Cpath fill='%23AB9FF2' d='M28 0H0v28h28V0Z'/%3E%3Cpath fill='%23FFFDF8' fill-rule='evenodd' d='M12.063 18.128c-1.173 1.796-3.137 4.07-5.75 4.07-1.236 0-2.424-.51-2.424-2.719 0-5.627 7.682-14.337 14.81-14.337 4.056 0 5.671 2.813 5.671 6.008 0 4.101-2.66 8.79-5.306 8.79-.84 0-1.252-.46-1.252-1.192 0-.19.032-.397.095-.62-.902 1.542-2.645 2.973-4.276 2.973-1.188 0-1.79-.747-1.79-1.797 0-.381.079-.778.222-1.176Zm9.63-7.089c0 .931-.549 1.397-1.163 1.397-.624 0-1.164-.466-1.164-1.397 0-.93.54-1.396 1.164-1.396.614 0 1.164.465 1.164 1.396Zm-3.49 0c0 .931-.55 1.397-1.164 1.397-.624 0-1.164-.466-1.164-1.397 0-.93.54-1.396 1.164-1.396.614 0 1.164.465 1.164 1.396Z' clip-rule='evenodd'/%3E%3C/g%3E%3Cdefs%3E%3CclipPath id='a'%3E%3Cpath fill='%23fff' d='M0 0h28v28H0z'/%3E%3C/clipPath%3E%3C/defs%3E%3C/svg%3E",
    iconBackground: "#9A8AEE",
    installed: isInstalled || undefined,
    mobile: {
      getUri: isInstalled
        ? undefined
        : (uri: string) =>
            `https://phantom.app/ul/wc?uri=${encodeURIComponent(uri)}`,
    },
    qrCode: isInstalled
      ? undefined
      : {
          getUri: (uri: string) => uri,
          instructions: {
            steps: [
              {
                description: "Open Phantom app and tap the scan button.",
                step: "scan" as const,
                title: "Open Phantom",
              },
            ],
            learnMoreUrl: "https://help.phantom.app",
          },
        },
    extension: {
      instructions: {
        steps: [
          {
            description:
              "Add Phantom to your browser. Once done, pin it for easy access.",
            step: "install" as const,
            title: "Install Phantom",
          },
          {
            description: "Create a new wallet or import an existing one.",
            step: "create" as const,
            title: "Create or Import",
          },
          {
            description:
              "Refresh this page and Phantom will appear as a connection option.",
            step: "refresh" as const,
            title: "Refresh",
          },
        ],
        learnMoreUrl: "https://help.phantom.app",
      },
    },
    createConnector: isInstalled
      ? (walletDetails) =>
          createConnector((config) => ({
            ...injected({
              target: () => ({
                id: walletDetails.rkDetails.id,
                name: walletDetails.rkDetails.name,
                provider: getPhantomProvider(),
              }),
            })(config),
            ...walletDetails,
          }))
      : getWalletConnectConnector({
          projectId,
          walletConnectParameters,
        }),
  };
};

export const config = getDefaultConfig({
  appName: "BastionSwap",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID || "placeholder",
  chains: [baseSepolia, anvilBaseFork],
  transports: {
    [baseSepolia.id]: http(),
    [anvilBaseFork.id]: http(),
  },
  wallets: [
    {
      groupName: "Popular",
      wallets: [
        metaMaskWallet,
        phantomWalletCustom,
        coinbaseWallet,
        rainbowWallet,
        braveWallet,
        walletConnectWallet,
      ],
    },
  ],
});
