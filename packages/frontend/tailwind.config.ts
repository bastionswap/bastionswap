import type { Config } from "tailwindcss";

const config: Config = {
  content: ["./src/**/*.{js,ts,jsx,tsx,mdx}"],
  darkMode: "class",
  theme: {
    extend: {
      colors: {
        bastion: {
          50: "#EBF0FA",
          100: "#D1DEF2",
          200: "#A3BDE5",
          300: "#759CD8",
          400: "#4A7BCB",
          500: "#2E5090",
          600: "#254073",
          700: "#1B2A4A",
          800: "#111C33",
          900: "#0A0E1A",
        },
        surface: {
          DEFAULT: "#111827",
          light: "#1A2235",
          lighter: "#232D42",
        },
        accent: {
          emerald: "#10B981",
          "emerald-light": "#34D399",
        },
      },
      backgroundColor: {
        body: "#0A0E1A",
      },
      borderColor: {
        subtle: "#1E293B",
      },
      animation: {
        "shimmer": "shimmer 2s linear infinite",
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
