import { open } from "@raycast/api";
import { homedir } from "node:os";

export default async function NewWarpWindow() {
  await open(`warp://action/new_window?path=${encodeURIComponent(homedir())}`);
}
