"use client";

import { Card, CardHeader } from "@/components/ui/Card";
import { shortenAddress, explorerUrl, formatBps, formatDuration } from "@/lib/formatters";

interface IssuerInfoProps {
  issuer: {
    id: string;
    reputationScore: string;
    totalEscrowsCreated?: number;
    totalEscrowsCompleted?: number;
    totalTriggersActivated?: number;
  };
  commitment?: {
    dailyWithdrawLimit: string;
    lockDuration: string;
    maxSellPercent: string;
  } | null;
}

export function IssuerInfo({ issuer, commitment }: IssuerInfoProps) {
  const score = parseInt(issuer.reputationScore);
  const scoreColor =
    score >= 80 ? "text-emerald-400" : score >= 50 ? "text-yellow-400" : "text-red-400";
  const scorePercent = Math.min(score / 10, 100); // score out of 1000 → %

  return (
    <Card>
      <CardHeader>
        <h3 className="text-lg font-semibold">Issuer</h3>
      </CardHeader>

      <div className="mb-4">
        <a
          href={explorerUrl(issuer.id)}
          target="_blank"
          rel="noopener noreferrer"
          className="text-bastion-400 hover:underline text-sm"
        >
          {shortenAddress(issuer.id)}
          <span className="ml-1 text-gray-600">&#8599;</span>
        </a>
      </div>

      {/* Reputation Gauge */}
      <div className="mb-4">
        <div className="flex items-center justify-between mb-1">
          <span className="text-xs text-gray-500">Reputation Score</span>
          <span className={`text-sm font-semibold ${scoreColor}`}>
            {score}
          </span>
        </div>
        <div className="h-2 rounded-full bg-gray-800">
          <div
            className={`h-full rounded-full ${
              score >= 80
                ? "bg-emerald-500"
                : score >= 50
                  ? "bg-yellow-500"
                  : "bg-red-500"
            }`}
            style={{ width: `${scorePercent}%` }}
          />
        </div>
      </div>

      {/* History */}
      <div className="grid grid-cols-3 gap-3 mb-4">
        <div className="rounded-lg bg-gray-800 p-3 text-center">
          <p className="text-lg font-semibold">
            {issuer.totalEscrowsCreated ?? 0}
          </p>
          <p className="text-xs text-gray-500">Created</p>
        </div>
        <div className="rounded-lg bg-gray-800 p-3 text-center">
          <p className="text-lg font-semibold text-emerald-400">
            {issuer.totalEscrowsCompleted ?? 0}
          </p>
          <p className="text-xs text-gray-500">Completed</p>
        </div>
        <div className="rounded-lg bg-gray-800 p-3 text-center">
          <p className="text-lg font-semibold text-red-400">
            {issuer.totalTriggersActivated ?? 0}
          </p>
          <p className="text-xs text-gray-500">Triggers</p>
        </div>
      </div>

      {/* Commitment Parameters */}
      {commitment && (
        <div>
          <p className="text-xs text-gray-500 mb-2">Commitment Parameters</p>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-400">Daily Withdraw Limit</span>
              <span>{formatBps(parseInt(commitment.dailyWithdrawLimit))}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Lock Duration</span>
              <span>{formatDuration(parseInt(commitment.lockDuration))}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-gray-400">Max Sell / 24h</span>
              <span>{formatBps(parseInt(commitment.maxSellPercent))}</span>
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}
