"use client";

interface TokenIconProps {
  address: string;
  size?: number;
  className?: string;
}

export function TokenIcon({ address, size = 32, className = "" }: TokenIconProps) {
  // Generate a deterministic color from the address
  const hash = address.slice(2, 8);
  const hue = parseInt(hash, 16) % 360;

  return (
    <div
      className={`rounded-full flex items-center justify-center text-white font-bold ${className}`}
      style={{
        width: size,
        height: size,
        backgroundColor: `hsl(${hue}, 60%, 40%)`,
        fontSize: size * 0.4,
      }}
    >
      {address.slice(2, 4).toUpperCase()}
    </div>
  );
}
