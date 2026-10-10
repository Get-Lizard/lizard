import { Action, ActionPanel, Alert, Color, Icon, List, confirmAlert, showInFinder, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { useEffect, useState } from "react";

interface Proc {
  pid: number;
  cpu: number;
  rssKB: number;
  command: string;
}

function snapshot(): Promise<Proc[]> {
  return new Promise((resolve, reject) => {
    execFile("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="], { maxBuffer: 16 * 1024 * 1024 }, (error, stdout) => {
      if (error) return reject(error);
      const rows = stdout
        .split("\n")
        .map((line) => line.trim().match(/^(\d+)\s+([\d.]+)\s+(\d+)\s+(.+)$/))
        .filter((match): match is RegExpMatchArray => match !== null)
        .map((match) => ({ pid: Number(match[1]), cpu: Number(match[2]), rssKB: Number(match[3]), command: match[4] }));
      resolve(rows.sort((a, b) => b.cpu - a.cpu));
    });
  });
}

const nameOf = (command: string) => command.split("/").pop() ?? command;
const bundleOf = (command: string) => (command.includes(".app/") ? command.slice(0, command.indexOf(".app/") + 4) : null);
const memory = (kb: number) => (kb > 1024 * 1024 ? `${(kb / 1024 / 1024).toFixed(1)} GB` : `${Math.round(kb / 1024)} MB`);

export default function KillProcess() {
  const [processes, setProcesses] = useState<Proc[] | null>(null);

  const refresh = () => snapshot().then(setProcesses);
  useEffect(() => {
    refresh();
    const timer = setInterval(refresh, 4000);
    return () => clearInterval(timer);
  }, []);

  const stop = async (proc: Proc, force: boolean) => {
    if (force) {
      const sure = await confirmAlert({
        title: `Force kill ${nameOf(proc.command)}?`,
        message: "Unsaved work in it will be lost.",
        primaryAction: { title: "Force Kill", style: Alert.ActionStyle.Destructive },
      });
      if (!sure) return;
    }
    try {
      process.kill(proc.pid, force ? "SIGKILL" : "SIGTERM");
      await showToast({ title: `${force ? "Killed" : "Stopped"} ${nameOf(proc.command)}` });
    } catch (error) {
      await showToast({ style: Toast.Style.Failure, title: "Couldn't stop it", message: String((error as Error).message) });
    }
    setTimeout(refresh, 400);
  };

  return (
    <List isLoading={processes === null} searchBarPlaceholder="Search processes…">
      {(processes ?? []).slice(0, 300).map((proc) => {
        const bundle = bundleOf(proc.command);
        return (
          <List.Item
            key={proc.pid}
            icon={bundle ? { source: bundle } : Icon.Terminal}
            title={nameOf(proc.command)}
            subtitle={String(proc.pid)}
            keywords={[String(proc.pid), proc.command]}
            accessories={[
              { tag: { value: `${proc.cpu.toFixed(1)}%`, color: proc.cpu > 50 ? Color.Red : proc.cpu > 10 ? Color.Orange : Color.SecondaryText } },
              { text: memory(proc.rssKB) },
            ]}
            actions={
              <ActionPanel>
                <Action title="Stop Process" icon={Icon.XMarkCircle} onAction={() => stop(proc, false)} />
                <Action title="Force Kill" icon={Icon.Bolt} style={Action.Style.Destructive} onAction={() => stop(proc, true)} />
                <Action.CopyToClipboard title="Copy PID" content={String(proc.pid)} />
                {bundle ? <Action title="Show in Finder" icon={Icon.Finder} onAction={() => showInFinder(bundle)} /> : null}
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}
