import { redirect } from "next/navigation";

/** Legacy route (linked from the README). */
export default function AdminRedirect() {
  redirect("/compliance");
}
