import { GithubLogo } from "@phosphor-icons/react";
import { Mark } from "../Mark";

export const REPO = "https://github.com/Get-Lizard/lizard";

export function Nav() {
  return (
    <header className="sticky top-0 z-40 border-b border-line bg-bg/75 backdrop-blur-xl">
      <nav className="mx-auto flex h-16 max-w-[1240px] items-center justify-between px-4 md:px-8">
        <a href="#top" className="flex items-center gap-2.5 text-[19px] font-semibold tracking-tight">
          <Mark size={26} animate={false} />
          lizard
          <span className="rounded-full border border-accent/30 bg-accent/10 px-2 py-0.5 text-[11.5px] font-medium tracking-normal text-accent">macOS 26</span>
        </a>
        <div className="hidden items-center gap-7 text-[14px] text-muted lg:flex">
          <a className="transition-colors hover:text-ink" href="#ai">Private AI</a>
          <a className="transition-colors hover:text-ink" href="#features">Features</a>
          <a className="transition-colors hover:text-ink" href="#voice">Voice</a>
          <a className="transition-colors hover:text-ink" href="#snippets">Snippets</a>
          <a className="transition-colors hover:text-ink" href="#worklog">Work Log</a>
          <a className="transition-colors hover:text-ink" href="#github">GitHub</a>
          <a className="transition-colors hover:text-ink" href="#extensions">Extensions</a>
          <a className="transition-colors hover:text-ink" href="#sync">Sync</a>
        </div>
        <a href={REPO} className="inline-flex h-9 items-center gap-2 rounded-full border border-line-strong px-4 text-[14px] font-medium transition-colors hover:border-accent/60">
          <GithubLogo size={17} weight="fill" />
          View source
        </a>
      </nav>
    </header>
  );
}
