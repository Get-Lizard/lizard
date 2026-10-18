import { useEffect, useState } from "react";
import { AppleLogo, Check, Copy, DownloadSimple, TerminalWindow } from "@phosphor-icons/react";

export const BREW = "brew install --cask get-lizard/tap/lizard";

/** The one install action on the page: copy the Homebrew command. */
export function InstallCommand({ large = false }: { large?: boolean }) {
  const [copied, setCopied] = useState(false);
  return (
    <button
      type="button"
      onClick={() => {
        navigator.clipboard.writeText(BREW);
        setCopied(true);
        setTimeout(() => setCopied(false), 1600);
      }}
      className={`group inline-flex max-w-full items-center gap-3 rounded-full border border-line-strong bg-raised pl-5 pr-2 text-left font-mono text-ink transition-all duration-300 ease-out-expo hover:border-accent/50 active:scale-[0.98] ${large ? "h-14 text-[15px]" : "h-12 text-[13.5px]"}`}
      aria-label="Copy the Homebrew install command"
    >
      <TerminalWindow size={18} weight="duotone" className="shrink-0 text-accent" />
      <span className="truncate">{BREW}</span>
      <span className={`inline-flex shrink-0 items-center gap-1.5 rounded-full px-3 py-1.5 font-sans text-[13px] font-medium transition-colors ${copied ? "bg-accent text-accent-ink" : "bg-sunken text-muted group-hover:text-ink"}`}>
        {copied ? <Check size={14} weight="bold" /> : <Copy size={14} />}
        {copied ? "Copied" : "Copy"}
      </span>
    </button>
  );
}

/** What Lizard needs, shown right under every install command so nobody installs it by mistake. */
export function Requirements({ center = false }: { center?: boolean }) {
  return (
    <p className={`inline-flex max-w-full items-start gap-2 rounded-2xl border border-accent/30 bg-accent/10 px-4 py-2 text-left text-[13.5px] leading-snug text-ink sm:items-center sm:rounded-full ${center ? "justify-center" : ""}`}>
      <AppleLogo size={16} weight="fill" className="mt-px shrink-0 text-accent sm:mt-0" />
      <span>
        Requires <strong className="font-semibold">macOS 26 Tahoe</strong> on <strong className="font-semibold">Apple silicon</strong> (M1 or later)
      </span>
    </p>
  );
}

/** Always the newest release: the site's deploy copies the latest release's Lizard.dmg next to
 *  the page (and redeploys after every release), so it downloads without leaving the site. */
export const DMG_URL = "./Lizard.dmg";

/** The latest version number, read live from GitHub (falls back to no number). */
function useLatestVersion() {
  const [version, setVersion] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    fetch("https://api.github.com/repos/Get-Lizard/lizard/releases/latest", { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : null))
      .then((json) => {
        if (alive && json?.tag_name) setVersion(String(json.tag_name).replace(/^v/, ""));
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);
  return version;
}

/** Signed, notarized disk image of the latest release. */
export function DownloadButton({ large = false }: { large?: boolean }) {
  const version = useLatestVersion();
  return (
    <a
      href={DMG_URL}
      download="Lizard.dmg"
      className={`group inline-flex items-center gap-2.5 rounded-full bg-accent font-semibold text-accent-ink shadow-[0_10px_30px_-10px_color-mix(in_oklab,var(--accent)_70%,transparent)] transition-all duration-300 ease-out-expo hover:brightness-110 active:scale-[0.98] ${large ? "h-14 px-6 text-[16px]" : "h-12 px-5 text-[15px]"}`}
    >
      <DownloadSimple size={19} weight="bold" className="transition-transform duration-300 group-hover:translate-y-0.5" />
      <span>Download for Mac</span>
      {version && <span className="rounded-full bg-accent-ink/15 px-2 py-0.5 text-[12.5px] font-medium tabular-nums">v{version}</span>}
    </a>
  );
}
