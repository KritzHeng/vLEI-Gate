"use client";

import { useParams } from "next/navigation";
import { OfferingDetail } from "@/components/Offerings";

export default function OfferingPage() {
  const params = useParams<{ launcher: string }>();
  const launcher = decodeURIComponent(String(params?.launcher ?? ""));
  return <OfferingDetail address={launcher} />;
}
