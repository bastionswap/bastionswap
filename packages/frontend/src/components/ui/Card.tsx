"use client";

import { ReactNode } from "react";

interface CardProps {
  children: ReactNode;
  className?: string;
  onClick?: () => void;
  glow?: "emerald" | "red" | "amber" | "none";
}

const glowStyles = {
  emerald: "hover:shadow-[0_2px_12px_rgba(5,150,105,0.1)] border-emerald-200",
  red: "border-red-200 shadow-[0_2px_12px_rgba(239,68,68,0.08)]",
  amber: "border-amber-200 shadow-[0_2px_12px_rgba(245,158,11,0.08)]",
  none: "",
};

export function Card({ children, className = "", onClick, glow = "none" }: CardProps) {
  return (
    <div
      className={`glass-card p-6 ${onClick ? "cursor-pointer hover:shadow-card-hover transition-all duration-200" : ""} ${glowStyles[glow]} ${className}`}
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
