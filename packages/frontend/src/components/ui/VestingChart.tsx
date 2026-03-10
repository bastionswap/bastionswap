"use client";

interface VestingChartProps {
  /** Lock duration in days (0% removable during this period) */
  lockDays: number;
  /** Vesting duration in days (linear from 0% to 100% after lock) */
  vestingDays: number;
  /** Optional default lock days to overlay as comparison (dashed line) */
  defaultLockDays?: number;
  /** Optional default vesting days to overlay as comparison (dashed line) */
  defaultVestingDays?: number;
  /** Chart height in px */
  height?: number;
  /** Label for the current schedule */
  label?: string;
  /** Label for the default schedule */
  defaultLabel?: string;
}

// Chart layout constants
const PAD_LEFT = 44;
const PAD_RIGHT = 16;
const PAD_TOP = 16;
const PAD_BOTTOM = 32;

function buildLinearPath(
  lockDays: number,
  vestingDays: number,
  maxDays: number,
  chartW: number,
  chartH: number,
): string {
  const totalDays = lockDays + vestingDays;
  if (totalDays === 0) return "";

  const toX = (d: number) => PAD_LEFT + (d / maxDays) * chartW;
  const toY = (bps: number) => PAD_TOP + chartH - (bps / 10000) * chartH;

  // Start at origin (day 0, 0%)
  let path = `M ${toX(0)} ${toY(0)}`;

  // Flat at 0% through lock period
  path += ` L ${toX(lockDays)} ${toY(0)}`;

  // Linear ramp from 0% to 100% over vesting period
  const endDay = Math.min(totalDays, maxDays);
  path += ` L ${toX(endDay)} ${toY(10000)}`;

  // Extend horizontally if totalDays < maxDays
  if (totalDays < maxDays) {
    path += ` H ${toX(maxDays)}`;
  }

  return path;
}

export function VestingChart({
  lockDays,
  vestingDays,
  defaultLockDays,
  defaultVestingDays,
  height = 180,
  label = "Custom",
  defaultLabel = "Default (90d)",
}: VestingChartProps) {
  const WIDTH = 400; // viewBox width, scales responsively
  const chartW = WIDTH - PAD_LEFT - PAD_RIGHT;
  const chartH = height - PAD_TOP - PAD_BOTTOM;

  const totalDays = lockDays + vestingDays;
  const defaultTotalDays = (defaultLockDays ?? 0) + (defaultVestingDays ?? 0);

  // Determine max days for the x-axis
  const rawMax = Math.max(totalDays, defaultTotalDays, 7);
  const maxDays = rawMax <= 30 ? 30 : rawMax <= 90 ? 90 : rawMax <= 180 ? 180 : rawMax <= 365 ? 365 : Math.ceil(rawMax / 30) * 30;

  const toX = (d: number) => PAD_LEFT + (d / maxDays) * chartW;
  const toY = (bps: number) => PAD_TOP + chartH - (bps / 10000) * chartH;

  // Y-axis ticks
  const yTicks = [0, 2500, 5000, 7500, 10000];
  // X-axis ticks
  const xTicks: number[] = [];
  if (maxDays <= 30) {
    for (let d = 0; d <= maxDays; d += 7) xTicks.push(d);
    if (xTicks[xTicks.length - 1] !== maxDays) xTicks.push(maxDays);
  } else if (maxDays <= 90) {
    for (let d = 0; d <= maxDays; d += 30) xTicks.push(d);
    if (xTicks[xTicks.length - 1] !== maxDays) xTicks.push(maxDays);
  } else {
    for (let d = 0; d <= maxDays; d += 30) xTicks.push(d);
    if (xTicks[xTicks.length - 1] !== maxDays) xTicks.push(maxDays);
    if (xTicks.length > 7) {
      const step = Math.ceil(maxDays / 5 / 30) * 30;
      xTicks.length = 0;
      for (let d = 0; d <= maxDays; d += step) xTicks.push(d);
      if (xTicks[xTicks.length - 1] !== maxDays) xTicks.push(maxDays);
    }
  }

  const currentPath = buildLinearPath(lockDays, vestingDays, maxDays, chartW, chartH);
  const defaultPath = defaultLockDays !== undefined && defaultVestingDays !== undefined
    ? buildLinearPath(defaultLockDays, defaultVestingDays, maxDays, chartW, chartH)
    : "";

  // Fill area under current schedule
  const fillPath = currentPath
    ? `${currentPath} V ${toY(0)} H ${toX(0)} Z`
    : "";

  const showLegend = !!defaultPath;
  const showLock = lockDays > 0;

  return (
    <div className="w-full">
      <svg
        viewBox={`0 0 ${WIDTH} ${height}`}
        className="w-full"
        preserveAspectRatio="xMidYMid meet"
      >
        {/* Grid lines */}
        {yTicks.map((bps) => (
          <line
            key={`y-${bps}`}
            x1={PAD_LEFT}
            x2={WIDTH - PAD_RIGHT}
            y1={toY(bps)}
            y2={toY(bps)}
            stroke="#e5e7eb"
            strokeWidth={0.5}
          />
        ))}

        {/* Lock period shading */}
        {showLock && (
          <rect
            x={toX(0)}
            y={PAD_TOP}
            width={toX(lockDays) - toX(0)}
            height={chartH}
            fill="#f59e0b"
            opacity={0.08}
          />
        )}

        {/* Lock period boundary line */}
        {showLock && (
          <line
            x1={toX(lockDays)}
            x2={toX(lockDays)}
            y1={PAD_TOP}
            y2={PAD_TOP + chartH}
            stroke="#f59e0b"
            strokeWidth={1}
            strokeDasharray="3 2"
          />
        )}

        {/* Lock label */}
        {showLock && lockDays / maxDays > 0.08 && (
          <text
            x={(toX(0) + toX(lockDays)) / 2}
            y={PAD_TOP + 12}
            textAnchor="middle"
            className="fill-amber-500"
            fontSize={8}
            fontWeight={600}
          >
            LOCK
          </text>
        )}

        {/* Y-axis labels */}
        {yTicks.map((bps) => (
          <text
            key={`yl-${bps}`}
            x={PAD_LEFT - 6}
            y={toY(bps) + 3.5}
            textAnchor="end"
            className="fill-gray-400"
            fontSize={9}
          >
            {bps / 100}%
          </text>
        ))}

        {/* X-axis labels */}
        {xTicks.map((d) => (
          <text
            key={`xl-${d}`}
            x={toX(d)}
            y={height - 6}
            textAnchor="middle"
            className="fill-gray-400"
            fontSize={9}
          >
            {d}d
          </text>
        ))}

        {/* Fill under current schedule */}
        {fillPath && (
          <path
            d={fillPath}
            fill="url(#vestingGradient)"
            opacity={0.15}
          />
        )}

        {/* Default schedule (dashed) */}
        {defaultPath && (
          <path
            d={defaultPath}
            fill="none"
            stroke="#9ca3af"
            strokeWidth={1.5}
            strokeDasharray="4 3"
          />
        )}

        {/* Current schedule (solid) */}
        {currentPath && (
          <path
            d={currentPath}
            fill="none"
            stroke="#B45309"
            strokeWidth={2}
          />
        )}

        {/* Key points on current schedule */}
        {/* Lock end point */}
        <circle
          cx={toX(lockDays)}
          cy={toY(0)}
          r={3.5}
          fill="white"
          stroke="#B45309"
          strokeWidth={2}
        />
        {/* Vesting end point (100%) */}
        <circle
          cx={toX(totalDays)}
          cy={toY(10000)}
          r={3.5}
          fill="white"
          stroke="#B45309"
          strokeWidth={2}
        />

        {/* Gradient definition */}
        <defs>
          <linearGradient id="vestingGradient" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#B45309" />
            <stop offset="100%" stopColor="#B45309" stopOpacity={0} />
          </linearGradient>
        </defs>
      </svg>

      {/* Legend */}
      {(showLegend || showLock) && (
        <div className="flex items-center justify-center gap-5 mt-1 flex-wrap">
          <div className="flex items-center gap-1.5">
            <div className="h-0.5 w-5 bg-bastion-700 rounded" />
            <span className="text-[11px] text-gray-600">{label}</span>
          </div>
          {showLegend && (
            <div className="flex items-center gap-1.5">
              <div className="h-0.5 w-5 rounded" style={{ backgroundImage: "repeating-linear-gradient(90deg, #9ca3af 0, #9ca3af 4px, transparent 4px, transparent 7px)" }} />
              <span className="text-[11px] text-gray-400">{defaultLabel}</span>
            </div>
          )}
          {showLock && (
            <div className="flex items-center gap-1.5">
              <div className="h-3 w-5 rounded-sm bg-amber-500/20 border border-amber-400/40" />
              <span className="text-[11px] text-amber-600">Lock ({lockDays}d)</span>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
