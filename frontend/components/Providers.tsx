"use client";

import type { ReactNode } from "react";
import { DemoProvider } from "@/lib/demo";
import { SessionProvider } from "@/lib/session";
import { WalletProvider } from "@/lib/wallet";

export default function Providers({ children }: { children: ReactNode }) {
  return (
    <DemoProvider>
      <WalletProvider>
        <SessionProvider>{children}</SessionProvider>
      </WalletProvider>
    </DemoProvider>
  );
}
