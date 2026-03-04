"use client";

interface BadgeProps {
  variant: "protected" | "standard" | "triggered" | "pending" | "info";
  children: React.ReactNode;
}

const ShieldIcon = () => (
  <svg className="h-3 w-3" viewBox="0 0 16 16" fill="currentColor">
    <path d="M8 0L1 3v5c0 4.17 2.99 8.06 7 9 4.01-.94 7-4.83 7-9V3L8 0zm0 2.18l5 2.14v3.68c0 3.25-2.22 6.3-5 7.14-2.78-.84-5-3.89-5-7.14V4.32l5-2.14z" />
    <path d="M7 10.5l-2.5-2.5 1.06-1.06L7 8.38l3.44-3.44L11.5 6 7 10.5z" />
  </svg>
);

const variants = {
  protected:
    "bg-emerald-500/15 text-emerald-400 border-emerald-500/25 shadow-[0_0_8px_rgba(16,185,129,0.1)]",
  standard: "bg-gray-500/15 text-gray-400 border-gray-500/25",
  triggered:
    "bg-red-500/15 text-red-400 border-red-500/25 shadow-[0_0_8px_rgba(239,68,68,0.1)]",
  pending:
    "bg-amber-500/15 text-amber-400 border-amber-500/25 shadow-[0_0_8px_rgba(245,158,11,0.1)]",
  info: "bg-bastion-500/15 text-bastion-300 border-bastion-500/25",
};

export function Badge({ variant, children }: BadgeProps) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium ${variants[variant]}`}
    >
      {variant === "protected" && <ShieldIcon />}
      {children}
    </span>
  );
}
