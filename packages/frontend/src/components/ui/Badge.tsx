"use client";

interface BadgeProps {
  variant: "protected" | "standard" | "triggered" | "info";
  children: React.ReactNode;
}

const variants = {
  protected:
    "bg-emerald-500/20 text-emerald-400 border-emerald-500/30",
  standard: "bg-gray-500/20 text-gray-400 border-gray-500/30",
  triggered: "bg-red-500/20 text-red-400 border-red-500/30",
  info: "bg-blue-500/20 text-blue-400 border-blue-500/30",
};

export function Badge({ variant, children }: BadgeProps) {
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full border px-2.5 py-0.5 text-xs font-medium ${variants[variant]}`}
    >
      {children}
    </span>
  );
}
