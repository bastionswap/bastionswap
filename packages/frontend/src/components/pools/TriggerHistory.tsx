"use client";

import { Badge } from "@/components/ui/Badge";
import { shortenAddress, explorerUrl } from "@/lib/formatters";

interface TriggerHistoryProps {
  events: {
    id: string;
    triggerType: number;
    triggerTypeName: string;
    timestamp: string;
    transactionHash: string;
    withMerkleRoot: boolean;
  }[];
}

const TRIGGER_ICONS: Record<number, { icon: string; color: string; bg: string }> = {
  1: { icon: "M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z", color: "text-red-600", bg: "bg-red-100" },
  2: { icon: "M2.25 6L9 12.75l4.286-4.286a11.948 11.948 0 014.306 6.43l.776 2.898m0 0l3.182-5.511m-3.182 5.51l-5.511-3.181", color: "text-amber-600", bg: "bg-amber-100" },
  3: { icon: "M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636", color: "text-red-600", bg: "bg-red-100" },
  4: { icon: "M12 6v12m-3-2.818l.879.659c1.171.879 3.07.879 4.242 0 1.172-.879 1.172-2.303 0-3.182C13.536 12.219 12.768 12 12 12c-.725 0-1.45-.22-2.003-.659-1.106-.879-1.106-2.303 0-3.182s2.9-.879 4.006 0l.415.33M21 12a9 9 0 11-18 0 9 9 0 0118 0z", color: "text-amber-600", bg: "bg-amber-100" },
  5: { icon: "M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z", color: "text-amber-600", bg: "bg-amber-100" },
  6: { icon: "M16.5 10.5V6.75a4.5 4.5 0 10-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 002.25-2.25v-6.75a2.25 2.25 0 00-2.25-2.25H6.75a2.25 2.25 0 00-2.25 2.25v6.75a2.25 2.25 0 002.25 2.25z", color: "text-red-600", bg: "bg-red-100" },
};

const DEFAULT_ICON = { icon: "M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z", color: "text-gray-600", bg: "bg-gray-100" };

export function TriggerHistory({ events }: TriggerHistoryProps) {
  if (events.length === 0) return null;

  return (
    <div className="glass-card p-0 overflow-hidden">
      <div className="px-6 pt-5 pb-4 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-red-100">
            <svg className="h-5 w-5 text-red-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z" />
            </svg>
          </div>
          <div>
            <h3 className="text-base font-semibold text-gray-900">Trigger History</h3>
            <p className="text-xs text-gray-400">{events.length} event{events.length !== 1 ? "s" : ""} recorded</p>
          </div>
        </div>
        <Badge variant="triggered">{events.length}</Badge>
      </div>

      <div className="px-6 pb-5 space-y-2">
        {events.map((event) => {
          const triggerStyle = TRIGGER_ICONS[event.triggerType] || DEFAULT_ICON;
          return (
            <div
              key={event.id}
              className="flex items-center justify-between rounded-xl bg-gray-50 px-4 py-3"
            >
              <div className="flex items-center gap-3">
                <div className={`flex h-8 w-8 items-center justify-center rounded-lg ${triggerStyle.bg}`}>
                  <svg className={`h-4 w-4 ${triggerStyle.color}`} fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d={triggerStyle.icon} />
                  </svg>
                </div>
                <div>
                  <p className="text-sm font-medium text-gray-900">{event.triggerTypeName}</p>
                  <p className="text-xs text-gray-400">
                    {new Date(parseInt(event.timestamp) * 1000).toLocaleString()}
                  </p>
                </div>
              </div>
              <div className="flex items-center gap-2">
                {event.withMerkleRoot && (
                  <Badge variant="info">Merkle</Badge>
                )}
                <a
                  href={explorerUrl(event.transactionHash, "tx")}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-flex items-center gap-1 text-xs text-bastion-600 hover:text-bastion-700 transition-colors"
                >
                  {shortenAddress(event.transactionHash, 4)}
                  <svg className="h-3 w-3" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={2}>
                    <path strokeLinecap="round" strokeLinejoin="round" d="M13.5 6H5.25A2.25 2.25 0 003 8.25v10.5A2.25 2.25 0 005.25 21h10.5A2.25 2.25 0 0018 18.75V10.5m-10.5 6L21 3m0 0h-5.25M21 3v5.25" />
                  </svg>
                </a>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
