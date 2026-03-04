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

export function TriggerHistory({ events }: TriggerHistoryProps) {
  if (events.length === 0) return null;

  return (
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Trigger History</h3>
        <Badge variant="triggered">{events.length} events</Badge>
      </CardHeader>

      <div className="space-y-3">
        {events.map((event) => (
          <div
            key={event.id}
            className="flex items-center justify-between rounded-lg bg-gray-800 px-4 py-3"
          >
            <div>
              <p className="text-sm font-medium">{event.triggerTypeName}</p>
              <p className="text-xs text-gray-500">
                {new Date(parseInt(event.timestamp) * 1000).toLocaleString()}
              </p>
            </div>
            <div className="flex items-center gap-2">
              {event.withMerkleRoot && (
                <Badge variant="info">Merkle</Badge>
              )}
              <a
                href={explorerUrl(event.transactionHash, "tx")}
                target="_blank"
                rel="noopener noreferrer"
                className="text-xs text-bastion-400 hover:underline"
              >
                {shortenAddress(event.transactionHash, 4)}
              </a>
            </div>
          </div>
        ))}
      </div>
    </Card>
  );
}
