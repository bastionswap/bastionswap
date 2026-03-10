import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  theme: {
    extend: {
      colors: {
        bastion: {
          50: "#FFFBEB",
          100: "#FEF3C7",
          200: "#FDE68A",
          300: "#FCD34D",
          400: "#FBBF24",
          500: "#F59E0B",
          600: "#D97706",
          700: "#B45309",
          800: "#92400E",
          900: "#78350F",
        },
        surface: {
          DEFAULT: "#FFFFFF",
          light: "#F8FAFC",
          lighter: "#F1F5F9",
        },
        accent: {
          emerald: "#059669",
          "emerald-light": "#10B981",
        },
      },
      backgroundColor: {
        body: "#F8FAFC",
      },
      borderColor: {
        subtle: "#E2E8F0",
      },
      boxShadow: {
        card: "0 1px 3px 0 rgb(0 0 0 / 0.04), 0 1px 2px -1px rgb(0 0 0 / 0.04)",
        "card-hover": "0 4px 6px -1px rgb(0 0 0 / 0.06), 0 2px 4px -2px rgb(0 0 0 / 0.04)",
        soft: "0 2px 8px -2px rgb(0 0 0 / 0.08)",
        glow: "0 0 0 1px rgb(245 158 11 / 0.15), 0 2px 12px -2px rgb(245 158 11 / 0.12)",
      },
      animation: {
        shimmer: "shimmer 2s linear infinite",
        "pulse-slow": "pulse 3s cubic-bezier(0.4, 0, 0.6, 1) infinite",
      },
      keyframes: {
        shimmer: {
          "0%": { backgroundPosition: "-200% 0" },
          "100%": { backgroundPosition: "200% 0" },
        },
      },
    },
  },
  plugins: [],
};

export default config;
