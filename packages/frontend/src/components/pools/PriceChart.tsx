"use client";

import { useState } from "react";
import {
  AreaChart,
  Area,
  BarChart,
  Bar,
  XAxis,
  YAxis,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import { Card, CardHeader } from "@/components/ui/Card";
import {
  usePoolChartData,
  TimeRange,
  ChartPoint,
} from "@/hooks/usePoolChartData";

const TIME_RANGES: TimeRange[] = ["1H", "24H", "7D", "30D", "ALL"];

function formatTime(ts: number, range: TimeRange): string {
  const d = new Date(ts * 1000);
  if (range === "1H" || range === "24H") {
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

function formatPrice(val: number): string {
  if (val === 0) return "0";
  if (val < 0.0001) return val.toExponential(2);
  if (val < 1) return val.toPrecision(4);
  return val.toLocaleString(undefined, { maximumFractionDigits: 4 });
}

interface PriceChartProps {
  poolId: string;
  /** Which token address is the issued (non-base) token */
  issuedToken?: string;
  /** Pool token0 address */
  token0?: string;
  /** Symbol of the base token (e.g. "WETH") */
  baseSymbol?: string;
  /** Symbol of the issued token (e.g. "MEME") */
  issuedSymbol?: string;
  /** Decimals for pool token0 */
  token0Decimals?: number;
  /** Decimals for pool token1 */
  token1Decimals?: number;
}

export function PriceChart({ poolId, issuedToken, token0, baseSymbol, issuedSymbol, token0Decimals = 18, token1Decimals = 18 }: PriceChartProps) {
  const [range, setRange] = useState<TimeRange>("24H");
  const { data: chartResult, isLoading } = usePoolChartData(poolId, range);

  // Subgraph price = (sqrtPriceX96/2^96)^2 = token1_raw/token0_raw (no decimal adjustment).
  // Apply decimal correction: humanPrice = rawPrice * 10^(decimals0 - decimals1)
  const decimalAdj = 10 ** (token0Decimals - token1Decimals);

  // If issuedToken is token1, invert to show base per issued.
  const needsInvert = !!(issuedToken && token0 && issuedToken.toLowerCase() !== token0.toLowerCase());

  const rawData = chartResult?.data ?? [];
  const data = rawData.map((p) => {
    const adjusted = p.price * decimalAdj;
    return { ...p, price: needsInvert && adjusted > 0 ? 1 / adjusted : adjusted };
  });
  const currentPrice = data.length > 0 ? data[data.length - 1].price : 0;
  const firstPrice = data.length > 0 ? data[0].price : 0;
  const priceChange = firstPrice > 0 ? ((currentPrice - firstPrice) / firstPrice) * 100 : 0;
  const isUp = priceChange >= 0;
  const gradientColor = isUp ? "#10b981" : "#ef4444";
  const changeColor = isUp ? "text-emerald-600" : "text-red-500";

  const priceLabel = issuedSymbol && baseSymbol
    ? `1 ${issuedSymbol} = ${formatPrice(currentPrice)} ${baseSymbol}`
    : `Price (token1/token0)`;

  return (
    <Card>
      <CardHeader>
        <div>
          <div className="flex items-baseline gap-3">
            <span className="text-xl font-bold text-gray-900 tabular-nums">
              {formatPrice(currentPrice)}
            </span>
            {data.length > 0 && (
              <span className={`text-sm font-medium ${changeColor}`}>
                {isUp ? "+" : ""}
                {priceChange.toFixed(2)}%
              </span>
            )}
          </div>
          <p className="text-xs text-gray-400 mt-0.5">{priceLabel}</p>
        </div>
        <div className="flex gap-1">
          {TIME_RANGES.map((r) => (
            <button
              key={r}
              onClick={() => setRange(r)}
              className={`px-2.5 py-1 text-xs font-medium rounded-lg transition-colors ${
                range === r
                  ? "bg-bastion-50 text-bastion-700"
                  : "text-gray-400 hover:text-gray-600 hover:bg-gray-50"
              }`}
            >
              {r}
            </button>
          ))}
        </div>
      </CardHeader>

      {isLoading ? (
        <div className="h-[330px] flex items-center justify-center">
          <div className="h-5 w-5 animate-spin rounded-full border-2 border-gray-200 border-t-bastion-500" />
        </div>
      ) : data.length < 2 ? (
        <div className="h-[330px] flex items-center justify-center text-sm text-gray-400">
          Not enough data
        </div>
      ) : (
        <div>
          {/* Price area chart */}
          <ResponsiveContainer width="100%" height={250}>
            <AreaChart data={data} margin={{ top: 4, right: 4, bottom: 0, left: 4 }}>
              <defs>
                <linearGradient id="priceGradient" x1="0" y1="0" x2="0" y2="1">
                  <stop offset="0%" stopColor={gradientColor} stopOpacity={0.2} />
                  <stop offset="100%" stopColor={gradientColor} stopOpacity={0} />
                </linearGradient>
              </defs>
              <XAxis
                dataKey="timestamp"
                tickFormatter={(ts) => formatTime(ts, range)}
                tick={{ fontSize: 11, fill: "#9ca3af" }}
                axisLine={false}
                tickLine={false}
                minTickGap={40}
              />
              <YAxis
                domain={["auto", "auto"]}
                tickFormatter={formatPrice}
                tick={{ fontSize: 11, fill: "#9ca3af" }}
                axisLine={false}
                tickLine={false}
                width={60}
              />
              <Tooltip
                content={({ active, payload }) => {
                  if (!active || !payload?.[0]) return null;
                  const p = payload[0].payload as ChartPoint;
                  return (
                    <div className="rounded-lg bg-white shadow-lg border border-gray-100 px-3 py-2 text-xs">
                      <p className="text-gray-400">
                        {new Date(p.timestamp * 1000).toLocaleString()}
                      </p>
                      <p className="font-semibold text-gray-900 mt-0.5">
                        {formatPrice(p.price)}
                      </p>
                    </div>
                  );
                }}
              />
              <Area
                type="monotone"
                dataKey="price"
                stroke={gradientColor}
                strokeWidth={2}
                fill="url(#priceGradient)"
              />
            </AreaChart>
          </ResponsiveContainer>

          {/* Volume bar chart */}
          <ResponsiveContainer width="100%" height={80}>
            <BarChart data={data} margin={{ top: 0, right: 4, bottom: 0, left: 4 }}>
              <XAxis dataKey="timestamp" hide />
              <YAxis hide />
              <Tooltip
                content={({ active, payload }) => {
                  if (!active || !payload?.[0]) return null;
                  const p = payload[0].payload as ChartPoint;
                  return (
                    <div className="rounded-lg bg-white shadow-lg border border-gray-100 px-3 py-2 text-xs">
                      <p className="text-gray-400">Volume</p>
                      <p className="font-semibold text-gray-900 mt-0.5">
                        {p.volume.toLocaleString()}
                      </p>
                    </div>
                  );
                }}
              />
              <Bar dataKey="volume" fill={gradientColor} opacity={0.3} radius={[2, 2, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>
      )}
    </Card>
  );
}
