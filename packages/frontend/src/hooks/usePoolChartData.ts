"use client";

import { useQuery } from "@tanstack/react-query";
import { gql } from "graphql-request";
import { graphClient } from "@/config/subgraph";

export type TimeRange = "1H" | "24H" | "7D" | "30D" | "ALL";

export interface ChartPoint {
  timestamp: number;
  price: number;
  volume: number;
}

const POOL_HOUR_DATA_QUERY = gql`
  query PoolHourData($poolId: String!, $startTime: Int!) {
    poolHourDatas(
      where: { pool: $poolId, hourStartUnix_gte: $startTime }
      orderBy: hourStartUnix
      orderDirection: asc
      first: 1000
    ) {
      hourStartUnix
      open
      close
      high
      low
      volumeToken0
      txCount
    }
  }
`;

const POOL_DAY_DATA_QUERY = gql`
  query PoolDayData($poolId: String!, $startTime: Int!) {
    poolDayDatas(
      where: { pool: $poolId, dayStartUnix_gte: $startTime }
      orderBy: dayStartUnix
      orderDirection: asc
      first: 1000
    ) {
      dayStartUnix
      open
      close
      high
      low
      volumeToken0
      txCount
    }
  }
`;

function getStartTime(range: TimeRange): number {
  const now = Math.floor(Date.now() / 1000);
  switch (range) {
    case "1H":
      return now - 3600;
    case "24H":
      return now - 86400;
    case "7D":
      return now - 7 * 86400;
    case "30D":
      return now - 30 * 86400;
    case "ALL":
      return 0;
  }
}

function useHourly(range: TimeRange): boolean {
  return range === "1H" || range === "24H" || range === "7D";
}

interface HourDataResponse {
  poolHourDatas: Array<{
    hourStartUnix: number;
    open: string;
    close: string;
    high: string;
    low: string;
    volumeToken0: string;
    txCount: number;
  }>;
}

interface DayDataResponse {
  poolDayDatas: Array<{
    dayStartUnix: number;
    open: string;
    close: string;
    high: string;
    low: string;
    volumeToken0: string;
    txCount: number;
  }>;
}

export function usePoolChartData(poolId: string | undefined, range: TimeRange) {
  const startTime = getStartTime(range);
  const hourly = useHourly(range);

  return useQuery({
    queryKey: ["poolChartData", poolId, range],
    queryFn: async () => {
      if (!poolId) return null;

      if (hourly) {
        const res = await graphClient.request<HourDataResponse>(
          POOL_HOUR_DATA_QUERY,
          { poolId, startTime }
        );
        const points: ChartPoint[] = res.poolHourDatas.map((d) => ({
          timestamp: d.hourStartUnix,
          price: parseFloat(d.close),
          volume: parseFloat(d.volumeToken0),
        }));
        return buildResult(points);
      } else {
        const res = await graphClient.request<DayDataResponse>(
          POOL_DAY_DATA_QUERY,
          { poolId, startTime }
        );
        const points: ChartPoint[] = res.poolDayDatas.map((d) => ({
          timestamp: d.dayStartUnix,
          price: parseFloat(d.close),
          volume: parseFloat(d.volumeToken0),
        }));
        return buildResult(points);
      }
    },
    enabled: !!poolId,
    refetchInterval: 60_000,
  });
}

function buildResult(data: ChartPoint[]) {
  if (data.length === 0) {
    return { data: [], currentPrice: 0, priceChange24h: 0 };
  }
  const currentPrice = data[data.length - 1].price;
  const firstPrice = data[0].price;
  const priceChange24h =
    firstPrice > 0 ? ((currentPrice - firstPrice) / firstPrice) * 100 : 0;
  return { data, currentPrice, priceChange24h };
}
