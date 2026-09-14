import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://vane.prazwal.xyz"),
  title: "VANE — a Uniswap v4 hook that gives a pool a posterior",
  description:
    "VANE infers the informed signal from the deflection of a pool's own order flow and corrects its quote. Kyle-matched price discovery, computed entirely on chain, with no oracle and no co-processor.",
  icons: {
    icon: "/brand/vane-icon-512.png",
    apple: "/brand/vane-icon-180.png",
  },
  openGraph: {
    title: "VANE",
    description: "A Uniswap v4 hook that gives a pool a posterior.",
    url: "https://vane.prazwal.xyz",
    siteName: "VANE",
    type: "website",
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Newsreader:ital,opsz,wght@0,6..72,300;0,6..72,400;1,6..72,300&family=Instrument+Sans:wght@400;500&family=IBM+Plex+Mono:wght@400;500&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>{children}</body>
    </html>
  );
}
