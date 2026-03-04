"use client";

import { ReactNode } from "react";

interface CardProps {
  children: ReactNode;
  className?: string;
  onClick?: () => void;
  glow?: "emerald" | "red" | "amber" | "none";
}

const glowStyles = {
  emerald: "hover:shadow-[0_0_20px_rgba(16,185,129,0.08)] hover:border-emerald-500/20",
  red: "border-red-500/20 shadow-[0_0_20px_rgba(239,68,68,0.06)]",
  amber: "border-amber-500/20 shadow-[0_0_20px_rgba(245,158,11,0.06)]",
  none: "",
};

export function Card({ children, className = "", onClick, glow = "none" }: CardProps) {
  return (
    <div
      className={`glass-card p-6 ${onClick ? "cursor-pointer hover:border-gray-600 transition-all duration-200" : ""} ${glowStyles[glow]} ${className}`}
      onClick={onClick}
    >
      {children}
    </div>
  );
}

export function CardHeader({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`mb-4 flex items-center justify-between ${className}`}>
      {children}
    </div>
  );
}
