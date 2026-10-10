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
        </a>
        <div className="hidden items-center gap-8 text-[14px] text-muted md:flex">
          <a className="transition-colors hover:text-ink" href="#ai">Private AI</a>
          <a className="transition-colors hover:text-ink" href="#features">Features</a>
          <a className="transition-colors hover:text-ink" href="#extensions">Extensions</a>
          <a className="transition-colors hover:text-ink" href="#shortcuts">Shortcuts</a>
        </div>
        <a href={REPO} className="inline-flex h-9 items-center gap-2 rounded-full border border-line-strong px-4 text-[14px] font-medium transition-colors hover:border-accent/60">
          <GithubLogo size={17} weight="fill" />
          View source
        </a>
      </nav>
    </header>
  );
}
