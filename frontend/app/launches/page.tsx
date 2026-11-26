import { redirect } from "next/navigation";

/** Legacy route (linked from the README and the Flap launcher UI). */
export default function LaunchesRedirect() {
  redirect("/offerings");
}
