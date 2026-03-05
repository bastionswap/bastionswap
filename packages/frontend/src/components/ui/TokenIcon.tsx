"use client";

interface TokenIconProps {
  address: string;
  size?: number;
  className?: string;
}

export function TokenIcon({ address, size = 32, className = "" }: TokenIconProps) {
  const hash = address.slice(2, 8);
  const hue = parseInt(hash, 16) % 360;
  const satHash = parseInt(address.slice(8, 10), 16);
  const sat = 50 + (satHash % 20);

  return (
    <div
      className={`rounded-full flex items-center justify-center text-white font-bold ring-2 ring-white shadow-sm ${className}`}
      style={{
        width: size,
        height: size,
        background: `linear-gradient(135deg, hsl(${hue}, ${sat}%, 55%), hsl(${(hue + 40) % 360}, ${sat}%, 45%))`,
        fontSize: size * 0.35,
      }}
    >
      {address.slice(2, 4).toUpperCase()}
    </div>
  );
}
