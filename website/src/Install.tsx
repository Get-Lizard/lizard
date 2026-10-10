import { useState } from "react";
import { Check, Copy, TerminalWindow } from "@phosphor-icons/react";

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
