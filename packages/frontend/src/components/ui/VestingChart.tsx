"use client";

interface Milestone {
  days: number;
  bps: number; // basis points, 10000 = 100%
}

interface VestingChartProps {
  /** Current vesting schedule milestones */
  milestones: Milestone[];
  /** Optional default schedule to overlay as comparison (dashed line) */
  defaultMilestones?: Milestone[];
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

function buildStepPath(
  milestones: Milestone[],
  maxDays: number,
  chartW: number,
  chartH: number,
): string {
  if (milestones.length === 0) return "";

  const toX = (d: number) => PAD_LEFT + (d / maxDays) * chartW;
  const toY = (bps: number) => PAD_TOP + chartH - (bps / 10000) * chartH;

  // Start at origin (day 0, 0%)
  let path = `M ${toX(0)} ${toY(0)}`;

  for (const m of milestones) {
    // Horizontal to the milestone day at previous bps level
    const prevY = path.match(/[\d.]+$/); // last Y
    path += ` H ${toX(m.days)}`;
    // Vertical jump to new bps level
    path += ` V ${toY(m.bps)}`;
  }

  // Extend horizontally to the end if last milestone doesn't reach maxDays
  const lastM = milestones[milestones.length - 1];
  if (lastM.days < maxDays) {
    path += ` H ${toX(maxDays)}`;
  }

  return path;
}

export function VestingChart({
  milestones,
  defaultMilestones,
  height = 180,
  label = "Custom",
  defaultLabel = "Default (90d)",
}: VestingChartProps) {
  const WIDTH = 400; // viewBox width, scales responsively
  const chartW = WIDTH - PAD_LEFT - PAD_RIGHT;
  const chartH = height - PAD_TOP - PAD_BOTTOM;

  // Determine max days for the x-axis
  const allDays = [
    ...milestones.map((m) => m.days),
    ...(defaultMilestones?.map((m) => m.days) ?? []),
  ];
  const rawMax = Math.max(...allDays, 7);
  // Round up to a nice number
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
    // Limit to ~6 ticks
    if (xTicks.length > 7) {
      const step = Math.ceil(maxDays / 5 / 30) * 30;
      xTicks.length = 0;
      for (let d = 0; d <= maxDays; d += step) xTicks.push(d);
      if (xTicks[xTicks.length - 1] !== maxDays) xTicks.push(maxDays);
    }
  }

  const currentPath = buildStepPath(milestones, maxDays, chartW, chartH);
  const defaultPath = defaultMilestones
    ? buildStepPath(defaultMilestones, maxDays, chartW, chartH)
    : "";

  // Fill area under current schedule
  const fillPath = currentPath
    ? `${currentPath} V ${toY(0)} H ${toX(0)} Z`
    : "";

  const showLegend = !!defaultMilestones && defaultMilestones.length > 0;

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
            stroke="#6d28d9"
            strokeWidth={2}
          />
        )}

        {/* Milestone dots on current schedule */}
        {milestones.map((m, i) => (
          <circle
            key={i}
            cx={toX(m.days)}
            cy={toY(m.bps)}
            r={3.5}
            fill="white"
            stroke="#6d28d9"
            strokeWidth={2}
          />
        ))}

        {/* Default milestone dots */}
        {defaultMilestones?.map((m, i) => (
          <circle
            key={`d-${i}`}
            cx={toX(m.days)}
            cy={toY(m.bps)}
            r={2.5}
            fill="white"
            stroke="#9ca3af"
            strokeWidth={1.5}
          />
        ))}

        {/* Gradient definition */}
        <defs>
          <linearGradient id="vestingGradient" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor="#6d28d9" />
            <stop offset="100%" stopColor="#6d28d9" stopOpacity={0} />
          </linearGradient>
        </defs>
      </svg>

      {/* Legend */}
      {showLegend && (
        <div className="flex items-center justify-center gap-5 mt-1">
          <div className="flex items-center gap-1.5">
            <div className="h-0.5 w-5 bg-violet-700 rounded" />
            <span className="text-[11px] text-gray-600">{label}</span>
          </div>
          <div className="flex items-center gap-1.5">
            <div className="h-0.5 w-5 bg-gray-400 rounded" style={{ backgroundImage: "repeating-linear-gradient(90deg, #9ca3af 0, #9ca3af 4px, transparent 4px, transparent 7px)" }} />
            <span className="text-[11px] text-gray-400">{defaultLabel}</span>
          </div>
        </div>
      )}
    </div>
  );
}
