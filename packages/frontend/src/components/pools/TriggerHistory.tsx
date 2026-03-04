"use client";

import { Card, CardHeader } from "@/components/ui/Card";
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

const TRIGGER_ICONS: Record<number, string> = {
  1: "\u{1F6A8}", // RUG_PULL
  2: "\u{1F4C9}", // ISSUER_DUMP
  3: "\u{1F36F}", // HONEYPOT
  4: "\u{1F4B8}", // HIDDEN_TAX
  5: "\u{23F3}",  // SLOW_RUG
  6: "\u{1F6AB}", // COMMITMENT_BREACH
};

export function TriggerHistory({ events }: TriggerHistoryProps) {
  if (events.length === 0) return null;

  return (
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Trigger History</h3>
        <Badge variant="triggered">{events.length}</Badge>
      </CardHeader>

      <div className="space-y-2">
        {events.map((event) => (
          <div
            key={event.id}
            className="flex items-center justify-between rounded-xl bg-surface-light px-4 py-3"
          >
            <div className="flex items-center gap-3">
              <span className="text-lg">{TRIGGER_ICONS[event.triggerType] || "\u26A0\uFE0F"}</span>
              <div>
                <p className="text-sm font-medium">{event.triggerTypeName}</p>
                <p className="text-xs text-gray-500">
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
                className="text-xs text-bastion-300 hover:text-bastion-200 transition-colors"
              >
                {shortenAddress(event.transactionHash, 4)} &#8599;
              </a>
            </div>
          </div>
        ))}
      </div>
    </Card>
  );
}
