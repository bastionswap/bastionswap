"use client";

import { Card, CardHeader } from "@/components/ui/Card";
import { Badge } from "@/components/ui/Badge";
import { timeUntil, formatDuration, formatBps } from "@/lib/formatters";

interface EscrowStatusProps {
  escrow: {
    totalLocked: string;
    released: string;
    remaining: string;
    isTriggered: boolean;
    createdAt?: string;
    commitment?: {
      dailyWithdrawLimit: string;
      lockDuration: string;
      maxSellPercent: string;
    } | null;
    vestingSchedule?: {
      id: string;
      timestamp: string;
      basisPoints: number;
    }[];
  };
}

export function EscrowStatus({ escrow }: EscrowStatusProps) {
  const total = parseFloat(escrow.totalLocked);
  const released = parseFloat(escrow.released);
  const remaining = parseFloat(escrow.remaining);
  const progress = total > 0 ? (released / total) * 100 : 0;

  const now = Math.floor(Date.now() / 1000);
  const nextMilestone = escrow.vestingSchedule
    ?.filter((m) => parseInt(m.timestamp) > now)
    .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp))[0];

  return (
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Escrow Status</h3>
        {escrow.isTriggered ? (
          <Badge variant="triggered">TRIGGERED</Badge>
        ) : (
          <Badge variant="protected">Active</Badge>
        )}
      </CardHeader>

      {escrow.isTriggered && (
        <div className="mb-4 rounded-lg bg-red-500/10 border border-red-500/20 px-4 py-3 text-sm text-red-400">
          A trigger has been activated. Escrowed funds have been
          redistributed to protect holders.
        </div>
      )}

      <div className="grid grid-cols-3 gap-4 mb-4">
        <div>
          <p className="text-xs text-gray-500">Total Locked</p>
          <p className="text-lg font-semibold">{total.toFixed(4)}</p>
        </div>
        <div>
          <p className="text-xs text-gray-500">Released</p>
          <p className="text-lg font-semibold text-emerald-400">
            {released.toFixed(4)}
          </p>
        </div>
        <div>
          <p className="text-xs text-gray-500">Remaining</p>
          <p className="text-lg font-semibold text-bastion-400">
            {remaining.toFixed(4)}
          </p>
        </div>
      </div>

      {/* Progress Bar */}
      <div className="mb-2">
        <div className="flex items-center justify-between text-xs text-gray-500 mb-1">
          <span>Vesting Progress</span>
          <span>{progress.toFixed(1)}%</span>
        </div>
        <div className="h-2 rounded-full bg-gray-800">
          <div
            className={`h-full rounded-full transition-all ${
              escrow.isTriggered ? "bg-red-500" : "bg-emerald-500"
            }`}
            style={{ width: `${Math.min(progress, 100)}%` }}
          />
        </div>
      </div>

      {nextMilestone && !escrow.isTriggered && (
        <p className="text-xs text-gray-500">
          Next unlock: {timeUntil(parseInt(nextMilestone.timestamp))} (
          {formatBps(nextMilestone.basisPoints)} cumulative)
        </p>
      )}

      {/* Vesting Schedule Timeline */}
      {escrow.vestingSchedule && escrow.vestingSchedule.length > 0 && (
        <div className="mt-4">
          <p className="text-xs text-gray-500 mb-2">Vesting Schedule</p>
          <div className="space-y-2">
            {escrow.vestingSchedule
              .sort((a, b) => parseInt(a.timestamp) - parseInt(b.timestamp))
              .map((milestone, i) => {
                const ts = parseInt(milestone.timestamp);
                const isPast = ts <= now;
                return (
                  <div key={milestone.id} className="flex items-center gap-3">
                    <div
                      className={`h-2 w-2 rounded-full ${
                        isPast ? "bg-emerald-500" : "bg-gray-600"
                      }`}
                    />
                    <span className="text-xs text-gray-400 w-24">
                      {new Date(ts * 1000).toLocaleDateString()}
                    </span>
                    <span className="text-xs font-medium">
                      {formatBps(milestone.basisPoints)}
                    </span>
                  </div>
                );
              })}
          </div>
        </div>
      )}
    </Card>
  );
}
