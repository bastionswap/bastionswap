"use client";

import { useState, type ReactNode } from "react";

export type SidebarTab = "trade" | "protection" | "issuer";

interface TabConfig {
  id: SidebarTab;
  label: string;
  badge?: ReactNode;
}

interface PoolSidebarTabsProps {
  isTriggered?: boolean;
  reputationScore?: number | null;
  tradeContent: ReactNode;
  protectionContent: ReactNode;
  issuerContent: ReactNode;
  /** Content shown above tabs on all tabs (e.g. TriggerBanner when active) */
  alertBanner?: ReactNode;
}

export function PoolSidebarTabs({
  isTriggered,
  reputationScore,
  tradeContent,
  protectionContent,
  issuerContent,
  alertBanner,
}: PoolSidebarTabsProps) {
  const [activeTab, setActiveTab] = useState<SidebarTab>("trade");

  const tabs: TabConfig[] = [
    { id: "trade", label: "Trade" },
    {
      id: "protection",
      label: "Protection",
      badge: isTriggered ? (
        <span className="relative flex h-2 w-2 ml-1.5">
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-red-400 opacity-75" />
          <span className="relative inline-flex h-2 w-2 rounded-full bg-red-500" />
        </span>
      ) : null,
    },
    {
      id: "issuer",
      label: "Issuer",
      badge:
        reputationScore != null ? (
          <span className="ml-1.5 inline-flex items-center justify-center rounded-full bg-bastion-100 text-bastion-700 text-[10px] font-semibold min-w-[20px] h-[18px] px-1">
            {reputationScore}
          </span>
        ) : null,
    },
  ];

  const contentMap: Record<SidebarTab, ReactNode> = {
    trade: tradeContent,
    protection: protectionContent,
    issuer: issuerContent,
  };

  return (
    <div>
      {/* Alert banner always visible (renders nothing when no trigger) */}
      {alertBanner}

      {/* Tab bar */}
      <div className="flex rounded-xl bg-gray-100/80 p-1 mb-4">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            className={`
              flex-1 flex items-center justify-center gap-0.5 rounded-lg px-3 py-2 text-sm font-medium transition-all duration-150
              ${
                activeTab === tab.id
                  ? "bg-white text-gray-900 shadow-sm"
                  : "text-gray-500 hover:text-gray-700"
              }
            `}
          >
            {tab.label}
            {tab.badge}
          </button>
        ))}
      </div>

      {/* Tab content */}
      <div className="space-y-4">{contentMap[activeTab]}</div>
    </div>
  );
}
