import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://vane.prazwal.xyz"),
  title: "VANE — a Uniswap v4 hook that gives a pool a posterior",
  description:
    "VANE infers the informed signal from the deflection of a pool's own order flow and corrects its quote. Kyle-matched price discovery, computed entirely on chain, with no oracle and no co-processor.",
  openGraph: {
    title: "VANE",
    description:
      "A Uniswap v4 hook that gives a pool a posterior. Kyle-matched price discovery with no oracle and no off-chain co-processor.",
    url: "https://vane.prazwal.xyz",
    siteName: "VANE",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "VANE",
    description: "A Uniswap v4 hook that gives a pool a posterior.",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
