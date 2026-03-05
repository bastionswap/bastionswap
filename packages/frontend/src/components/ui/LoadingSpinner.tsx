"use client";

export function LoadingSpinner({ size = "md" }: { size?: "sm" | "md" | "lg" }) {
  const sizeClass = {
    sm: "h-4 w-4",
    md: "h-8 w-8",
    lg: "h-12 w-12",
  }[size];

  return (
    <div className="flex items-center justify-center">
      <div
        className={`${sizeClass} animate-spin rounded-full border-2 border-gray-200 border-t-bastion-600`}
      />
    </div>
  );
}

export function Skeleton({
  className = "",
  lines = 1,
}: {
  className?: string;
  lines?: number;
}) {
  return (
    <div className={`space-y-2 ${className}`}>
      {Array.from({ length: lines }).map((_, i) => (
        <div
          key={i}
          className="skeleton h-4 rounded"
          style={{ width: i === lines - 1 && lines > 1 ? "60%" : "100%" }}
        />
      ))}
    </div>
  );
}

export function SkeletonCard() {
  return (
    <div className="glass-card p-6 space-y-4">
      <div className="flex items-center gap-3">
        <div className="skeleton h-10 w-10 rounded-full" />
        <div className="flex-1 space-y-2">
          <div className="skeleton h-4 w-32 rounded" />
          <div className="skeleton h-3 w-20 rounded" />
        </div>
      </div>
      <div className="grid grid-cols-3 gap-4">
        <div className="space-y-1">
          <div className="skeleton h-3 w-16 rounded" />
          <div className="skeleton h-5 w-20 rounded" />
        </div>
        <div className="space-y-1">
          <div className="skeleton h-3 w-16 rounded" />
          <div className="skeleton h-5 w-20 rounded" />
        </div>
        <div className="space-y-1">
          <div className="skeleton h-3 w-16 rounded" />
          <div className="skeleton h-5 w-20 rounded" />
        </div>
      </div>
    </div>
  );
}
